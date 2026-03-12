defmodule Maraithon.InsightNotifications do
  @moduledoc """
  Telegram delivery + feedback tuning for actionable insights.
  """

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.InsightNotifications.Actions
  alias Maraithon.InsightNotifications.{Delivery, ThresholdProfile}
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.TelegramRouter

  require Logger

  @default_threshold 0.78
  @min_threshold 0.35
  @max_threshold 0.97
  @helpful_delta 0.03
  @not_helpful_delta 0.05
  @eligible_insight_limit 50

  @doc """
  Polls for open insights, stages eligible Telegram deliveries, and dispatches pending ones.
  """
  def dispatch_telegram_batch(opts \\ []) do
    if telegram_configured?() do
      batch_size = Keyword.get(opts, :batch_size, 20)

      staged = stage_eligible_telegram_deliveries()

      pending =
        Delivery
        |> where([d], d.channel == "telegram" and d.status == "pending")
        |> order_by([d], desc: d.score, asc: d.inserted_at)
        |> preload([:insight])
        |> limit(^batch_size)
        |> Repo.all()

      Enum.reduce(pending, %{staged: staged, sent: 0, failed: 0}, fn delivery, acc ->
        case send_delivery(delivery) do
          :ok -> %{acc | sent: acc.sent + 1}
          {:error, _reason} -> %{acc | failed: acc.failed + 1}
        end
      end)
    else
      %{staged: 0, sent: 0, failed: 0}
    end
  end

  @doc """
  Handles Telegram webhook events relevant to linking and feedback.
  """
  def handle_telegram_event(%{} = event) do
    case read_string(event, "type") do
      "message" ->
        handle_message_event(read_map(event, "data"))

      "edited_message" ->
        TelegramRouter.handle_edited_message(read_map(event, "data"))

      "callback_query" ->
        handle_callback_query(read_map(event, "data"))

      _ ->
        :ok
    end
  end

  def handle_telegram_event(_event), do: :ok

  defp handle_message_event(data) when is_map(data) do
    chat_id = read_id_string(data, "chat_id")
    text = read_string(data, "text")

    cond do
      is_nil(chat_id) ->
        :ok

      String.starts_with?(text || "", "/start") or String.starts_with?(text || "", "/link") ->
        link_telegram_chat(chat_id, text, read_map(data, "from"))

      true ->
        case maybe_handle_preference_command(chat_id, text) do
          :handled -> :ok
          _ -> TelegramRouter.handle_message(data)
        end
    end
  end

  defp handle_message_event(_), do: :ok

  def get_or_create_profile(user_id) when is_binary(user_id) do
    case Repo.get_by(ThresholdProfile, user_id: user_id) do
      %ThresholdProfile{} = profile ->
        {:ok, profile}

      nil ->
        %ThresholdProfile{}
        |> ThresholdProfile.changeset(%{user_id: user_id, score_threshold: @default_threshold})
        |> Repo.insert()
        |> case do
          {:ok, profile} -> {:ok, profile}
          {:error, _} -> {:ok, Repo.get_by!(ThresholdProfile, user_id: user_id)}
        end
    end
  end

  defp stage_eligible_telegram_deliveries do
    ConnectedAccounts.list_connected_provider("telegram")
    |> Enum.reduce(0, fn account, acc ->
      acc + stage_for_account(account)
    end)
  end

  defp stage_for_account(account) do
    destination = account.external_account_id || get_in(account.metadata, ["chat_id"])
    now = DateTime.utc_now()

    if is_binary(destination) and String.trim(destination) != "" do
      {:ok, profile} = get_or_create_profile(account.user_id)

      Insights.list_open_for_user(account.user_id, limit: @eligible_insight_limit)
      |> Enum.reduce(0, fn insight, count ->
        score = insight_score(insight)

        if score >= profile.score_threshold and
             PreferenceMemory.allow_telegram_interrupt?(account.user_id, insight, now) and
             not delivery_exists?(insight.id, destination) do
          attrs = %{
            insight_id: insight.id,
            user_id: account.user_id,
            channel: "telegram",
            destination: destination,
            score: score,
            threshold: profile.score_threshold,
            status: "pending"
          }

          case Repo.insert(
                 Delivery.changeset(%Delivery{}, attrs),
                 on_conflict: :nothing,
                 conflict_target: [:insight_id, :channel, :destination],
                 returning: true
               ) do
            {:ok, %Delivery{id: nil}} -> count
            {:ok, _delivery} -> count + 1
            {:error, _reason} -> count
          end
        else
          count
        end
      end)
    else
      0
    end
  end

  defp send_delivery(%Delivery{} = delivery) do
    payload = Actions.telegram_payload(delivery)

    case telegram_module().send_message(
           delivery.destination,
           payload.text,
           parse_mode: "HTML",
           reply_markup: payload.reply_markup
         ) do
      {:ok, result} ->
        message_id = read_message_id(result)

        delivery
        |> Ecto.Changeset.change(%{
          status: "sent",
          sent_at: DateTime.utc_now(),
          provider_message_id: message_id,
          metadata: Map.merge(delivery.metadata || %{}, %{"telegram_message_id" => message_id})
        })
        |> Repo.update()

        :ok

      {:error, reason} ->
        Logger.warning("Failed to send Telegram insight notification", reason: inspect(reason))

        delivery
        |> Ecto.Changeset.change(%{status: "failed", error_message: inspect(reason)})
        |> Repo.update()

        {:error, reason}
    end
  end

  defp handle_feedback_callback(data) when is_map(data) do
    callback_data = read_string(data, "data")
    callback_id = read_string(data, "callback_id")
    chat_id = read_id_string(data, "chat_id")

    with {:ok, delivery_id, feedback} <- parse_feedback_data(callback_data),
         %Delivery{} = delivery <- Repo.get(Delivery, delivery_id),
         true <- delivery.channel == "telegram" and to_string(delivery.destination) == chat_id,
         {:ok, updated_delivery} <- apply_feedback(delivery, feedback) do
      maybe_answer_callback(callback_id, feedback_ack_text(updated_delivery, feedback))
      :ok
    else
      {:error, :already_recorded} ->
        maybe_answer_callback(callback_id, "Feedback already recorded")
        :ok

      _ ->
        maybe_answer_callback(callback_id, "Feedback could not be recorded")
        :ok
    end
  end

  defp handle_feedback_callback(_), do: :ok

  defp handle_callback_query(data) when is_map(data) do
    case read_string(data, "data") do
      "insfb:" <> _ ->
        handle_feedback_callback(data)

      _ ->
        case TelegramRouter.handle_callback_query(data) do
          :ok -> :ok
          _ -> Actions.handle_callback(data)
        end
    end
  end

  defp handle_callback_query(_), do: :ok

  defp apply_feedback(%Delivery{} = delivery, feedback)
       when feedback in ["helpful", "not_helpful"] do
    if delivery.feedback in ["helpful", "not_helpful"] do
      {:error, :already_recorded}
    else
      status = if feedback == "helpful", do: "feedback_helpful", else: "feedback_not_helpful"

      Repo.transaction(fn ->
        updated_delivery =
          delivery
          |> Ecto.Changeset.change(%{
            status: status,
            feedback: feedback,
            feedback_at: DateTime.utc_now()
          })
          |> Repo.update!()

        _ =
          case feedback do
            "helpful" -> Insights.acknowledge(delivery.user_id, delivery.insight_id)
            "not_helpful" -> Insights.dismiss(delivery.user_id, delivery.insight_id)
          end

        _ = tune_threshold(delivery.user_id, feedback)

        updated_delivery
      end)
      |> case do
        {:ok, updated_delivery} -> {:ok, Repo.preload(updated_delivery, :insight)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp tune_threshold(user_id, feedback) do
    {:ok, profile} = get_or_create_profile(user_id)

    delta = if feedback == "helpful", do: -@helpful_delta, else: @not_helpful_delta

    profile
    |> ThresholdProfile.changeset(%{
      score_threshold: clamp(profile.score_threshold + delta, @min_threshold, @max_threshold),
      helpful_count: profile.helpful_count + if(feedback == "helpful", do: 1, else: 0),
      not_helpful_count:
        profile.not_helpful_count + if(feedback == "not_helpful", do: 1, else: 0),
      last_feedback_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp maybe_handle_preference_command(chat_id, text) when is_binary(chat_id) do
    command_text = String.trim(text || "")

    case ConnectedAccounts.get_connected_by_external_account("telegram", chat_id) do
      nil ->
        maybe_reply_preference_help(chat_id, command_text)

      account ->
        handle_connected_preference_command(account.user_id, chat_id, command_text)
    end
  end

  defp maybe_handle_preference_command(_chat_id, _text), do: :ok

  defp handle_connected_preference_command(user_id, chat_id, text) do
    cond do
      text in ["/preferences", "/prefs", "/memory"] ->
        telegram_module().send_message(chat_id, PreferenceMemory.render_summary(user_id))
        :handled

      String.starts_with?(text, "/prefer") or String.starts_with?(text, "/policy") ->
        instruction = text |> String.split(~r/\s+/, parts: 2) |> Enum.at(1, "")

        case PreferenceMemory.apply_explicit_instruction(user_id, instruction) do
          {:ok, %{reply: reply}} -> telegram_module().send_message(chat_id, reply)
          {:error, _reason} -> telegram_module().send_message(chat_id, preference_help_text())
        end

        :handled

      String.starts_with?(text, "/forget") ->
        rule_id = text |> String.split(~r/\s+/, parts: 2) |> Enum.at(1, "")

        case PreferenceMemory.forget_rule(user_id, rule_id) do
          {:ok, reply} ->
            telegram_module().send_message(chat_id, reply)

          {:error, :rule_not_found} ->
            telegram_module().send_message(chat_id, "No saved rule matched that id.")

          {:error, _reason} ->
            telegram_module().send_message(chat_id, preference_help_text())
        end

        :handled

      true ->
        :pass
    end
  end

  defp maybe_reply_preference_help(chat_id, command_text) do
    if command_text in ["/preferences", "/prefs", "/memory"] or
         String.starts_with?(command_text, "/prefer") or
         String.starts_with?(command_text, "/policy") or
         String.starts_with?(command_text, "/forget") do
      telegram_module().send_message(
        chat_id,
        "Link this chat first with /start your@email.com, then use /prefer or /preferences."
      )

      :handled
    else
      :pass
    end
  end

  defp preference_help_text do
    """
    Preference commands:
    /preferences
    /prefer ignore receipts
    /prefer treat investors as urgent
    /prefer don't interrupt after 8pm unless external
    /forget RULE_ID
    """
    |> String.trim()
  end

  defp link_telegram_chat(chat_id, command_text, from_user) do
    case parse_link_user_id(command_text) do
      nil ->
        telegram_module().send_message(
          chat_id,
          "Use /start your-email@example.com to link this Telegram chat to Maraithon."
        )

      user_id ->
        case Accounts.get_user(user_id) do
          nil ->
            telegram_module().send_message(chat_id, "No Maraithon user found for #{user_id}.")

          _user ->
            metadata = %{
              "chat_id" => to_string(chat_id),
              "telegram_user_id" => to_string(read_integer(from_user, "id") || ""),
              "username" => read_string(from_user, "username"),
              "first_name" => read_string(from_user, "first_name"),
              "last_name" => read_string(from_user, "last_name")
            }

            case ConnectedAccounts.upsert_manual(user_id, "telegram", %{
                   external_account_id: to_string(chat_id),
                   metadata: metadata
                 }) do
              {:ok, _account} ->
                telegram_module().send_message(
                  chat_id,
                  "Linked to Maraithon user #{user_id}. Important insights will be sent here."
                )

              {:error, reason} ->
                Logger.warning("Failed linking telegram chat",
                  reason: inspect(reason),
                  user_id: user_id
                )

                telegram_module().send_message(chat_id, "Could not link this chat right now.")
            end
        end
    end

    :ok
  end

  defp parse_link_user_id(command_text) when is_binary(command_text) do
    parts =
      command_text
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    candidate =
      case parts do
        [command, arg | _] when is_binary(command) ->
          if command_matches?(command, "/start") or command_matches?(command, "/link"),
            do: arg,
            else: nil

        _ ->
          nil
      end

    case Accounts.normalize_email(candidate || "") do
      "" -> nil
      normalized -> normalized
    end
  end

  defp parse_link_user_id(_), do: nil

  defp command_matches?(command, base) when is_binary(command) and is_binary(base) do
    normalized =
      command
      |> String.trim()
      |> String.downcase()
      |> String.split("@", parts: 2)
      |> List.first()

    normalized == base
  end

  defp parse_feedback_data(value) when is_binary(value) do
    case Regex.run(~r/^insfb:([0-9a-f\-]{36}):(h|n)$/i, value, capture: :all_but_first) do
      [delivery_id, "h"] -> {:ok, delivery_id, "helpful"}
      [delivery_id, "n"] -> {:ok, delivery_id, "not_helpful"}
      _ -> {:error, :invalid_callback_data}
    end
  end

  defp parse_feedback_data(_), do: {:error, :invalid_callback_data}

  defp insight_score(%Insight{} = insight) do
    case read_float(insight.metadata || %{}, "telegram_fit_score") do
      value when is_float(value) ->
        clamp(value, 0.0, 1.0)

      nil ->
        confidence = clamp(insight.confidence || 0.0, 0.0, 1.0)
        priority = clamp((insight.priority || 0) / 100, 0.0, 1.0)

        clamp(0.65 * confidence + 0.35 * priority, 0.0, 1.0)
    end
  end

  defp maybe_answer_callback(nil, _text), do: :ok

  defp maybe_answer_callback(callback_id, text) do
    _ = telegram_module().answer_callback_query(callback_id, text: text)
    :ok
  end

  defp feedback_ack_text(%Delivery{} = delivery, feedback) do
    learned_reply =
      case PreferenceMemory.learn_from_feedback(delivery.user_id, delivery.insight, feedback) do
        {:ok, %{reply: reply}} when is_binary(reply) and reply != "" -> reply
        _ -> nil
      end

    base =
      case feedback do
        "helpful" -> "Thanks, we will send similar insights."
        "not_helpful" -> "Got it, we will be more selective."
        _ -> "Feedback saved."
      end

    if is_binary(learned_reply),
      do: truncate_callback_text("#{base} #{learned_reply}"),
      else: base
  end

  defp truncate_callback_text(text) when is_binary(text) do
    if String.length(text) <= 180, do: text, else: String.slice(text, 0, 177) <> "..."
  end

  defp delivery_exists?(insight_id, destination) do
    Delivery
    |> where([d], d.insight_id == ^insight_id)
    |> where([d], d.channel == "telegram")
    |> where([d], d.destination == ^to_string(destination))
    |> Repo.exists?()
  end

  defp read_message_id(result) when is_map(result) do
    value = read_string(result, "message_id") || read_integer(result, "message_id")

    case value do
      nil -> nil
      number when is_integer(number) -> Integer.to_string(number)
      string when is_binary(string) -> string
      _ -> nil
    end
  end

  defp read_string(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp read_integer(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_id_string(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp read_map(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_float(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
          _ -> nil
        end)
    end
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp telegram_configured? do
    module = telegram_module()

    if function_exported?(module, :configured?, 0) do
      module.configured?()
    else
      true
    end
  end

  defp telegram_module do
    Application.get_env(:maraithon, :insights, [])
    |> Keyword.get(:telegram_module, Telegram)
  end
end
