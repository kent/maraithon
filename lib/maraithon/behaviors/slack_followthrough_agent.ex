defmodule Maraithon.Behaviors.SlackFollowthroughAgent do
  @moduledoc """
  Slack accountability behavior focused on unresolved commitments and reply debt.

  Detects high-signal open loops from channel and DM history, then stores
  structured unresolved commitment records for Telegram escalation.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Connectors.Slack
  alias Maraithon.Followthrough.ConversationContext
  alias Maraithon.Insights
  alias Maraithon.OAuth

  require Logger

  @default_wakeup_interval_ms :timer.minutes(10)
  @default_channel_scan_limit 80
  @default_dm_scan_limit 50
  @default_lookback_hours 48
  @default_max_insights_per_cycle 5
  @default_min_confidence 0.75
  @max_scan_conversations 12
  @max_evidence_points 3
  @max_insights_scan_multiplier 2

  @promise_terms [
    "i will",
    "we will",
    "i'll",
    "we'll",
    "i can",
    "i can get this",
    "i can send",
    "follow up",
    "follow-up",
    "circle back",
    "by today",
    "by tomorrow"
  ]

  @commitment_action_terms [
    "send",
    "share",
    "reply",
    "forward",
    "recap",
    "owners",
    "next steps",
    "deck",
    "slides",
    "notes",
    "doc",
    "proposal",
    "update"
  ]

  @reply_request_terms [
    "?",
    "can you",
    "could you",
    "please",
    "when",
    "update",
    "asap",
    "urgent",
    "today",
    "tomorrow"
  ]

  @artifact_delivery_terms [
    "sent",
    "shared",
    "uploaded",
    "attached",
    "here is",
    "here's",
    "fwd",
    "forwarded",
    "done",
    "recap",
    "owners",
    "next steps"
  ]

  @planning_terms [
    "planning",
    "roadmap",
    "retro",
    "meeting",
    "sync",
    "action items",
    "owners",
    "next steps"
  ]

  @deadline_terms [
    "today",
    "tomorrow",
    "eod",
    "end of day",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday"
  ]

  @weekday_numbers %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      team_id: normalize_string(config["team_id"]),
      team_ids: normalize_team_ids(config["team_ids"]),
      channel_scan_limit:
        to_positive_integer(config["channel_scan_limit"], @default_channel_scan_limit),
      dm_scan_limit: to_positive_integer(config["dm_scan_limit"], @default_dm_scan_limit),
      lookback_hours: to_positive_integer(config["lookback_hours"], @default_lookback_hours),
      max_insights_per_cycle:
        to_positive_integer(config["max_insights_per_cycle"], @default_max_insights_per_cycle),
      min_confidence: to_float(config["min_confidence"], @default_min_confidence),
      wakeup_interval_ms:
        to_positive_integer(config["wakeup_interval_ms"], @default_wakeup_interval_ms),
      last_scan_at: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state = ensure_user_id(state, context)

    cond do
      is_nil(state.user_id) ->
        Logger.warning("SlackFollowthroughAgent skipped wakeup: user_id missing",
          agent_id: context.agent_id
        )

        {:idle, state}

      true ->
        candidates =
          case context[:event] do
            %{payload: payload} ->
              candidates_from_pubsub_payload(payload, state, context.timestamp)

            _ ->
              candidates_from_periodic_scan(state, context.timestamp)
          end
          |> dedupe_candidates()
          |> Enum.filter(&high_signal_unresolved?(&1, state))
          |> Enum.take(state.max_insights_per_cycle * @max_insights_scan_multiplier)

        insights =
          candidates
          |> Enum.take(state.max_insights_per_cycle)

        case persist_insights(insights, state, context) do
          {:ok, stored} ->
            if stored == [] do
              {:idle, %{state | last_scan_at: context.timestamp}}
            else
              {:emit,
               {:insights_recorded,
                %{
                  count: length(stored),
                  user_id: state.user_id,
                  categories: stored |> Enum.map(& &1.category) |> Enum.uniq()
                }}, %{state | last_scan_at: context.timestamp}}
            end

          {:error, reason} ->
            {:emit,
             {:insight_error, %{reason: inspect(reason), attempted_count: length(insights)}},
             %{state | last_scan_at: context.timestamp}}
        end
    end
  end

  @impl true
  def handle_effect_result({:tool_call, _result}, state, _context), do: {:idle, state}
  def handle_effect_result({:llm_call, _result}, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state), do: {:relative, state.wakeup_interval_ms || @default_wakeup_interval_ms}

  defp ensure_user_id(state, context) do
    case state.user_id do
      nil -> %{state | user_id: normalize_string(context[:user_id])}
      _ -> state
    end
  end

  defp candidates_from_periodic_scan(state, timestamp) do
    team_ids = resolve_team_ids(state)

    if team_ids == [] do
      []
    else
      Enum.flat_map(team_ids, fn team_id ->
        scan_team(team_id, state, timestamp)
      end)
    end
  end

  defp candidates_from_pubsub_payload(payload, state, timestamp) when is_map(payload) do
    source = read_string(payload, "source", read_string(payload, "connector", nil))

    cond do
      source == "slack" ->
        payload
        |> extract_pubsub_messages()
        |> scan_message_batch(state, timestamp)

      true ->
        candidates_from_periodic_scan(state, timestamp)
    end
  end

  defp candidates_from_pubsub_payload(_payload, state, timestamp),
    do: candidates_from_periodic_scan(state, timestamp)

  defp scan_team(team_id, state, timestamp) do
    bot_provider = "slack:#{team_id}"

    with {:ok, bot_token} <- OAuth.get_valid_access_token(state.user_id, bot_provider) do
      user_token = resolve_user_token(state.user_id, team_id)
      self_user_ids = resolve_self_user_ids(state.user_id, team_id)
      oldest = slack_oldest_ts(timestamp, state.lookback_hours)

      channel_candidates =
        scan_conversations(
          team_id,
          bot_token,
          self_user_ids,
          state,
          oldest,
          types: ["public_channel", "private_channel"],
          scan_limit: state.channel_scan_limit
        )

      dm_candidates =
        case user_token do
          nil ->
            []

          token ->
            scan_conversations(
              team_id,
              token,
              self_user_ids,
              state,
              oldest,
              types: ["im", "mpim"],
              scan_limit: state.dm_scan_limit
            )
        end

      channel_candidates ++ dm_candidates
    else
      {:error, :no_token} ->
        Logger.debug("SlackFollowthroughAgent missing bot token for workspace", team_id: team_id)
        []

      {:error, reason} ->
        Logger.warning("SlackFollowthroughAgent failed to load bot token",
          team_id: team_id,
          reason: inspect(reason)
        )

        []
    end
  end

  defp scan_conversations(team_id, access_token, self_user_ids, state, oldest, opts) do
    types = Keyword.get(opts, :types, ["public_channel"])
    scan_limit = Keyword.get(opts, :scan_limit, 30)
    conversation_limit = min(@max_scan_conversations, max(div(scan_limit, 8), 3))
    per_conversation = max(div(scan_limit, max(conversation_limit, 1)), 4)

    with {:ok, response} <-
           Slack.list_conversations(access_token,
             types: types,
             exclude_archived: true,
             limit: conversation_limit
           ) do
      response["channels"]
      |> normalize_list()
      |> Enum.take(conversation_limit)
      |> Enum.flat_map(fn conversation ->
        channel_id = conversation["id"]

        case Slack.get_conversation_history(access_token, channel_id,
               limit: per_conversation,
               oldest: oldest
             ) do
          {:ok, history} ->
            history["messages"]
            |> normalize_list()
            |> Enum.map(&normalize_message(&1, team_id, conversation))
            |> scan_message_batch(state, DateTime.utc_now(), self_user_ids)

          {:error, reason} ->
            Logger.debug("SlackFollowthroughAgent failed conversation history",
              team_id: team_id,
              channel_id: channel_id,
              reason: inspect(reason)
            )

            []
        end
      end)
      |> Enum.take(scan_limit)
    else
      {:error, reason} ->
        Logger.debug("SlackFollowthroughAgent failed conversation list",
          team_id: team_id,
          reason: inspect(reason)
        )

        []
    end
  end

  defp scan_message_batch(messages, state, timestamp, explicit_self_ids \\ [])

  defp scan_message_batch(messages, state, _timestamp, explicit_self_ids)
       when is_list(messages) do
    sorted_messages =
      messages
      |> Enum.map(&normalize_inline_message/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&datetime_sort_key(&1.occurred_at))

    self_user_ids =
      (explicit_self_ids ++
         (sorted_messages |> Enum.map(& &1.self_user_id) |> Enum.reject(&is_nil/1)))
      |> Enum.uniq()

    commitment_candidates =
      sorted_messages
      |> Enum.flat_map(&commitment_candidates(&1, sorted_messages, self_user_ids, state))

    reply_candidates =
      sorted_messages
      |> Enum.flat_map(&reply_candidates(&1, sorted_messages, self_user_ids, state))

    commitment_candidates ++ reply_candidates
  end

  defp scan_message_batch(_messages, _state, _timestamp, _explicit_self_ids), do: []

  defp commitment_candidates(message, all_messages, self_user_ids, state) do
    text = message.text || ""
    normalized = String.downcase(text)
    promise_matches = matched_terms(normalized, @promise_terms)
    action_matches = matched_terms(normalized, @commitment_action_terms)
    planning_matches = matched_terms(normalized, @planning_terms)
    deadline_matches = matched_terms(normalized, @deadline_terms)
    explicit_promise? = promise_matches != [] and action_matches != []

    if explicit_promise? and self_message?(message, self_user_ids) do
      if followthrough_message(all_messages, message, self_user_ids) do
        []
      else
        conversation_context =
          build_slack_conversation_context(message, all_messages, self_user_ids, state)

        if resolved_conversation?(conversation_context) do
          []
        else
          person = commitment_person(text, message)
          due_at = infer_deadline_from_text(normalized, message.occurred_at)
          due_at = due_at || DateTime.add(message.occurred_at || DateTime.utc_now(), 24, :hour)
          artifact = artifact_hint(normalized)

          category =
            if(planning_matches != [], do: "meeting_follow_up", else: "commitment_unresolved")

          title =
            case artifact do
              nil -> "Slack follow-through owed to #{person}"
              value -> "You said you'd send #{value} to #{person}. No follow-up yet."
            end

          summary =
            if category == "meeting_follow_up" do
              "After the planning thread, owners and next steps still appear unresolved."
            else
              "The Slack commitment to #{person} still appears open #{deadline_phrase(due_at)}."
            end

          next_action =
            "Reply in the same Slack thread with the promised artifact, owner, and exact ETA."

          evidence =
            []
            |> maybe_append("Promise terms detected: #{Enum.join(promise_matches, ", ")}.", true)
            |> maybe_append(
              "Commitment terms detected: #{Enum.join(action_matches, ", ")}.",
              action_matches != []
            )
            |> maybe_append(
              "Deadline cues: #{Enum.join(deadline_matches, ", ")}.",
              deadline_matches != []
            )
            |> maybe_append("No follow-through message was found after this commitment.", true)
            |> Enum.take(@max_evidence_points)

          confidence =
            0.72
            |> maybe_add_float(0.08, length(promise_matches) >= 2)
            |> maybe_add_float(0.06, length(action_matches) >= 2)
            |> maybe_add_float(0.06, planning_matches != [])
            |> maybe_add_float(0.06, deadline_matches != [])
            |> maybe_add_float(0.05, artifact != nil)
            |> maybe_add_float(0.05, self_user_ids != [])
            |> maybe_add_float(-0.1, self_user_ids == [])
            |> clamp(0.0, 1.0)

          priority =
            urgency_priority(due_at, if(category == "meeting_follow_up", do: 83, else: 86))

          source_id = "slack:#{message.team_id}:#{message.channel_id}:#{message.ts}"

          dedupe_key =
            "slack:commitment:#{message.team_id}:#{message.channel_id}:#{message.thread_ts || message.ts}"

          record =
            commitment_record(
              "Follow through on Slack commitment: #{truncate(text, 120)}",
              person,
              source_id,
              due_at,
              "unresolved",
              evidence,
              next_action
            )

          [
            %{
              source: "slack",
              source_id: source_id,
              source_occurred_at: message.occurred_at,
              category: category,
              title: truncate(title, 180),
              summary: summary,
              recommended_action: next_action,
              priority: priority,
              confidence: confidence,
              due_at: due_at,
              dedupe_key: dedupe_key,
              metadata: %{
                "team_id" => message.team_id,
                "channel_id" => message.channel_id,
                "channel_name" => message.channel_name,
                "thread_ts" => message.thread_ts,
                "signals" => Enum.uniq(promise_matches ++ action_matches ++ planning_matches),
                "record" => record
              }
            }
            |> ConversationContext.apply_to_candidate(conversation_context)
          ]
        end
      end
    else
      []
    end
  end

  defp reply_candidates(message, all_messages, self_user_ids, state) do
    text = message.text || ""
    normalized = String.downcase(text)
    reply_matches = matched_terms(normalized, @reply_request_terms)
    needs_reply? = reply_matches != [] or String.contains?(normalized, "?")

    incoming_dm? =
      (message.is_dm || message.is_mpim) and not self_message?(message, self_user_ids)

    if incoming_dm? and needs_reply? do
      if reply_sent_after?(all_messages, message, self_user_ids) do
        []
      else
        conversation_context =
          build_slack_conversation_context(message, all_messages, self_user_ids, state)

        if resolved_conversation?(conversation_context) do
          []
        else
          person = message.user_id || "the sender"
          due_at = infer_deadline_from_text(normalized, message.occurred_at)
          due_at = due_at || DateTime.add(message.occurred_at || DateTime.utc_now(), 8, :hour)

          next_action =
            "Send a Slack reply now with owner, next step, and a concrete timing commitment."

          evidence =
            []
            |> maybe_append("Incoming DM/MPIM message appears to request a response.", true)
            |> maybe_append(
              "Reply request terms: #{Enum.join(reply_matches, ", ")}.",
              reply_matches != []
            )
            |> maybe_append("No reply from you was found afterward in this conversation.", true)
            |> Enum.take(@max_evidence_points)

          confidence =
            0.7
            |> maybe_add_float(0.12, reply_matches != [])
            |> maybe_add_float(0.06, String.contains?(normalized, "?"))
            |> maybe_add_float(0.05, self_user_ids != [])
            |> clamp(0.0, 1.0)

          priority = urgency_priority(due_at, 82)
          source_id = "slack:#{message.team_id}:#{message.channel_id}:#{message.ts}"
          dedupe_key = "slack:reply:#{message.team_id}:#{message.channel_id}:#{message.ts}"

          record =
            commitment_record(
              "Reply to #{person} in Slack",
              person,
              source_id,
              due_at,
              "unresolved",
              evidence,
              next_action
            )

          [
            %{
              source: "slack",
              source_id: source_id,
              source_occurred_at: message.occurred_at,
              category: "reply_urgent",
              title: "Slack reply owed to #{person}",
              summary:
                "You still owe #{person} a Slack response #{deadline_phrase(due_at)} and no reply was detected.",
              recommended_action: next_action,
              priority: priority,
              confidence: confidence,
              due_at: due_at,
              dedupe_key: dedupe_key,
              metadata: %{
                "team_id" => message.team_id,
                "channel_id" => message.channel_id,
                "channel_name" => message.channel_name,
                "thread_ts" => message.thread_ts,
                "signals" => reply_matches,
                "record" => record
              }
            }
            |> ConversationContext.apply_to_candidate(conversation_context)
          ]
        end
      end
    else
      []
    end
  end

  defp persist_insights([], _state, _context), do: {:ok, []}

  defp persist_insights(insights, state, context) do
    case Insights.record_many(state.user_id, context.agent_id, insights) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, reason} ->
        Logger.warning("SlackFollowthroughAgent failed to persist insights",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp high_signal_unresolved?(candidate, state) do
    confidence = read_float(candidate, "confidence", 0.0)
    priority = read_integer(candidate, "priority", 0)
    min_threshold = max(state.min_confidence, 0.74)
    status = read_string(read_map(candidate, "metadata")["record"] || %{}, "status", "unresolved")

    String.downcase(status) == "unresolved" and confidence >= min_threshold and priority >= 70
  end

  defp dedupe_candidates(candidates) do
    candidates
    |> Enum.reduce(%{}, fn candidate, acc ->
      key = read_string(candidate, "dedupe_key", Ecto.UUID.generate())

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, candidate)

        existing ->
          if read_integer(candidate, "priority", 0) >= read_integer(existing, "priority", 0) do
            Map.put(acc, key, candidate)
          else
            acc
          end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&read_integer(&1, "priority", 0), :desc)
  end

  defp resolve_team_ids(state) do
    cond do
      state.team_ids not in [nil, []] ->
        state.team_ids

      state.team_id ->
        [state.team_id]

      true ->
        state.user_id
        |> OAuth.list_user_tokens()
        |> Enum.map(& &1.provider)
        |> Enum.filter(&is_binary/1)
        |> Enum.flat_map(fn provider ->
          case Regex.run(~r/^slack:([^:]+)$/, provider, capture: :all_but_first) do
            [team_id] -> [team_id]
            _ -> []
          end
        end)
        |> Enum.uniq()
    end
  end

  defp normalize_team_ids(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_team_ids(_values), do: []

  defp resolve_user_token(user_id, team_id) do
    user_id
    |> OAuth.list_user_tokens()
    |> Enum.filter(fn token ->
      is_binary(token.provider) and String.starts_with?(token.provider, "slack:#{team_id}:user:")
    end)
    |> Enum.sort_by(&datetime_sort_key(&1.updated_at), :desc)
    |> List.first()
    |> case do
      nil ->
        nil

      token ->
        case OAuth.get_valid_access_token(user_id, token.provider) do
          {:ok, access_token} -> access_token
          _ -> nil
        end
    end
  end

  defp resolve_self_user_ids(user_id, team_id) do
    user_id
    |> OAuth.list_user_tokens()
    |> Enum.map(& &1.provider)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn provider ->
      case Regex.run(~r/^slack:#{Regex.escape(team_id)}:user:([^:]+)$/, provider,
             capture: :all_but_first
           ) do
        [slack_user_id] -> [slack_user_id]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp build_slack_conversation_context(message, all_messages, self_user_ids, state) do
    fallback_messages = Enum.filter(all_messages, &same_thread_or_channel?(&1, message))

    case fetch_slack_thread_messages(message, state) do
      {:ok, messages} when is_list(messages) and messages != [] ->
        ConversationContext.from_slack(messages, message,
          self_user_ids: self_user_ids,
          default_owner: "user_owner"
        )

      {:error, reason} ->
        if present?(message.thread_ts) do
          fallback_messages
          |> ConversationContext.from_slack(message,
            self_user_ids: self_user_ids,
            default_owner: "user_owner"
          )
          |> Map.put("notification_posture", "insufficient_context")
          |> Map.put(
            "insufficient_context_reason",
            "slack_thread_fetch_failed: #{inspect(reason)}"
          )
        else
          ConversationContext.from_slack(fallback_messages, message,
            self_user_ids: self_user_ids,
            default_owner: "user_owner"
          )
        end

      _ ->
        ConversationContext.from_slack(fallback_messages, message,
          self_user_ids: self_user_ids,
          default_owner: "user_owner"
        )
    end
  end

  defp fetch_slack_thread_messages(message, state) do
    if present?(message.thread_ts) do
      case slack_access_token_for_thread(state.user_id, message.team_id) do
        nil ->
          {:error, :no_token}

        access_token ->
          case Slack.get_thread_replies(access_token, message.channel_id, message.thread_ts,
                 limit: 50
               ) do
            {:ok, response} ->
              messages =
                response["messages"]
                |> normalize_list()
                |> Enum.map(&thread_reply_message(&1, message))

              {:ok, messages}

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:ok, []}
    end
  end

  defp slack_access_token_for_thread(user_id, team_id) do
    resolve_user_token(user_id, team_id) ||
      case OAuth.get_valid_access_token(user_id, "slack:#{team_id}") do
        {:ok, access_token} -> access_token
        _ -> nil
      end
  end

  defp thread_reply_message(reply, message) when is_map(reply) do
    %{
      "source" => "slack",
      "team_id" => message.team_id,
      "channel_id" => message.channel_id,
      "channel_name" => message.channel_name,
      "is_dm" => message.is_dm,
      "is_mpim" => message.is_mpim,
      "counterparty_id" => message.counterparty_id,
      "self_user_id" => message.self_user_id,
      "user_id" => read_string(reply, "user", nil),
      "text" => read_string(reply, "text", ""),
      "ts" => read_string(reply, "ts", nil),
      "thread_ts" => read_string(reply, "thread_ts", message.thread_ts || message.ts)
    }
  end

  defp thread_reply_message(_reply, _message), do: %{}

  defp resolved_conversation?(context) when is_map(context) do
    read_string(context, "notification_posture", nil) == "resolved"
  end

  defp followthrough_message(messages, source_message, self_user_ids) do
    Enum.find(messages, fn candidate ->
      later_message?(candidate, source_message) and
        self_message?(candidate, self_user_ids) and
        same_thread_or_channel?(candidate, source_message) and
        contains_any?(String.downcase(candidate.text || ""), @artifact_delivery_terms)
    end)
  end

  defp reply_sent_after?(messages, source_message, self_user_ids) do
    Enum.any?(messages, fn candidate ->
      later_message?(candidate, source_message) and
        self_message?(candidate, self_user_ids) and
        same_thread_or_channel?(candidate, source_message)
    end)
  end

  defp same_thread_or_channel?(left, right) do
    if present?(left.thread_ts) and present?(right.thread_ts) do
      left.thread_ts == right.thread_ts
    else
      left.channel_id == right.channel_id
    end
  end

  defp later_message?(candidate, source) do
    datetime_sort_key(candidate.occurred_at) > datetime_sort_key(source.occurred_at)
  end

  defp self_message?(message, self_user_ids) do
    cond do
      message.user_id in self_user_ids ->
        true

      self_user_ids == [] ->
        contains_any?(String.downcase(message.text || ""), [
          "i will",
          "i'll",
          "i can",
          "we will",
          "we'll"
        ])

      true ->
        false
    end
  end

  defp commitment_person(text, message) do
    mentions =
      Regex.scan(~r/<@([A-Z0-9]+)>/, text || "", capture: :all_but_first)
      |> List.flatten()

    cond do
      mentions != [] ->
        hd(mentions)

      message.is_dm and present?(message.counterparty_id) ->
        message.counterparty_id

      true ->
        "the recipient"
    end
  end

  defp artifact_hint(text) when is_binary(text) do
    cond do
      String.contains?(text, "deck") -> "the deck"
      String.contains?(text, "slides") -> "the slides"
      String.contains?(text, "proposal") -> "the proposal"
      String.contains?(text, "doc") -> "the document"
      String.contains?(text, "notes") -> "meeting notes"
      true -> nil
    end
  end

  defp normalize_message(message, team_id, conversation) do
    %{
      team_id: team_id,
      channel_id: conversation["id"],
      channel_name: conversation["name"] || conversation["id"],
      is_dm: conversation["is_im"] || false,
      is_mpim: conversation["is_mpim"] || false,
      counterparty_id: conversation["user"],
      self_user_id: nil,
      ts: read_string(message, "ts", nil),
      thread_ts: read_string(message, "thread_ts", nil),
      user_id: read_string(message, "user", nil),
      subtype: read_string(message, "subtype", nil),
      text: read_string(message, "text", ""),
      occurred_at: parse_slack_timestamp(read_string(message, "ts", nil))
    }
  end

  defp normalize_inline_message(message) when is_map(message) do
    team_id = read_string(message, "team_id", nil)
    channel_id = read_string(message, "channel_id", read_string(message, "channel", nil))
    ts = read_string(message, "ts", nil)
    source = read_string(message, "source", nil)

    if source in [nil, "slack"] and team_id != nil and channel_id != nil and ts != nil do
      %{
        team_id: team_id,
        channel_id: channel_id,
        channel_name: read_string(message, "channel_name", channel_id),
        is_dm: read_bool(message, "is_dm", dm_channel?(channel_id)),
        is_mpim: read_bool(message, "is_mpim", false),
        counterparty_id: read_string(message, "counterparty_id", nil),
        self_user_id: read_string(message, "self_user_id", nil),
        ts: ts,
        thread_ts: read_string(message, "thread_ts", nil),
        user_id: read_string(message, "user_id", read_string(message, "user", nil)),
        subtype: read_string(message, "subtype", nil),
        text: read_string(message, "text", ""),
        occurred_at: parse_slack_timestamp(ts)
      }
    else
      nil
    end
  end

  defp normalize_inline_message(_message), do: nil

  defp extract_pubsub_messages(payload) do
    data = read_map(payload, "data")

    cond do
      match?(%{"messages" => messages} when is_list(messages), data) ->
        data["messages"]

      match?(%{messages: messages} when is_list(messages), data) ->
        data.messages

      read_string(payload, "source", nil) == "slack" and is_map(data) ->
        [data]

      true ->
        []
    end
    |> Enum.map(fn item ->
      item
      |> read_map("event")
      |> case do
        %{} = event when map_size(event) > 0 ->
          %{
            "source" => "slack",
            "team_id" => read_string(payload, "team_id", read_string(data, "team_id", nil)),
            "channel_id" =>
              read_string(
                event,
                "channel_id",
                read_string(event, "channel", read_string(data, "channel_id", nil))
              ),
            "channel_name" => read_string(event, "channel_name", nil),
            "user_id" => read_string(event, "user_id", read_string(event, "user", nil)),
            "text" => read_string(event, "text", ""),
            "ts" => read_string(event, "ts", nil),
            "thread_ts" => read_string(event, "thread_ts", nil),
            "is_dm" => read_bool(event, "is_dm", false),
            "is_mpim" => read_bool(event, "is_mpim", false)
          }

        _ ->
          item
      end
    end)
  end

  defp slack_oldest_ts(timestamp, lookback_hours) do
    timestamp
    |> DateTime.add(-(lookback_hours * 3600), :second)
    |> DateTime.to_unix()
    |> Integer.to_string()
  end

  defp parse_slack_timestamp(nil), do: DateTime.utc_now()

  defp parse_slack_timestamp(value) when is_binary(value) do
    seconds =
      value
      |> String.split(".", parts: 2)
      |> List.first()
      |> case do
        nil ->
          0

        text ->
          case Integer.parse(text) do
            {parsed, _} -> parsed
            _ -> 0
          end
      end

    DateTime.from_unix!(seconds)
  rescue
    _ -> DateTime.utc_now()
  end

  defp parse_slack_timestamp(_value), do: DateTime.utc_now()

  defp infer_deadline_from_text(text, reference_at) when is_binary(text) do
    base = reference_at || DateTime.utc_now()

    cond do
      String.contains?(text, "today") or String.contains?(text, "eod") or
          String.contains?(text, "end of day") ->
        end_of_day(base)

      String.contains?(text, "tomorrow") ->
        base
        |> DateTime.add(1, :day)
        |> end_of_day()

      true ->
        parse_weekday_deadline(text, base) || parse_iso_date_deadline(text)
    end
  end

  defp infer_deadline_from_text(_text, _reference_at), do: nil

  defp parse_weekday_deadline(text, base) do
    case Regex.run(
           ~r/\b(?:by|before|on)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/,
           text
         ) do
      [_, weekday] ->
        target_weekday = Map.get(@weekday_numbers, weekday)
        current_date = DateTime.to_date(base)
        current_weekday = Date.day_of_week(current_date)

        days_ahead =
          case target_weekday - current_weekday do
            diff when diff < 0 -> diff + 7
            0 -> 7
            diff -> diff
          end

        current_date
        |> Date.add(days_ahead)
        |> end_of_day_date()

      _ ->
        nil
    end
  end

  defp parse_iso_date_deadline(text) do
    case Regex.run(~r/\b(\d{4}-\d{2}-\d{2})\b/, text, capture: :all_but_first) do
      [date_string] ->
        case Date.from_iso8601(date_string) do
          {:ok, date} -> end_of_day_date(date)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp end_of_day(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> end_of_day_date()
  end

  defp end_of_day_date(%Date{} = date) do
    with {:ok, naive} <- NaiveDateTime.new(date, ~T[23:00:00]) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp urgency_priority(nil, base), do: base

  defp urgency_priority(%DateTime{} = due_at, base) do
    hours = DateTime.diff(due_at, DateTime.utc_now(), :hour)

    cond do
      hours < 0 -> max(base, 94)
      hours <= 6 -> max(base, 90)
      hours <= 24 -> max(base, 86)
      true -> base
    end
  end

  defp deadline_phrase(nil), do: ""

  defp deadline_phrase(%DateTime{} = due_at) do
    today = Date.utc_today()
    due_date = DateTime.to_date(due_at)

    cond do
      Date.compare(due_date, today) == :lt ->
        "and it is already overdue"

      due_date == today ->
        "and it is due today"

      due_date == Date.add(today, 1) ->
        "and it is due tomorrow"

      true ->
        "and it is due by #{Date.to_iso8601(due_date)}"
    end
  end

  defp commitment_record(commitment, person, source, deadline, status, evidence, next_action) do
    %{
      "commitment" => commitment,
      "person" => person,
      "source" => source,
      "deadline" => to_iso8601(deadline),
      "status" => status,
      "evidence" => Enum.take(evidence, @max_evidence_points),
      "next_action" => next_action
    }
  end

  defp to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_iso8601(_), do: nil

  defp contains_any?(text, terms) when is_binary(text) do
    Enum.any?(terms, &String.contains?(text, &1))
  end

  defp matched_terms(text, terms) when is_binary(text) do
    terms
    |> Enum.filter(&String.contains?(text, &1))
    |> Enum.uniq()
  end

  defp maybe_append(list, _value, false), do: list
  defp maybe_append(list, value, true), do: list ++ [value]

  defp maybe_add_float(value, amount, true), do: value + amount
  defp maybe_add_float(value, _amount, false), do: value

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp to_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp to_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp to_positive_integer(_value, default), do: default

  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value / 1

  defp to_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp to_float(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_value), do: nil

  defp read_string(attrs, key, default) when is_map(attrs) do
    value = fetch_attr(attrs, key)
    normalize_string(value) || default
  end

  defp read_integer(attrs, key, default) when is_map(attrs) do
    value = fetch_attr(attrs, key)

    cond do
      is_integer(value) ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      true ->
        default
    end
  end

  defp read_float(attrs, key, default) when is_map(attrs) do
    value = fetch_attr(attrs, key)

    cond do
      is_float(value) ->
        value

      is_integer(value) ->
        value / 1

      is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      true ->
        default
    end
  end

  defp read_map(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_bool(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when value in [true, "true", "TRUE", "1"] -> true
      value when value in [false, "false", "FALSE", "0"] -> false
      _ -> default
    end
  end

  defp fetch_attr(attrs, key) when is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(attrs, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp datetime_sort_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp datetime_sort_key(_), do: 0

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []

  defp dm_channel?(channel) when is_binary(channel), do: String.starts_with?(channel, "D")
  defp dm_channel?(_channel), do: false
end
