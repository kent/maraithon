defmodule Maraithon.Followthrough.ConversationContext do
  @moduledoc """
  Classifies provider-native conversation state so follow-through insights can
  distinguish unattended threads from conversations that are already moving.
  """

  @completion_terms [
    "sent",
    "shared",
    "uploaded",
    "attached",
    "here is",
    "here's",
    "done",
    "completed",
    "closed the loop",
    "resolved"
  ]

  @other_owner_terms [
    "i'll handle",
    "i will handle",
    "i'll take",
    "i will take",
    "i'll own",
    "i will own",
    "i'll send",
    "i will send",
    "i'll reply",
    "i will reply",
    "on it",
    "i got this",
    "i've got this"
  ]

  @eta_terms [
    "today",
    "tomorrow",
    "eod",
    "end of day"
  ]

  @doc """
  Builds normalized conversation state for one Gmail thread.
  """
  def from_gmail(messages, trigger_message, opts \\ [])
      when is_list(messages) and is_map(trigger_message) and is_list(opts) do
    self_refs =
      opts
      |> Keyword.get(:self_refs, [])
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    default_owner = Keyword.get(opts, :default_owner, "user_owner")

    messages =
      messages
      |> Enum.map(&normalize_gmail_message(&1, self_refs))
      |> maybe_include_trigger(normalize_gmail_message(trigger_message, self_refs))
      |> sort_and_dedupe()

    trigger = normalize_gmail_message(trigger_message, self_refs)

    classify(messages, trigger, default_owner)
    |> Map.put("provider", "gmail")
    |> Map.put("thread_ref", read_string(trigger_message, "thread_id"))
    |> Map.put("trigger_message_ref", read_string(trigger_message, "message_id"))
  end

  @doc """
  Builds normalized conversation state for one Slack thread or DM history window.
  """
  def from_slack(messages, trigger_message, opts \\ [])
      when is_list(messages) and is_map(trigger_message) and is_list(opts) do
    self_user_ids =
      opts
      |> Keyword.get(:self_user_ids, [])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    default_owner = Keyword.get(opts, :default_owner, "user_owner")

    messages =
      messages
      |> Enum.map(&normalize_slack_message(&1, self_user_ids))
      |> maybe_include_trigger(normalize_slack_message(trigger_message, self_user_ids))
      |> sort_and_dedupe()

    trigger = normalize_slack_message(trigger_message, self_user_ids)

    classify(messages, trigger, default_owner)
    |> Map.put("provider", "slack")
    |> Map.put("thread_ref", slack_thread_ref(trigger_message))
    |> Map.put("trigger_message_ref", read_string(trigger_message, "ts"))
  end

  @doc """
  Applies conversation-state metadata and posture-aware copy to one candidate.
  """
  def apply_to_candidate(candidate, context) when is_map(candidate) and is_map(context) do
    candidate = stringify_keys(candidate)
    posture = read_string(context, "notification_posture", "interrupt_now")
    metadata = read_map(candidate, "metadata")
    detail = read_map(metadata, "detail")
    summary = conversation_summary(context)
    checked_evidence = checked_evidence_items(context)

    candidate =
      candidate
      |> Map.put("metadata", Map.put(metadata, "conversation_context", context))
      |> maybe_put_why_now(summary)
      |> maybe_put_context_brief(summary)
      |> maybe_put_interrupt_flag(posture)
      |> maybe_put_detail(detail, summary, checked_evidence)

    case posture do
      "heads_up" ->
        apply_heads_up_copy(candidate, context)

      _ ->
        candidate
    end
  end

  def conversation_summary(context) when is_map(context) do
    latest_actor = read_string(context, "latest_actor")
    owner_mentioned = read_string(context, "owner_mentioned")
    eta_mentioned = read_string(context, "eta_mentioned")

    case read_string(context, "notification_posture", "interrupt_now") do
      "resolved" ->
        "Later conversation activity appears to close the loop."

      "heads_up" ->
        cond do
          present?(owner_mentioned) and present?(eta_mentioned) ->
            "#{owner_mentioned} has already responded and appears to own the next step with ETA #{eta_mentioned}. The conversation is moving."

          present?(owner_mentioned) ->
            "#{owner_mentioned} has already responded and appears to own the next step. The conversation is moving."

          present?(latest_actor) ->
            "#{latest_actor} has already responded and the conversation is moving."

          true ->
            "Another participant has already responded and the conversation is moving."
        end

      "insufficient_context" ->
        "Conversation context could not be fully evaluated."

      _ ->
        "No later reply or follow-through was found in the conversation."
    end
  end

  defp classify(messages, trigger, default_owner) do
    {prior_messages, later_messages} = partition_messages(messages, trigger)
    self_messages = Enum.filter(messages, &(Map.get(&1, "actor_role") == "self"))
    other_messages = Enum.filter(messages, &(Map.get(&1, "actor_role") == "other"))
    prior_self = Enum.filter(prior_messages, &(Map.get(&1, "actor_role") == "self"))
    prior_other = Enum.filter(prior_messages, &(Map.get(&1, "actor_role") == "other"))
    later_self = Enum.filter(later_messages, &(Map.get(&1, "actor_role") == "self"))
    later_other = Enum.filter(later_messages, &(Map.get(&1, "actor_role") == "other"))
    completion_evidence = completion_evidence(later_messages)
    owner_mentioned = owner_mentioned(later_messages)
    eta_mentioned = eta_mentioned(later_messages)

    momentum_state =
      cond do
        completion_evidence != [] -> "resolved"
        later_messages == [] -> "stalled"
        true -> "active"
      end

    coverage_state =
      cond do
        later_self != [] -> "covered_by_user"
        later_other != [] -> "covered_by_other"
        later_messages == [] -> "uncovered"
        true -> "unknown"
      end

    ownership_state =
      cond do
        present?(owner_mentioned) and owner_mentioned != "you" -> "other_owner"
        coverage_state == "covered_by_other" -> "shared_owner"
        true -> default_owner || "unknown"
      end

    notification_posture =
      cond do
        momentum_state == "resolved" -> "resolved"
        coverage_state == "covered_by_user" -> "resolved"
        coverage_state == "covered_by_other" -> "heads_up"
        later_messages == [] -> "interrupt_now"
        true -> "insufficient_context"
      end

    latest_message = List.last(later_messages)

    %{
      "ownership_state" => ownership_state,
      "momentum_state" => momentum_state,
      "coverage_state" => coverage_state,
      "notification_posture" => notification_posture,
      "latest_actor" => read_string(latest_message, "actor"),
      "latest_actor_role" => read_string(latest_message, "actor_role", "unknown"),
      "latest_activity_at" => to_iso8601(read_datetime(latest_message, "occurred_at")),
      "other_participant_replied" => later_other != [],
      "user_replied" => later_self != [],
      "thread_message_count" => length(messages),
      "self_message_count" => length(self_messages),
      "other_message_count" => length(other_messages),
      "prior_user_participation" => prior_self != [],
      "prior_other_message_count" => length(prior_other),
      "owner_mentioned" => owner_mentioned,
      "eta_mentioned" => eta_mentioned,
      "completion_evidence" => completion_evidence,
      "coverage_evidence" =>
        coverage_evidence(later_messages, later_other, owner_mentioned, eta_mentioned),
      "insufficient_context_reason" =>
        insufficient_context_reason(notification_posture, messages, trigger)
    }
  end

  defp apply_heads_up_copy(candidate, context) do
    actor = read_string(context, "latest_actor", "Someone")
    source = read_string(candidate, "source", "conversation")
    category = read_string(candidate, "category", "general")
    summary = conversation_summary(context)

    title =
      case category do
        "reply_urgent" ->
          "#{humanize_source(source)} thread moving with #{actor}"

        "meeting_follow_up" ->
          "#{humanize_source(source)} follow-up still open, but the thread is moving"

        _ ->
          "#{humanize_source(source)} conversation progressing"
      end

    recommended_action =
      if read_string(context, "ownership_state") == "other_owner" do
        "Monitor the thread and step in only if the current owner slips or the final artifact still depends on you."
      else
        "Monitor the thread and close the final loop if the owner, artifact, or ETA is still yours."
      end

    metadata = read_map(candidate, "metadata")

    candidate
    |> Map.put("title", truncate(title, 180))
    |> Map.put("summary", "#{summary} You may still need to close the final loop.")
    |> Map.put("recommended_action", recommended_action)
    |> Map.update("priority", 78, &max(&1 - 6, 70))
    |> Map.update("confidence", 0.78, &clamp_float(&1 - 0.05))
    |> Map.put(
      "metadata",
      metadata
      |> Map.put(
        "why_now",
        "#{summary} The thread is active, but the final follow-through may still be yours."
      )
      |> Map.put("context_brief", summary)
      |> maybe_adjust_telegram_fit_score()
    )
  end

  defp maybe_adjust_telegram_fit_score(metadata) when is_map(metadata) do
    case fetch_attr(metadata, "telegram_fit_score") do
      value when is_float(value) ->
        Map.put(metadata, "telegram_fit_score", clamp_float(value - 0.05))

      value when is_integer(value) ->
        Map.put(metadata, "telegram_fit_score", clamp_float(value / 1 - 0.05))

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> Map.put(metadata, "telegram_fit_score", clamp_float(parsed - 0.05))
          _ -> metadata
        end

      _ ->
        metadata
    end
  end

  defp maybe_put_why_now(candidate, summary) do
    Map.update(candidate, "metadata", %{}, fn metadata ->
      Map.put_new(metadata, "why_now", summary)
    end)
  end

  defp maybe_put_context_brief(candidate, summary) do
    Map.update(candidate, "metadata", %{}, fn metadata ->
      Map.put(metadata, "context_brief", summary)
    end)
  end

  defp maybe_put_interrupt_flag(candidate, posture) do
    Map.update(candidate, "metadata", %{}, fn metadata ->
      Map.put(metadata, "interrupt_now", posture == "interrupt_now")
    end)
  end

  defp maybe_put_detail(candidate, existing_detail, summary, checked_evidence) do
    detail =
      existing_detail
      |> Map.put("conversation_summary", summary)
      |> Map.put("open_loop_reason", summary)
      |> Map.put("checked_evidence", checked_evidence)

    Map.update(candidate, "metadata", %{}, fn metadata ->
      Map.put(metadata, "detail", detail)
    end)
  end

  defp checked_evidence_items(context) do
    source_ref = read_string(context, "thread_ref")

    (read_list(context, "coverage_evidence") ++ read_list(context, "completion_evidence"))
    |> Enum.uniq()
    |> Enum.map(fn line ->
      %{
        "kind" => "source_evidence",
        "label" => line,
        "source_ref" => source_ref
      }
    end)
  end

  defp coverage_evidence(later_messages, later_other, owner_mentioned, eta_mentioned) do
    latest_other = List.last(later_other)

    []
    |> maybe_append(
      "#{read_string(latest_other, "actor", "Another participant")} replied later in the conversation.",
      latest_other != nil
    )
    |> maybe_append(
      "#{owner_mentioned} appears to own the next step.",
      present?(owner_mentioned) and owner_mentioned != "you"
    )
    |> maybe_append("A later message included ETA #{eta_mentioned}.", present?(eta_mentioned))
    |> maybe_append(
      "Later conversation activity was detected after the triggering message.",
      later_messages != []
    )
    |> Enum.take(3)
  end

  defp completion_evidence(messages) do
    messages
    |> Enum.filter(fn message ->
      contains_any?(read_string(message, "text", ""), @completion_terms)
    end)
    |> Enum.map(fn message ->
      "#{read_string(message, "actor", "Someone")} posted language that looks like completion or delivery."
    end)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  defp owner_mentioned(messages) do
    Enum.find_value(messages, fn message ->
      actor = read_string(message, "actor")
      actor_role = read_string(message, "actor_role")
      text = read_string(message, "text", "")

      cond do
        actor_role == "other" and contains_any?(text, @other_owner_terms) ->
          actor

        Regex.match?(~r/\bowner is\b/i, text) ->
          actor

        true ->
          nil
      end
    end)
  end

  defp eta_mentioned(messages) do
    Enum.find_value(messages, fn message ->
      text = read_string(message, "text", "")

      cond do
        contains_any?(text, @eta_terms) ->
          Enum.find(@eta_terms, &String.contains?(String.downcase(text), &1))

        Regex.match?(~r/\b\d{4}-\d{2}-\d{2}\b/, text) ->
          Regex.run(~r/\b\d{4}-\d{2}-\d{2}\b/, text) |> List.first()

        true ->
          nil
      end
    end)
  end

  defp insufficient_context_reason("insufficient_context", messages, trigger) do
    cond do
      messages == [] -> "No conversation messages were available."
      trigger == %{} -> "Trigger message could not be normalized."
      true -> "Conversation activity was incomplete or ambiguous."
    end
  end

  defp insufficient_context_reason(_posture, _messages, _trigger), do: nil

  defp partition_messages(messages, trigger) do
    trigger_id = read_string(trigger, "id")

    case Enum.find_index(messages, &(read_string(&1, "id") == trigger_id)) do
      nil ->
        trigger_at = read_datetime(trigger, "occurred_at")

        Enum.reduce(messages, {[], []}, fn message, {prior, later} ->
          case {read_datetime(message, "occurred_at"), trigger_at} do
            {%DateTime{} = message_at, %DateTime{} = trigger_at} ->
              case DateTime.compare(message_at, trigger_at) do
                :lt -> {[message | prior], later}
                :gt -> {prior, [message | later]}
                :eq -> {prior, later}
              end

            _ ->
              {prior, later}
          end
        end)
        |> then(fn {prior, later} -> {Enum.reverse(prior), Enum.reverse(later)} end)

      index ->
        {Enum.take(messages, index), Enum.drop(messages, index + 1)}
    end
  end

  defp normalize_gmail_message(message, self_refs) when is_map(message) do
    from = read_string(message, "from")

    %{
      "id" => read_string(message, "message_id"),
      "actor" => primary_contact(from) || from,
      "actor_role" => gmail_actor_role(from, self_refs),
      "text" =>
        [
          read_string(message, "subject"),
          read_string(message, "snippet"),
          from,
          read_string(message, "to")
        ]
        |> Enum.reject(&blank?/1)
        |> Enum.join(" "),
      "occurred_at" => read_datetime(message, "internal_date") || read_datetime(message, "date")
    }
  end

  defp normalize_gmail_message(_message, _self_refs), do: %{}

  defp normalize_slack_message(message, self_user_ids) when is_map(message) do
    user_id = read_string(message, "user_id") || read_string(message, "user")

    %{
      "id" => read_string(message, "ts"),
      "actor" => user_id,
      "actor_role" => slack_actor_role(user_id, self_user_ids),
      "text" => read_string(message, "text", ""),
      "occurred_at" =>
        read_datetime(message, "occurred_at") || parse_slack_timestamp(read_string(message, "ts"))
    }
  end

  defp normalize_slack_message(_message, _self_user_ids), do: %{}

  defp maybe_include_trigger(messages, %{"id" => nil}), do: messages
  defp maybe_include_trigger(messages, %{"id" => ""}), do: messages
  defp maybe_include_trigger(messages, trigger), do: [trigger | messages]

  defp sort_and_dedupe(messages) do
    messages
    |> Enum.reject(&(&1 == %{}))
    |> Enum.reduce(%{}, fn message, acc ->
      id = read_string(message, "id")
      key = if blank?(id), do: Ecto.UUID.generate(), else: id
      Map.put_new(acc, key, message)
    end)
    |> Map.values()
    |> Enum.sort_by(&sort_key/1)
  end

  defp sort_key(message) do
    case read_datetime(message, "occurred_at") do
      %DateTime{} = occurred_at -> {0, DateTime.to_unix(occurred_at, :microsecond)}
      _ -> {1, read_string(message, "id", "")}
    end
  end

  defp gmail_actor_role(from, self_refs) do
    normalized = String.downcase(from || "")

    if Enum.any?(self_refs, fn ref -> ref != "" and String.contains?(normalized, ref) end) do
      "self"
    else
      "other"
    end
  end

  defp slack_actor_role(user_id, self_user_ids) do
    if user_id in self_user_ids, do: "self", else: "other"
  end

  defp slack_thread_ref(message) do
    team_id = read_string(message, "team_id")
    channel_id = read_string(message, "channel_id")
    thread_ts = read_string(message, "thread_ts") || read_string(message, "ts")

    [team_id, channel_id, thread_ts]
    |> Enum.reject(&blank?/1)
    |> Enum.join(":")
  end

  defp primary_contact(value) when is_binary(value) do
    case Regex.run(~r/^\s*([^<]+)\s*</, value, capture: :all_but_first) do
      [display_name] ->
        normalize_text(display_name)

      _ ->
        case Regex.run(~r/([^,<@\s]+@[^,>\s]+)/, value, capture: :all_but_first) do
          [email] -> email
          _ -> normalize_text(value)
        end
    end
  end

  defp primary_contact(_value), do: nil

  defp contains_any?(value, terms) when is_binary(value) do
    normalized = String.downcase(value)
    Enum.any?(terms, &String.contains?(normalized, &1))
  end

  defp contains_any?(_value, _terms), do: false

  defp maybe_append(list, value, true), do: list ++ [value]
  defp maybe_append(list, _value, false), do: list

  defp humanize_source("gmail"), do: "Gmail"
  defp humanize_source("slack"), do: "Slack"
  defp humanize_source(value) when is_binary(value), do: String.capitalize(value)
  defp humanize_source(_value), do: "Conversation"

  defp clamp_float(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp clamp_float(value) when is_integer(value), do: clamp_float(value / 1)
  defp clamp_float(_value), do: 0.0

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) <= max, do: value, else: String.slice(value, 0, max - 3) <> "..."
  end

  defp read_string(map, key, default \\ nil) do
    case fetch_attr(map, key) do
      value when is_binary(value) ->
        normalize_text(value) || default

      value when is_atom(value) ->
        value |> Atom.to_string() |> normalize_text() || default

      _ ->
        default
    end
  end

  defp read_map(map, key) do
    case fetch_attr(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_list(map, key) do
    case fetch_attr(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp read_datetime(map, key) do
    case fetch_attr(map, key) do
      %DateTime{} = value ->
        value

      %NaiveDateTime{} = value ->
        DateTime.from_naive!(value, "Etc/UTC")

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_iso8601(_value), do: nil

  defp parse_slack_timestamp(nil), do: nil

  defp parse_slack_timestamp(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _rest} ->
        whole_seconds = trunc(seconds)
        microseconds = trunc((seconds - whole_seconds) * 1_000_000)
        DateTime.from_unix!(whole_seconds * 1_000_000 + microseconds, :microsecond)

      _ ->
        nil
    end
  end

  defp parse_slack_timestamp(_value), do: nil

  defp fetch_attr(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case maybe_existing_atom(key) do
          nil -> nil
          atom_key -> Map.get(map, atom_key)
        end
    end
  end

  defp fetch_attr(_map, _key), do: nil

  defp maybe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> nil
  end

  defp stringify_keys(value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, %{}, fn {key, item}, acc ->
      normalized_key =
        cond do
          is_binary(key) -> key
          is_atom(key) -> Atom.to_string(key)
          true -> to_string(key)
        end

      Map.put(acc, normalized_key, stringify_keys(item))
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp blank?(value), do: is_nil(normalize_text(to_string_safe(value)))

  defp to_string_safe(nil), do: nil
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(_value), do: nil

  defp present?(value), do: not blank?(value)
end
