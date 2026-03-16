defmodule Maraithon.InsightNotifications.Actions do
  @moduledoc """
  Telegram-native action proposals and execution for actionable insights.
  """

  import Ecto.Query

  alias Maraithon.Connectors.Telegram
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.LLM
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.Tools

  require Logger

  @callback_prefix "insact"
  @max_preview_length 900

  def telegram_payload(%Delivery{} = delivery) do
    delivery = ensure_insight_preloaded(delivery)

    %{
      text: render_message(delivery),
      reply_markup: build_reply_markup(delivery)
    }
  end

  def fetch_delivery_for_chat(delivery_id, chat_id) do
    fetch_delivery(delivery_id, chat_id)
  end

  def find_delivery_by_provider_message(chat_id, provider_message_id)
      when is_binary(chat_id) and is_binary(provider_message_id) do
    delivery =
      Delivery
      |> where([d], d.channel == "telegram" and d.destination == ^chat_id)
      |> where([d], d.provider_message_id == ^provider_message_id)
      |> preload(:insight)
      |> Repo.one()

    case delivery do
      %Delivery{} = delivery -> {:ok, delivery}
      nil -> {:error, :delivery_not_found}
    end
  end

  def find_delivery_by_provider_message(_chat_id, _provider_message_id),
    do: {:error, :delivery_not_found}

  def perform_action(%Delivery{} = delivery, action) when is_binary(action) do
    delivery = ensure_insight_preloaded(delivery)
    dispatch_action(action, delivery)
  end

  def action_state_for_delivery(%Delivery{} = delivery), do: action_state(delivery)

  def handle_callback(data) when is_map(data) do
    callback = read_string(data, "data")
    callback_id = read_string(data, "callback_id")
    chat_id = read_id_string(data, "chat_id")
    message_id = read_string(data, "message_id", read_integer(data, "message_id"))

    with {:ok, delivery_id, action} <- parse_callback(callback),
         {:ok, delivery} <- fetch_delivery(delivery_id, chat_id),
         {:ok, delivery, notice} <- dispatch_action(action, delivery),
         :ok <- refresh_telegram_message(delivery, chat_id, message_id) do
      answer_callback(callback_id, notice)
      :ok
    else
      {:error, :unsupported_callback} ->
        {:error, :unsupported_callback}

      {:error, reason} ->
        answer_callback(callback_id, callback_error_text(reason))
        :ok
    end
  end

  def handle_callback(_), do: {:error, :unsupported_callback}

  def render_message(%Delivery{} = delivery) do
    delivery = ensure_insight_preloaded(delivery)
    insight = delivery.insight
    metadata = insight.metadata || %{}
    action_state = action_state(delivery)
    why_now = read_string(metadata, "why_now")
    follow_up_ideas = read_string_list(metadata, "follow_up_ideas")

    due_text =
      case insight.due_at do
        %DateTime{} = due_at -> "\nDue: #{Calendar.strftime(due_at, "%Y-%m-%d %H:%M UTC")}"
        _ -> ""
      end

    source_line =
      case source_label(insight, metadata) do
        nil -> ""
        value -> "\nSource: #{safe(value)}"
      end

    why_now_text =
      case why_now do
        nil -> ""
        value -> "\n\n<b>Why now:</b> #{safe(value)}"
      end

    ideas_text =
      case follow_up_ideas do
        [] ->
          ""

        ideas ->
          rendered =
            ideas
            |> Enum.map_join("\n", fn idea -> "- #{safe(idea)}" end)

          "\n\n<b>Ideas:</b>\n#{rendered}"
      end

    action_state_text = render_action_state(action_state)

    """
    <b>Maraithon Insight</b>
    <b>#{safe(insight.title)}</b>

    #{safe(insight.summary)}

    <b>Action:</b> #{safe(insight.recommended_action)}#{due_text}#{source_line}#{why_now_text}#{ideas_text}#{action_state_text}

    score=#{Float.round(delivery.score || 0.0, 2)} threshold=#{Float.round(delivery.threshold || 0.0, 2)}
    """
    |> String.trim()
  end

  def build_reply_markup(%Delivery{} = delivery) do
    callback_helpful = "insfb:#{delivery.id}:h"
    callback_not_helpful = "insfb:#{delivery.id}:n"

    rows =
      delivery
      |> action_rows()
      |> Kernel.++([
        [
          %{"text" => "Helpful", "callback_data" => callback_helpful},
          %{"text" => "Not Helpful", "callback_data" => callback_not_helpful}
        ]
      ])

    %{"inline_keyboard" => rows}
  end

  defp action_rows(%Delivery{} = delivery) do
    case action_state(delivery) do
      %{"status" => "drafted"} ->
        [
          [
            %{"text" => "Send Now", "callback_data" => callback_data(delivery.id, "send")},
            %{"text" => "Regenerate", "callback_data" => callback_data(delivery.id, "regenerate")}
          ],
          [
            %{"text" => "Cancel", "callback_data" => callback_data(delivery.id, "cancel")}
          ]
        ]

      %{"status" => "executed"} ->
        []

      %{"status" => "dismissed"} ->
        []

      %{"status" => "snoozed"} ->
        []

      _ ->
        completion_button =
          if ackable_insight?(delivery.insight) do
            %{"text" => "Ack", "callback_data" => callback_data(delivery.id, "ack")}
          else
            %{"text" => "Mark Done", "callback_data" => callback_data(delivery.id, "done")}
          end

        base_rows =
          case primary_action(delivery.insight) do
            nil ->
              [
                [completion_button]
              ]

            %{label: label, callback_action: callback_action} ->
              [
                [
                  %{
                    "text" => label,
                    "callback_data" => callback_data(delivery.id, callback_action)
                  },
                  completion_button
                ]
              ]
          end

        base_rows ++
          [
            [
              %{"text" => "Snooze 4h", "callback_data" => callback_data(delivery.id, "snooze")},
              %{"text" => "Dismiss", "callback_data" => callback_data(delivery.id, "dismiss")}
            ]
          ]
    end
  end

  defp dispatch_action("draft", %Delivery{} = delivery), do: draft_action(delivery)
  defp dispatch_action("regenerate", %Delivery{} = delivery), do: draft_action(delivery)
  defp dispatch_action("send", %Delivery{} = delivery), do: execute_action(delivery)
  defp dispatch_action("cancel", %Delivery{} = delivery), do: cancel_action(delivery)
  defp dispatch_action("ack", %Delivery{} = delivery), do: acknowledge_insight(delivery)
  defp dispatch_action("done", %Delivery{} = delivery), do: mark_done(delivery)
  defp dispatch_action("dismiss", %Delivery{} = delivery), do: dismiss_insight(delivery)
  defp dispatch_action("snooze", %Delivery{} = delivery), do: snooze_insight(delivery)
  defp dispatch_action(_action, _delivery), do: {:error, :unsupported_action}

  defp draft_action(%Delivery{} = delivery) do
    insight = delivery.insight

    with {:ok, action_spec} <- build_action_spec(insight),
         {:ok, draft} <- generate_draft(action_spec, insight),
         {:ok, delivery} <- put_action_state(delivery, %{"status" => "drafted", "spec" => draft}) do
      {:ok, delivery, "#{read_string(action_spec, "notice_label", "Action")} draft ready"}
    end
  end

  defp execute_action(%Delivery{} = delivery) do
    with %{"status" => "drafted", "spec" => spec} <- action_state(delivery),
         {:ok, result} <- run_action(spec, delivery.insight),
         {:ok, delivery} <-
           put_action_state(delivery, %{
             "status" => "executed",
             "spec" => spec,
             "result" => stringify_map_keys(result),
             "executed_at" =>
               DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }),
         {:ok, _insight} <- acknowledge_with_result(delivery.insight, spec, result) do
      {:ok, delivery, execution_notice(spec)}
    else
      nil ->
        {:error, :draft_not_ready}

      %{} ->
        {:error, :draft_not_ready}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_action(%Delivery{} = delivery) do
    with {:ok, delivery} <- put_action_state(delivery, %{"status" => "cancelled"}) do
      {:ok, delivery, "Draft cleared"}
    end
  end

  defp mark_done(%Delivery{} = delivery) do
    with {:ok, delivery} <-
           put_action_state(delivery, %{"status" => "executed", "kind" => "manual_complete"}),
         {:ok, _insight} <-
           acknowledge_with_result(
             delivery.insight,
             %{"kind" => "manual_complete"},
             %{"status" => "marked_complete_in_telegram"}
           ) do
      {:ok, delivery, "Marked complete"}
    end
  end

  defp acknowledge_insight(%Delivery{} = delivery) do
    with {:ok, _insight} <- Insights.acknowledge(delivery.user_id, delivery.insight_id),
         {:ok, delivery} <-
           put_action_state(delivery, %{"status" => "executed", "kind" => "manual_ack"}) do
      {:ok, delivery, "Acknowledged"}
    end
  end

  defp dismiss_insight(%Delivery{} = delivery) do
    with {:ok, _insight} <- Insights.dismiss(delivery.user_id, delivery.insight_id),
         {:ok, delivery} <- put_action_state(delivery, %{"status" => "dismissed"}) do
      {:ok, delivery, "Insight dismissed"}
    end
  end

  defp snooze_insight(%Delivery{} = delivery) do
    snooze_until = DateTime.add(DateTime.utc_now(), 4, :hour)

    with {:ok, _insight} <- Insights.snooze(delivery.user_id, delivery.insight_id, snooze_until),
         {:ok, delivery} <-
           put_action_state(delivery, %{
             "status" => "snoozed",
             "until" => DateTime.to_iso8601(snooze_until)
           }) do
      {:ok, delivery, "Snoozed for 4 hours"}
    end
  end

  defp build_action_spec(%Insight{} = insight) do
    metadata = insight.metadata || %{}

    cond do
      insight.source == "gmail" ->
        to = gmail_target_address(insight, metadata)

        if blank?(to) do
          {:error, :action_not_available}
        else
          {:ok,
           %{
             "kind" => "gmail_reply",
             "notice_label" => "Email",
             "account" => read_string(metadata, "account"),
             "to" => to,
             "subject" =>
               normalize_reply_subject(read_string(metadata, "subject", insight.title)),
             "thread_id" => read_string(metadata, "thread_id"),
             "reply_to_message_id" => insight.source_id,
             "person" => record_value(metadata, "person"),
             "context" => build_context(insight, metadata)
           }}
        end

      insight.source == "slack" ->
        team_id = read_string(metadata, "team_id")
        channel_id = read_string(metadata, "channel_id")
        thread_ts = read_string(metadata, "thread_ts") || slack_source_ts(insight.source_id)

        if blank?(team_id) or blank?(channel_id) do
          {:error, :action_not_available}
        else
          {:ok,
           %{
             "kind" => "slack_reply",
             "notice_label" => "Slack",
             "team_id" => team_id,
             "channel" => channel_id,
             "thread_ts" => thread_ts,
             "person" => record_value(metadata, "person"),
             "context" => build_context(insight, metadata)
           }}
        end

      true ->
        {:error, :action_not_available}
    end
  end

  defp generate_draft(%{"kind" => "gmail_reply"} = spec, %Insight{} = insight) do
    fallback = %{
      "kind" => "gmail_reply",
      "account" => spec["account"],
      "to" => spec["to"],
      "subject" => spec["subject"],
      "body" => fallback_email_body(spec, insight),
      "thread_id" => spec["thread_id"],
      "reply_to_message_id" => spec["reply_to_message_id"]
    }

    prompt = email_prompt(spec, insight)

    case llm_json(prompt) do
      {:ok, %{"subject" => subject, "body" => body}}
      when is_binary(subject) and is_binary(body) ->
        {:ok,
         fallback
         |> Map.put("subject", String.trim(subject))
         |> Map.put("body", String.trim(body))}

      _ ->
        {:ok, fallback}
    end
  end

  defp generate_draft(%{"kind" => "slack_reply"} = spec, %Insight{} = insight) do
    fallback = %{
      "kind" => "slack_reply",
      "team_id" => spec["team_id"],
      "channel" => spec["channel"],
      "thread_ts" => spec["thread_ts"],
      "text" => fallback_slack_text(spec, insight)
    }

    prompt = slack_prompt(spec, insight)

    case llm_json(prompt) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        {:ok, Map.put(fallback, "text", String.trim(text))}

      _ ->
        {:ok, fallback}
    end
  end

  defp run_action(%{"kind" => "gmail_reply"} = spec, %Insight{} = insight) do
    args = %{
      "user_id" => insight.user_id,
      "account" => read_string(spec, "account"),
      "to" => read_string(spec, "to"),
      "subject" => read_string(spec, "subject"),
      "body" => read_string(spec, "body"),
      "thread_id" => read_string(spec, "thread_id"),
      "reply_to_message_id" => read_string(spec, "reply_to_message_id")
    }

    Tools.execute("gmail_send_message", compact_map(args))
  end

  defp run_action(%{"kind" => "slack_reply"} = spec, %Insight{} = insight) do
    args = %{
      "user_id" => insight.user_id,
      "team_id" => read_string(spec, "team_id"),
      "channel" => read_string(spec, "channel"),
      "text" => read_string(spec, "text"),
      "thread_ts" => read_string(spec, "thread_ts")
    }

    Tools.execute("slack_post_message", compact_map(args))
  end

  defp run_action(_spec, _insight), do: {:error, :action_not_available}

  defp acknowledge_with_result(%Insight{} = insight, spec, result) do
    merged_metadata =
      (insight.metadata || %{})
      |> Map.put(
        "telegram_resolution",
        compact_map(%{
          "kind" => read_string(spec, "kind"),
          "completed_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "result" => stringify_map_keys(result)
        })
      )

    insight
    |> Ecto.Changeset.change(
      status: "acknowledged",
      snoozed_until: nil,
      metadata: merged_metadata
    )
    |> Repo.update()
  end

  defp put_action_state(%Delivery{} = delivery, action_state) when is_map(action_state) do
    metadata =
      delivery.metadata || %{}

    updated =
      delivery
      |> Ecto.Changeset.change(
        metadata: Map.put(metadata, "telegram_action", stringify_map_keys(action_state))
      )
      |> Repo.update()

    case updated do
      {:ok, delivery} -> {:ok, Repo.preload(delivery, :insight)}
      error -> error
    end
  end

  defp fetch_delivery(delivery_id, chat_id) when is_binary(delivery_id) do
    delivery =
      Delivery
      |> where([d], d.id == ^delivery_id)
      |> preload([:insight])
      |> Repo.one()

    cond do
      is_nil(delivery) ->
        {:error, :delivery_not_found}

      to_string(delivery.destination) != to_string(chat_id) ->
        {:error, :unauthorized_chat}

      true ->
        {:ok, delivery}
    end
  end

  defp fetch_delivery(_delivery_id, _chat_id), do: {:error, :delivery_not_found}

  defp refresh_telegram_message(%Delivery{} = delivery, chat_id, message_id) do
    payload = telegram_payload(delivery)
    module = telegram_module()

    cond do
      function_exported?(module, :edit_message_text, 4) and present?(message_id) ->
        case module.edit_message_text(chat_id, message_id, payload.text,
               parse_mode: "HTML",
               reply_markup: payload.reply_markup
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:telegram_edit_failed, reason}}
        end

      function_exported?(module, :send_message, 3) ->
        case module.send_message(chat_id, payload.text,
               parse_mode: "HTML",
               reply_markup: payload.reply_markup
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:telegram_send_failed, reason}}
        end

      true ->
        {:error, :telegram_module_missing}
    end
  end

  defp render_action_state(nil), do: ""

  defp render_action_state(%{"status" => "drafted"} = state) do
    spec = read_map(state, "spec")

    case read_string(spec, "kind") do
      "gmail_reply" ->
        body = read_string(spec, "body")
        subject = read_string(spec, "subject")

        "\n\n<b>Email draft ready</b>\n<b>Subject:</b> #{safe(subject)}\n<pre>#{safe(truncate(body, @max_preview_length))}</pre>"

      "slack_reply" ->
        text = read_string(spec, "text")
        "\n\n<b>Slack draft ready</b>\n<pre>#{safe(truncate(text, @max_preview_length))}</pre>"

      _ ->
        ""
    end
  end

  defp render_action_state(%{"status" => "executed"} = state) do
    result = read_map(state, "result")
    kind = read_string(state, "kind", read_string(read_map(state, "spec"), "kind"))
    executed_at = read_string(state, "executed_at")

    details =
      case kind do
        "gmail_reply" ->
          "Sent via Gmail (message #{safe(read_string(result, "message_id", "unknown"))})."

        "slack_reply" ->
          "Sent in Slack (ts #{safe(read_string(result, "ts", "unknown"))})."

        "manual_complete" ->
          "Marked complete from Telegram."

        "manual_ack" ->
          "Acknowledged from Telegram."

        _ ->
          "Completed."
      end

    executed_line =
      if present?(executed_at), do: "\nAt: #{safe(executed_at)}", else: ""

    "\n\n<b>Completed</b>\n#{details}#{executed_line}"
  end

  defp render_action_state(%{"status" => "snoozed"} = state) do
    until_text = read_string(state, "until")
    "\n\n<b>Snoozed</b>\nUntil: #{safe(until_text)}"
  end

  defp render_action_state(%{"status" => "dismissed"}), do: "\n\n<b>Dismissed</b>"
  defp render_action_state(%{"status" => "cancelled"}), do: ""
  defp render_action_state(_), do: ""

  defp action_state(%Delivery{} = delivery) do
    case delivery.metadata do
      %{"telegram_action" => %{} = state} -> state
      _ -> nil
    end
  end

  defp primary_action(%Insight{} = insight) do
    if ackable_insight?(insight) do
      nil
    else
      case insight.source do
        "gmail" -> %{label: "Draft Email", callback_action: "draft"}
        "slack" -> %{label: "Draft Slack", callback_action: "draft"}
        _ -> nil
      end
    end
  end

  defp ackable_insight?(%Insight{} = insight) do
    insight.category == "important_fyi" or
      read_boolean(insight.metadata || %{}, "ackable", false)
  end

  defp parse_callback(value) when is_binary(value) do
    case Regex.run(~r/^#{@callback_prefix}:([0-9a-f\-]{36}):([a-z_]+)$/i, value,
           capture: :all_but_first
         ) do
      [delivery_id, action] -> {:ok, delivery_id, String.downcase(action)}
      _ -> {:error, :unsupported_callback}
    end
  end

  defp parse_callback(_), do: {:error, :unsupported_callback}

  defp callback_data(delivery_id, action), do: "#{@callback_prefix}:#{delivery_id}:#{action}"

  defp llm_json(prompt) when is_binary(prompt) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 500,
      "temperature" => 0.2,
      "reasoning_effort" => "low"
    }

    with {:ok, response} <- LLM.provider().complete(params),
         {:ok, parsed} <- decode_json(response.content) do
      {:ok, parsed}
    else
      {:error, reason} ->
        Logger.warning("Telegram insight draft generation failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp decode_json(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = data} -> {:ok, data}
      _ -> {:error, :invalid_json}
    end
  end

  defp email_prompt(spec, insight) do
    memory = draft_memory_context(insight.user_id)

    """
    Write a concise email reply for a founder follow-through assistant.

    Return ONLY valid JSON:
    {"subject":"...","body":"..."}

    Constraints:
    - Be concrete, professional, and brief.
    - Do not claim attachments, delivery, or completed work unless explicitly proven.
    - If the promised artifact is not clearly available, send an honest progress update plus a firm ETA.
    - Close the loop in one message.
    - Follow durable operator style and action preferences when they are relevant.

    Insight JSON:
    #{Jason.encode!(%{title: insight.title, summary: insight.summary, recommended_action: insight.recommended_action, person: spec["person"], context: spec["context"], to: spec["to"], subject: spec["subject"]})}

    Draft memory JSON:
    #{Jason.encode!(memory)}
    """
  end

  defp slack_prompt(spec, insight) do
    memory = draft_memory_context(insight.user_id)

    """
    Write a concise Slack reply for an unresolved follow-through item.

    Return ONLY valid JSON:
    {"text":"..."}

    Constraints:
    - Be direct and short.
    - Include owner / next step / ETA when appropriate.
    - Do not claim work is already done unless proven.
    - Follow durable operator style and action preferences when they are relevant.

    Insight JSON:
    #{Jason.encode!(%{title: insight.title, summary: insight.summary, recommended_action: insight.recommended_action, person: spec["person"], context: spec["context"]})}

    Draft memory JSON:
    #{Jason.encode!(memory)}
    """
  end

  defp draft_memory_context(user_id) when is_binary(user_id) do
    %{
      preference_memory: PreferenceMemory.prompt_context(user_id),
      operator_summaries: OperatorMemory.summaries_for_prompt(user_id)
    }
  end

  defp draft_memory_context(_user_id) do
    %{
      preference_memory: PreferenceMemory.prompt_context(nil),
      operator_summaries: []
    }
  end

  defp fallback_email_body(spec, insight) do
    greeting = email_greeting(spec["person"], spec["to"])

    """
    #{greeting}

    Following up here on this now. #{insight.summary}

    I don't want to leave this open. If the full artifact isn't ready yet, I'll send the remaining detail and exact ETA shortly.

    Best,
    #{sender_name()}
    """
    |> String.trim()
  end

  defp fallback_slack_text(_spec, insight) do
    "Following up on this now. #{insight.summary} I'll close the loop with owner, next step, and exact ETA shortly."
  end

  defp execution_notice(%{"kind" => "gmail_reply"}), do: "Email sent"
  defp execution_notice(%{"kind" => "slack_reply"}), do: "Slack reply sent"
  defp execution_notice(_), do: "Action completed"

  defp callback_error_text(:action_not_available), do: "Action not available for this insight"
  defp callback_error_text(:draft_not_ready), do: "Generate a draft first"
  defp callback_error_text(:delivery_not_found), do: "Insight delivery not found"
  defp callback_error_text(:unauthorized_chat), do: "This action is not authorized in this chat"
  defp callback_error_text(:unsupported_action), do: "Unsupported action"

  defp callback_error_text({:telegram_edit_failed, _}),
    do: "Action ran, but Telegram refresh failed"

  defp callback_error_text("google_account_reauth_required"), do: "Reconnect Google in Maraithon"
  defp callback_error_text("slack_workspace_reauth_required"), do: "Reconnect Slack in Maraithon"
  defp callback_error_text("google_account_not_connected"), do: "Connect Google first"
  defp callback_error_text("slack_workspace_not_connected"), do: "Connect Slack first"
  defp callback_error_text(reason) when is_binary(reason), do: truncate(reason, 60)
  defp callback_error_text(_), do: "Action failed"

  defp answer_callback(nil, _text), do: :ok

  defp answer_callback(callback_id, text) do
    _ = telegram_module().answer_callback_query(callback_id, text: text)
    :ok
  end

  defp gmail_target_address(insight, metadata) do
    case insight.category do
      "reply_urgent" -> read_string(metadata, "from")
      _ -> read_string(metadata, "to") || read_string(metadata, "from")
    end
  end

  defp source_label(%Insight{} = insight, metadata) do
    account =
      read_string(metadata, "account") ||
        read_string(metadata, "team_id")

    cond do
      present?(account) -> "#{insight.source} · #{account}"
      true -> insight.source
    end
  end

  defp build_context(%Insight{}, metadata) do
    compact_map(%{
      "record" => read_map(metadata, "record"),
      "context_brief" => read_string(metadata, "context_brief"),
      "signals" => read_string_list(metadata, "signals"),
      "evidence" => record_value_list(metadata, "evidence"),
      "person" => record_value(metadata, "person"),
      "commitment" => record_value(metadata, "commitment"),
      "next_action" => record_value(metadata, "next_action"),
      "account" => read_string(metadata, "account"),
      "channel_name" => read_string(metadata, "channel_name")
    })
  end

  defp slack_source_ts("slack:" <> rest) do
    rest
    |> String.split(":")
    |> List.last()
    |> normalize_blank()
  end

  defp slack_source_ts(_), do: nil

  defp email_greeting(person, to_field) do
    candidate =
      normalize_blank(person) ||
        normalize_blank(first_email_name(to_field)) ||
        "there"

    "Hi #{candidate},"
  end

  defp first_email_name(value) when is_binary(value) do
    value
    |> String.split(",", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        nil

      raw ->
        raw
        |> String.replace(~r/<[^>]+>/, "")
        |> String.replace("\"", "")
        |> String.trim()
        |> case do
          "" ->
            nil

          cleaned ->
            cleaned
            |> String.split(~r/\s+/, trim: true)
            |> List.first()
        end
    end
  end

  defp first_email_name(_), do: nil

  defp normalize_reply_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)

    cond do
      trimmed == "" -> "Quick follow-up"
      String.match?(trimmed, ~r/^re:/i) -> trimmed
      true -> "Re: #{trimmed}"
    end
  end

  defp normalize_reply_subject(_), do: "Quick follow-up"

  defp sender_name do
    System.get_env("MARAITHON_DEFAULT_SENDER_NAME") ||
      Application.get_env(:maraithon, :insights, [])
      |> Keyword.get(:default_sender_name, "Maraithon")
  end

  defp ensure_insight_preloaded(%Delivery{insight: %Insight{}} = delivery), do: delivery
  defp ensure_insight_preloaded(%Delivery{} = delivery), do: Repo.preload(delivery, :insight)

  defp telegram_module do
    Application.get_env(:maraithon, :insights, [])
    |> Keyword.get(:telegram_module, Telegram)
  end

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_map(value) ->
        Map.put(acc, to_string(key), stringify_map_keys(value))

      {key, value}, acc when is_list(value) ->
        Map.put(
          acc,
          to_string(key),
          Enum.map(value, fn
            item when is_map(item) -> stringify_map_keys(item)
            item -> item
          end)
        )

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp stringify_map_keys(other), do: other

  defp read_map(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      %{} = value -> value
      _ -> %{}
    end
  end

  defp read_string(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        default
    end
  end

  defp read_integer(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_boolean(map, key, default) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when value in [true, false] ->
        value

      value when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> true
          "1" -> true
          "yes" -> true
          "false" -> false
          "0" -> false
          "no" -> false
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_id_string(map, key) when is_map(map) and is_binary(key) do
    read_string(map, key) || read_integer(map, key) |> normalize_id()
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value), do: to_string(value)

  defp read_string_list(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value when is_binary(value) ->
        [String.trim(value)]

      _ ->
        []
    end
  end

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp record_value(metadata, key) do
    metadata
    |> read_map("record")
    |> read_string(key)
  end

  defp record_value_list(metadata, key) do
    metadata
    |> read_map("record")
    |> read_string_list(key)
  end

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: to_string(value || "")

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) > max, do: String.slice(value, 0, max - 3) <> "...", else: value
  end

  defp truncate(value, _max), do: to_string(value || "")

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp blank?(value), do: not present?(value)

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_blank(_), do: nil
end
