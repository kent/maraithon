defmodule Maraithon.Todos.UserFacingCopy do
  @moduledoc """
  Polishes user-facing todo copy before it is stored or resurfaced.

  This is intentionally deterministic and conservative. Model and source
  pipelines should generate rich copy themselves, but this boundary prevents
  obviously non-human phrasing like "User committed..." from leaking into
  Telegram, mobile, or the web app.
  """

  @generic_subjects MapSet.new([
                      "(no subject)",
                      "no subject",
                      "quick follow-up",
                      "quick follow up",
                      "follow-up",
                      "follow up",
                      "checking in",
                      "re",
                      "fw",
                      "fwd"
                    ])

  @product_user_contexts ~w(
    account accounts base cohort cohorts community count dashboard dashboards data email emails
    event events experience feedback flow flows funnel growth guide guides interface interview
    interviews journey journeys list lists login manual manuals message messages metric metrics
    name names onboarding page pages permission permissions persona personas plan plans
    preference preferences profile profiles record records research role roles screen screens
    segment segments session sessions setting settings sign-up signup story stories test tests
    testing
  )
  @product_user_context_pattern Enum.join(@product_user_contexts, "|")
  # Bare "the user" only becomes "you" when it reads as the subject of an
  # internal status sentence; rewriting every occurrence mangled product
  # copy like "the user manual" or "the user base".
  @user_subject_verbs ~w(
    is was has had hasn't needs wants should must owes owed asked committed
    promised replied responded said sent will can cannot does doesn't didn't
  )
  @user_subject_verb_pattern Enum.join(@user_subject_verbs, "|")
  @the_user_possessive_reference ~r/\bthe user's\b(?![-\s]+(?:#{@product_user_context_pattern})\b)/i
  @the_user_reference ~r/\bthe user\b(?=\s+(?:#{@user_subject_verb_pattern})\b|\s*[.,;:!?)]|\s*$)/i
  @user_possessive_reference ~r/\buser's\b(?![-\s]+(?:#{@product_user_context_pattern})\b)/i
  @the_operator_reference ~r/\bthe operator\b(?=\s+(?:#{@user_subject_verb_pattern})\b|\s*[.,;:!?)]|\s*$)/i
  @safe_label_prefix ~r/^\s*(?:source[_ ]context|context[_ ]brief|context|why[_ ]now|why[_ ]it[_ ]matters|next[_ ]best[_ ]action|next[_ ]action|decision[_ ]prompt|decision|evidence[_ ]excerpt|evidence|summary)\s*[:=-]\s*/i

  # Human-authored work keeps its wording, including intentional product terms
  # and line breaks. Partial updates may supply the persisted source as context.
  def polish_attrs(attrs, fallback_source \\ nil)

  def polish_attrs(attrs, fallback_source) when is_map(attrs) do
    if (read_field(attrs, "source") || fallback_source) in ["manual", "mobile"],
      do: attrs,
      else: polish_generated_attrs(attrs)
  end

  def polish_attrs(attrs, _fallback_source), do: attrs

  defp polish_generated_attrs(attrs) do
    attrs
    |> polish_text_field("title")
    |> polish_text_field("summary")
    |> polish_text_field("next_action")
    |> polish_text_field("recommended_action")
    |> polish_text_field("notes")
    |> polish_text_field("action_plan")
    |> maybe_rewrite_generic_commitment_copy()
  end

  def polish_text(value) when is_binary(value) do
    value
    |> strip_model_internal_copy()
    |> strip_safe_label_prefixes()
    |> strip_internal_label_lines()
    |> replace_internal_source_labels()
    |> replace_operator_jargon()
    |> replace_generic_user_action_language()
    |> replace_direct_role_language()
    |> replace_todo_language()
    |> single_line()
  end

  def polish_text(value), do: value

  def open_work_language(value, opts \\ [])

  def open_work_language(value, opts) when is_binary(value) and is_list(opts) do
    value
    |> strip_model_internal_copy()
    |> maybe_strip_safe_label_prefixes(opts)
    |> replace_operator_jargon()
    |> replace_generic_user_action_language()
    |> replace_direct_role_language()
    |> replace_todo_language()
  end

  def open_work_language(value, _opts), do: value

  defp replace_generic_user_action_language(value) do
    value
    |> String.replace(
      ~r/\bDecide whether to send the ([^.,;]+?) owner and ETA\.?/i,
      "Send the \\1 update with a clear owner and timing."
    )
    |> String.replace(
      ~r/\bReply now with owner, ETA, and the exact artifact or update you committed to\.?/i,
      "Reply with the promised update, current status, and timing you can stand behind."
    )
    |> String.replace(
      ~r/\bReply now with owner and ETA\.?/i,
      "Reply with a clear owner and timing."
    )
    |> String.replace(
      ~r/\bwith status, owner, and ETA\b/i,
      "with current status, a clear owner, and timing"
    )
    |> String.replace(
      ~r/\bwith owner, ETA, and\b/i,
      "with a clear owner, timing, and"
    )
    |> String.replace(
      ~r/\bwith owner, ETA\b/i,
      "with a clear owner and timing"
    )
    |> String.replace(
      ~r/\bwith a clear owner and ETA\b/i,
      "with a clear owner and timing"
    )
    |> String.replace(~r/\bwith owner and ETA\b/i, "with a clear owner and timing")
    |> String.replace(~r/\bwith the owner and ETA\b/i, "with a clear owner and timing")
    |> String.replace(
      ~r/\bNo later reply or follow[- ]?through was found in the conversation\.?/i,
      "No later reply or delivery is recorded."
    )
    |> String.replace(
      ~r/\bNo later reply or delivery was found\.?/i,
      "No later reply or delivery is recorded."
    )
    |> String.replace(
      ~r/\s+and no later reply was found\.?/i,
      "; no later reply is recorded."
    )
    |> String.replace(
      ~r/\bNo later reply was found\.?/i,
      "No later reply is recorded."
    )
    |> String.replace(
      ~r/\bclose the final loop\b/i,
      "handle the remaining follow-through"
    )
    |> String.replace(
      ~r/\bown the final loop\b/i,
      "own the remaining follow-through"
    )
    |> String.replace(~r/\bfinal loop\b/i, "remaining follow-through")
    |> String.replace(~r/\bclose the Slack loop with\b/i, "send the Slack follow-through to")
    |> String.replace(~r/\bclose the loop with\b/i, "send the follow-through to")
    |> String.replace(~r/\bclose the loop\b/i, "send the follow-through")
    |> String.replace(~r/\bopen loops\b/i, "open follow-ups")
    |> String.replace(~r/\bopen loop\b/i, "open follow-up")
    |> String.replace(~r/\breply loops\b/i, "reply threads")
    |> String.replace(
      ~r/\bThis((?:\s+\w+)?\s+thread)\s+still\s+needs\s+a\s+reply\s+from\s+(?:the\s+user|you)\.?/i,
      "This\\1 is waiting on your reply."
    )
    |> String.replace(
      ~r/\bThis((?:\s+\w+)?\s+thread)\s+still\s+needs\s+(?:your\s+reply|a\s+user\s+response)\.?/i,
      "This\\1 is waiting on your reply."
    )
    |> String.replace(~r/\bneeds a user response\b/i, "needs your reply")
    |> String.replace(~r/\bneeds user response\b/i, "needs your reply")
    |> String.replace(~r/\brequires a user response\b/i, "needs your reply")
    |> String.replace(~r/\bwaiting for a user response\b/i, "waiting on your reply")
    |> String.replace(~r/\bawaiting a user response\b/i, "waiting on your reply")
    |> String.replace(~r/\bneeds a user decision\b/i, "needs your decision")
    |> String.replace(~r/\bneeds user decision\b/i, "needs your decision")
    |> String.replace(~r/\brequires a user decision\b/i, "needs your decision")
  end

  defp replace_direct_role_language(value) do
    value
    |> String.replace(~r/^\s*The user committed\b/i, "You committed")
    |> String.replace(~r/\bthe user committed\b/i, "you committed")
    |> String.replace(~r/^\s*The user wants\b/i, "You want")
    |> String.replace(~r/\bthe user wants\b/i, "you want")
    |> String.replace(~r/^\s*The user needs\b/i, "You need")
    |> String.replace(~r/\bthe user needs\b/i, "you need")
    |> String.replace(~r/^\s*The user has\b/i, "You have")
    |> String.replace(~r/\bthe user has\b/i, "you have")
    |> String.replace(~r/^\s*The user is\b/i, "You are")
    |> String.replace(~r/\bthe user is\b/i, "you are")
    |> String.replace(~r/^\s*The user should\b/i, "You should")
    |> String.replace(~r/\bthe user should\b/i, "you should")
    |> String.replace(~r/^\s*The user asked\b/i, "You asked")
    |> String.replace(~r/\bthe user asked\b/i, "you asked")
    |> String.replace(~r/^\s*The user owes\b/i, "You owe")
    |> String.replace(~r/\bthe user owes\b/i, "you owe")
    |> String.replace(~r/^\s*User committed\b/i, "You committed")
    |> String.replace(~r/\bUser committed\b/i, "you committed")
    |> String.replace(~r/^\s*User wants\b/i, "You want")
    |> String.replace(~r/\bUser wants\b/i, "you want")
    |> String.replace(~r/^\s*User needs\b/i, "You need")
    |> String.replace(~r/\bUser needs\b/i, "you need")
    |> String.replace(~r/^\s*User has\b/i, "You have")
    |> String.replace(~r/\bUser has\b/i, "you have")
    |> String.replace(~r/^\s*User is\b/i, "You are")
    |> String.replace(~r/\bUser is\b/i, "you are")
    |> String.replace(~r/^\s*User should\b/i, "You should")
    |> String.replace(~r/\bUser should\b/i, "you should")
    |> String.replace(~r/^\s*User asked\b/i, "You asked")
    |> String.replace(~r/\bUser asked\b/i, "you asked")
    |> String.replace(~r/^\s*User owes\b/i, "You owe")
    |> String.replace(~r/\bUser owes\b/i, "you owe")
    |> String.replace(@the_user_possessive_reference, "your")
    |> String.replace(@the_user_reference, "you")
    |> String.replace(@user_possessive_reference, "your")
    |> String.replace(~r/\boperator attention\b/i, "your attention")
    |> String.replace(~r/^\s*The operator's\b/i, "Your")
    |> String.replace(~r/\bthe operator's\b/i, "your")
    |> String.replace(~r/^\s*Operator's\b/i, "Your")
    |> String.replace(@the_operator_reference, "you")
    |> String.replace(~r/\bKent's attention\b/i, "your attention")
    |> String.replace(~r/^\s*Kent needs\b/i, "You need")
    |> String.replace(~r/\bKent needs\b/i, "you need")
    |> String.replace(~r/^\s*Kent should\b/i, "You should")
    |> String.replace(~r/\bKent should\b/i, "you should")
    |> String.replace(~r/^\s*Kent has\b/i, "You have")
    |> String.replace(~r/\bKent has\b/i, "you have")
    |> String.replace(~r/^\s*Kent asked\b/i, "You asked")
    |> String.replace(~r/\bKent asked\b/i, "you asked")
    |> String.replace(~r/^\s*Kent owes\b/i, "You owe")
    |> String.replace(~r/\bKent owes\b/i, "you owe")
    |> String.replace(~r/^\s*Kent committed\b/i, "You committed")
    |> String.replace(~r/\bKent committed\b/i, "you committed")
  end

  defp replace_todo_language(value) do
    value
    |> String.replace(
      ~r/^\s*No open (?:work|todos?) (?:found|matched this request)\.?\s*$/i,
      "No saved open work matched this request."
    )
    |> String.replace(
      ~r/^\s*This check surfaced no open work\.?\s*$/i,
      "No saved open work matched this request."
    )
    |> String.replace(~r/\bopen todo list\b/i, "open work")
    |> String.replace(~r/\bopen todos\b/i, "open work")
    |> String.replace(~r/\bopen todo\b/i, "open work item")
    |> String.replace(~r/\btodo list\b/i, "open work")
    |> String.replace(~r/\btodos\b/i, "work items")
    |> String.replace(~r/\btodo\b/i, "work item")
    |> String.replace(
      ~r/\bwork item still needs a reply\b/i,
      "work item is waiting on your reply"
    )
  end

  defp maybe_rewrite_generic_commitment_copy(attrs) do
    summary = read_string(attrs, "summary")
    title = read_string(attrs, "title")
    next_action = read_string(attrs, "next_action") || read_string(attrs, "recommended_action")
    action_plan = read_string(attrs, "action_plan")

    if generic_commitment_copy?(summary) or generic_commitment_copy?(title) or
         generic_next_action?(next_action) or generic_action_plan?(action_plan) do
      context = context(attrs)

      attrs
      |> maybe_put_rewritten_title(context)
      |> maybe_put_rewritten_summary(context)
      |> maybe_put_rewritten_next_action(context)
      |> maybe_put_rewritten_action_plan(context)
    else
      attrs
    end
  end

  defp maybe_put_rewritten_title(attrs, context) do
    title = read_string(attrs, "title")

    if generic_commitment_copy?(title) do
      put_field(attrs, "title", title_for(context))
    else
      attrs
    end
  end

  defp maybe_put_rewritten_summary(attrs, context) do
    summary = read_string(attrs, "summary")

    if generic_commitment_copy?(summary) do
      put_field(attrs, "summary", summary_for(context))
    else
      attrs
    end
  end

  defp maybe_put_rewritten_next_action(attrs, context) do
    field =
      cond do
        read_string(attrs, "next_action") -> "next_action"
        read_string(attrs, "recommended_action") -> "recommended_action"
        true -> "next_action"
      end

    next_action = read_string(attrs, field)

    if generic_next_action?(next_action) do
      replacement =
        if draft_action?(next_action),
          do: draft_next_action_for(context),
          else: next_action_for(context)

      put_field(attrs, field, replacement)
    else
      attrs
    end
  end

  defp maybe_put_rewritten_action_plan(attrs, context) do
    action_plan = read_string(attrs, "action_plan")

    if generic_action_plan?(action_plan) do
      put_field(attrs, "action_plan", action_plan_for(context))
    else
      attrs
    end
  end

  defp context(attrs) do
    metadata = read_map(attrs, "metadata")
    record = read_map(metadata, "record")
    detail = read_map(metadata, "detail")
    conversation_context = read_map(metadata, "conversation_context")
    person_context = first_person_context(metadata)

    person =
      first_present([
        read_string(record, "person"),
        read_string(metadata, "person"),
        read_string(detail, "requested_by"),
        read_string(person_context, "display_name"),
        read_string(person_context, "name"),
        read_string(metadata, "requested_by"),
        read_string(metadata, "sender_name"),
        contact_name(read_string(attrs, "owner_label")),
        contact_name(read_string(metadata, "to")),
        contact_name(read_string(metadata, "from"))
      ])

    company =
      first_present([
        read_string(record, "company"),
        read_string(record, "organization"),
        read_string(metadata, "company"),
        read_string(metadata, "organization"),
        read_string(metadata, "org"),
        read_string(person_context, "company"),
        read_string(person_context, "organization"),
        read_string(metadata, "account_name"),
        domain_company(read_string(metadata, "from")),
        domain_company(read_string(metadata, "to")),
        domain_company(read_string(metadata, "email"))
      ])

    relationship =
      first_present([
        read_string(record, "relationship_context"),
        read_string(record, "relationship"),
        read_string(metadata, "relationship_context"),
        read_string(metadata, "relationship"),
        read_string(person_context, "relationship_context"),
        read_string(person_context, "relationship")
      ])

    topic =
      first_present([
        subject_topic(read_string(metadata, "subject")),
        subject_topic(read_string(metadata, "thread_subject")),
        subject_topic(read_string(metadata, "email_subject")),
        subject_topic(read_string(metadata, "message_subject")),
        subject_topic(read_string(metadata, "source_subject")),
        subject_topic(read_string(record, "subject")),
        subject_topic(read_string(detail, "subject")),
        subject_topic(read_string(attrs, "title")),
        subject_topic(read_string(record, "title")),
        subject_topic(read_string(detail, "title")),
        commitment_topic(read_string(record, "commitment")),
        commitment_topic(read_string(detail, "promise_text")),
        commitment_topic(read_string(metadata, "commitment")),
        source_topic(read_string(metadata, "source_title")),
        source_topic(read_string(metadata, "source_item_title")),
        source_topic(read_string(metadata, "body_excerpt")),
        source_topic(first_evidence(record)),
        source_topic(first_source_evidence(metadata))
      ])

    why =
      first_present([
        human_context(read_string(metadata, "why_it_matters")),
        human_context(read_string(metadata, "why_now")),
        human_context(read_string(metadata, "context_brief")),
        human_context(read_string(metadata, "reasoning_summary")),
        human_context(read_string(record, "reasoning_summary")),
        human_context(read_string(record, "reason")),
        human_context(read_string(detail, "why")),
        human_context(read_string(conversation_context, "summary")),
        human_context(first_string_list(conversation_context, "coverage_evidence")),
        human_context(first_string_list(conversation_context, "completion_evidence")),
        human_context(read_string(record, "summary")),
        human_context(first_evidence(record)),
        human_context(first_source_evidence(metadata)),
        human_context(read_string(metadata, "quote")),
        human_context(read_string(metadata, "source_quote")),
        human_context(read_string(metadata, "snippet")),
        human_context(read_string(metadata, "body_excerpt"))
      ])

    %{
      person: person,
      company: company,
      relationship: relationship,
      topic: topic,
      why: why
    }
  end

  defp title_for(context) do
    person = context.person || "the recipient"

    case context.topic do
      topic when is_binary(topic) -> "Follow up with #{person} about #{topic}"
      _ -> "Clarify the follow-up with #{person}"
    end
    |> truncate(140)
  end

  defp summary_for(context) do
    person = identity_label(context)
    topic = topic_phrase(context.topic)

    [
      "You committed to follow up with #{person}#{topic}.",
      context.why && "Context: #{context.why}.",
      "No later reply or delivery is recorded."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> truncate(500)
  end

  defp next_action_for(context) do
    person = context.person || "the recipient"

    case context.topic do
      topic when is_binary(topic) ->
        "Reply to #{person} about #{topic} with the promised update, current status, and the next timing you can safely commit to."

      _ ->
        "Open the source thread for #{person}, confirm what they need and what you promised, then reply with the next step and timing."
    end
  end

  defp draft_next_action_for(context) do
    person = context.person || "the recipient"

    case context.topic do
      topic when is_binary(topic) ->
        "Draft a reply to #{person} about #{topic} with the promised update, current status, and the next timing you can safely commit to."

      _ ->
        "Draft a reply to #{person} after confirming the specific request, what you promised, and the next timing you can safely commit to."
    end
  end

  defp action_plan_for(context) do
    person = context.person || "the recipient"

    case context.topic do
      topic when is_binary(topic) ->
        "Draft in your voice: reply to #{person} about #{topic} with the actual promise, current status, and timing you can safely stand behind."

      _ ->
        "Draft in your voice: open the source thread, confirm the specific request, then write the shortest useful reply with the next step and evidence-backed timing."
    end
  end

  defp identity_label(%{person: person, company: company, relationship: relationship})
       when is_binary(person) and is_binary(company) and is_binary(relationship) do
    cond do
      present?(company) and present?(relationship) ->
        "#{person} (#{company}; #{truncate(relationship, 72)})"

      present?(company) ->
        "#{person} (#{company})"

      present?(relationship) ->
        "#{person} (#{truncate(relationship, 72)})"

      true ->
        person
    end
  end

  defp identity_label(%{person: person, company: company})
       when is_binary(person) and is_binary(company) do
    if present?(company), do: "#{person} (#{company})", else: person
  end

  defp identity_label(%{person: person, relationship: relationship})
       when is_binary(person) and is_binary(relationship) do
    if present?(relationship), do: "#{person} (#{truncate(relationship, 72)})", else: person
  end

  defp identity_label(%{person: person}) when is_binary(person), do: person

  defp identity_label(_context), do: "the recipient"

  defp topic_phrase(nil), do: ""
  defp topic_phrase(topic), do: " about #{topic}"

  defp generic_commitment_copy?(value) when is_binary(value) do
    text = value |> String.trim() |> String.downcase()

    not String.starts_with?(text, "thread:") and
      (String.match?(text, ~r/\b(user|you)\s+committed\s+to\s+follow[- ]?up\b/) or
         String.contains?(text, "follow-up not yet sent") or
         String.contains?(text, "follow up not yet sent") or
         String.match?(text, ~r/no later reply or follow[- ]?through/) or
         String.contains?(text, "no later reply or delivery clearly closes the loop") or
         String.contains?(text, "no later reply or delivery is recorded") or
         String.contains?(text, "no later reply is recorded") or
         String.contains?(text, "no sent follow-up") or
         String.contains?(text, "commitment still appears open") or
         String.contains?(text, "the commitment still appears open") or
         String.contains?(text, "no completion evidence was found"))
  end

  defp generic_commitment_copy?(_value), do: false

  defp generic_next_action?(value) when is_binary(value) do
    text = String.downcase(value)

    String.contains?(text, "exact artifact or update you committed to") or
      String.contains?(text, "promised update, current status, and timing you can stand behind") or
      String.contains?(text, "with owner, eta, and") or
      String.contains?(text, "with owner and eta.") or
      String.contains?(text, "with owner, next step") or
      String.contains?(text, "current status, exact artifact") or
      String.contains?(text, "promised follow-through now") or
      String.contains?(text, "review and decide the next step") or
      String.contains?(text, "open this item and decide whether it still needs action")
  end

  defp generic_next_action?(_value), do: false

  defp draft_action?(value) when is_binary(value) do
    String.contains?(String.downcase(value), "draft")
  end

  defp draft_action?(_value), do: false

  defp generic_action_plan?(value) when is_binary(value) do
    text = String.downcase(value)

    String.contains?(text, "direct answer, owner, next step, and eta") or
      String.contains?(text, "owner, next step, and eta") or
      String.contains?(text, "owner, current status") or
      String.contains?(text, "current status, exact artifact") or
      String.contains?(text, "owner, and eta")
  end

  defp generic_action_plan?(_value), do: false

  defp polish_text_field(attrs, field) do
    case read_string(attrs, field) do
      nil -> attrs
      value -> put_field(attrs, field, polish_text(value))
    end
  end

  defp subject_topic(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/^\s*(re|fw|fwd):\s*/i, "")
    |> title_topic()
    |> String.replace(~r/\s+/, " ")
    |> String.trim(~s("'))
    |> normalize_topic()
  end

  defp subject_topic(_value), do: nil

  defp title_topic(value) when is_binary(value) do
    cond do
      captures = Regex.run(~r/\bon\s+"([^"]+)"/i, value, capture: :all_but_first) ->
        List.first(captures)

      captures = Regex.run(~r/\babout\s+"?([^".]+)"?\.?$/i, value, capture: :all_but_first) ->
        List.first(captures)

      captures =
          Regex.run(~r/\bfollow[- ]?up\s+with\s+.+?\s+on\s+"?([^".]+)"?\.?$/i, value,
            capture: :all_but_first
          ) ->
        List.first(captures)

      captures =
          Regex.run(~r/\breply\s+to\s+.+?\s+on\s+"?([^".]+)"?\.?$/i, value,
            capture: :all_but_first
          ) ->
        List.first(captures)

      true ->
        value
    end
  end

  defp title_topic(value), do: value

  defp commitment_topic(value) when is_binary(value) do
    value
    |> polish_text()
    |> String.replace(~r/^\s*you committed to follow[- ]?up with\s+[^.;]+[.;]?\s*/i, "")
    |> String.replace(~r/^\s*follow through on\s+/i, "")
    |> String.replace(~r/^\s*reply to\s+[^"]+\s+on\s+/i, "")
    |> String.trim()
    |> String.trim(~s("'))
    |> normalize_topic()
  end

  defp commitment_topic(_value), do: nil

  defp source_topic(value) when is_binary(value) do
    value
    |> polish_text()
    |> String.replace(~r/^\s*(subject|re|fw|fwd)\s*:\s*/i, "")
    |> String.replace(~r/^\s*(you|i)\s+(committed|promised|owe)\s+/i, "")
    |> String.replace(~r/^\s*(can you|could you|please|pls)\s+/i, "")
    |> String.replace(
      ~r/^\s*(send|share|provide|confirm|reply with|reply about)\s+(the\s+)?/i,
      ""
    )
    |> String.replace(~r/\s+with\s+(the )?(promised update|current status|next timing).*/i, "")
    |> String.trim()
    |> String.trim(~s("'))
    |> normalize_topic()
  end

  defp source_topic(_value), do: nil

  defp normalize_topic(value) when is_binary(value) do
    value = value |> String.trim() |> truncate(120)

    cond do
      value == "" -> nil
      MapSet.member?(@generic_subjects, String.downcase(value)) -> nil
      generic_commitment_copy?(value) -> nil
      true -> value
    end
  end

  defp normalize_topic(_value), do: nil

  defp human_context(value) when is_binary(value) do
    value =
      value
      |> polish_text()
      |> String.trim()
      |> String.trim_trailing(".")

    cond do
      value == "" -> nil
      generic_commitment_copy?(value) -> nil
      String.match?(String.downcase(value), ~r/^no (later )?(reply|follow)/) -> nil
      String.match?(String.downcase(value), ~r/^sent commitment email/) -> nil
      true -> truncate(value, 220)
    end
  end

  defp human_context(_value), do: nil

  defp first_evidence(record) when is_map(record) do
    case read_field(record, "evidence") do
      [first | _] when is_binary(first) -> first
      [%{} = first | _] -> evidence_text(first)
      _ -> nil
    end
  end

  defp first_evidence(_record), do: nil

  defp first_source_evidence(metadata) when is_map(metadata) do
    case read_field(metadata, "source_evidence") || read_field(metadata, "evidence") do
      value when is_binary(value) -> value
      [first | _] when is_binary(first) -> first
      [%{} = first | _] -> evidence_text(first)
      %{} = item -> evidence_text(item)
      _ -> nil
    end
  end

  defp first_source_evidence(_metadata), do: nil

  defp evidence_text(item) when is_map(item) do
    item = stringify_keys(item)

    first_present([
      read_string(item, "quote"),
      read_string(item, "detail"),
      read_string(item, "text"),
      read_string(item, "body"),
      read_string(item, "snippet"),
      read_string(item, "summary")
    ])
  end

  defp evidence_text(_item), do: nil

  defp first_string_list(map, key) when is_map(map) do
    case read_field(map, key) do
      [first | _] when is_binary(first) -> first
      [%{} = first | _] -> evidence_text(first)
      _ -> nil
    end
  end

  defp first_string_list(_map, _key), do: nil

  defp first_person_context(metadata) when is_map(metadata) do
    case read_field(metadata, "crm_people") || read_field(metadata, "people") do
      [%{} = person | _] -> normalize_person_context(person)
      %{} = person -> normalize_person_context(person)
      _ -> %{}
    end
  end

  defp first_person_context(_metadata), do: %{}

  defp normalize_person_context(person) when is_map(person) do
    person = stringify_keys(person)

    if present?(read_string(person, "name")) or present?(read_string(person, "display_name")) do
      person
    else
      name =
        [read_string(person, "first_name"), read_string(person, "last_name")]
        |> Enum.reject(&blank?/1)
        |> Enum.join(" ")
        |> normalize_person_name()

      if present?(name), do: Map.put(person, "name", name), else: person
    end
  end

  defp contact_name(value) when is_binary(value) do
    value
    |> String.split(~r/[;,]/, trim: true)
    |> List.first()
    |> case do
      nil ->
        nil

      first ->
        first = String.trim(first)

        case Regex.run(~r/^\s*([^<]+?)\s*<[^>]+>\s*$/, first, capture: :all_but_first) do
          [name] -> normalize_person_name(name)
          _ -> nil
        end
    end
  end

  defp contact_name(_value), do: nil

  defp normalize_person_name(name) when is_binary(name) do
    name = String.trim(name)
    if name == "" or String.contains?(name, "@"), do: nil, else: name
  end

  defp domain_company(value) when is_binary(value) do
    value
    |> String.split(~r/[;,]/, trim: true)
    |> List.first()
    |> email_domain()
    |> company_from_domain()
  end

  defp domain_company(_value), do: nil

  defp email_domain(value) when is_binary(value) do
    case Regex.run(~r/@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/, value, capture: :all_but_first) do
      [domain] -> domain |> String.downcase() |> String.trim(".")
      _ -> nil
    end
  end

  defp email_domain(_value), do: nil

  defp company_from_domain(nil), do: nil

  defp company_from_domain(domain) when is_binary(domain) do
    parts =
      domain
      |> String.split(".", trim: true)
      |> Enum.reject(&(&1 in ["mail", "email", "mx", "smtp", "www"]))

    root =
      case parts do
        [] -> nil
        [single] -> single
        parts -> Enum.at(parts, -2)
      end

    cond do
      root in [
        nil,
        "",
        "example",
        "gmail",
        "googlemail",
        "icloud",
        "me",
        "mac",
        "yahoo",
        "outlook",
        "hotmail",
        "aol",
        "proton",
        "hey",
        "fastmail"
      ] ->
        nil

      true ->
        root
        |> String.replace(~r/[-_]+/, " ")
        |> String.split(" ", trim: true)
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp first_present(values) do
    Enum.find(values, &present?/1)
  end

  defp read_map(map, key) when is_map(map) do
    case read_field(map, key) do
      value when is_map(value) -> stringify_keys(value)
      _ -> %{}
    end
  end

  defp read_string(map, key) do
    case read_field(map, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) or is_float(value) ->
        to_string(value)

      _ ->
        nil
    end
  end

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp read_field(_map, _key), do: nil

  defp put_field(map, key, value) when is_map(map) and is_binary(key) do
    atom_key = existing_atom_key(key)

    cond do
      atom_key && Map.has_key?(map, atom_key) -> Map.put(map, atom_key, value)
      Map.has_key?(map, key) -> Map.put(map, key, value)
      true -> Map.put(map, key, value)
    end
  end

  defp existing_atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank?(value), do: not present?(value)

  defp strip_internal_label_lines(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.reject(&internal_label_line?/1)
    |> Enum.join(" ")
  end

  defp internal_label_line?(line) when is_binary(line) do
    String.match?(
      line,
      ~r/^\s*(from|source|priority|status|open|title|kind|ref|reference|direction|origin|cadence)\s*:/i
    )
  end

  defp strip_safe_label_prefixes(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.map(&strip_safe_label_prefix/1)
    |> Enum.join("\n")
  end

  defp maybe_strip_safe_label_prefixes(text, opts) do
    if Keyword.get(opts, :strip_safe_label_prefixes, true) do
      strip_safe_label_prefixes(text)
    else
      text
    end
  end

  defp strip_safe_label_prefix(line) do
    {stripped, changed?} =
      Enum.reduce_while(1..3, {line, false}, fn _, {current, changed?} ->
        next = Regex.replace(@safe_label_prefix, current, "", global: false)

        if next == current do
          {:halt, {current, changed?}}
        else
          {:cont, {next, true}}
        end
      end)

    stripped = String.trim(stripped)

    if changed? do
      capitalize_action_start(stripped)
    else
      stripped
    end
  end

  defp capitalize_action_start(""), do: ""

  defp capitalize_action_start(text) do
    if String.match?(
         text,
         ~r/^(reply|send|ask|confirm|book|review|decide|open|draft|call|text|schedule|choose|check|write|share|approve|update|follow|make|handle|finish|pay|order|prepare|forward|renew|mark)\b/
       ) do
      <<first::utf8, rest::binary>> = text
      String.upcase(<<first::utf8>>) <> rest
    else
      text
    end
  end

  defp strip_model_internal_copy(text) when is_binary(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.map(&strip_model_internal_fragments/1)
    |> Enum.reject(&model_internal_line?/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp strip_model_internal_fragments(line) when is_binary(line) do
    line
    |> String.replace(~r/^\s*\d{1,3}%\s+confidence\b[^.!?\n]*(?:[.!?]\s*|$)/iu, "")
    |> String.replace(~r/^\s*confidence\s+(?:this|that|was|is)\b[^.!?\n]*(?:[.!?]\s*|$)/iu, "")
    |> String.replace(
      ~r/^\s*model\s+(?:classified|confidence|ranked|reasoning|saw|score)\b[^.!?\n]*(?:[.!?]\s*|$)/iu,
      ""
    )
    |> String.replace(~r/^\s*score\s+(?:says|was|is)\b[^.!?\n]*(?:[.!?]\s*|$)/iu, "")
    |> String.replace(~r/^\s*reasoning\s*:\s*[^.!?\n]*(?:[.!?]\s*|$)/iu, "")
    |> String.trim()
  end

  defp model_internal_line?(line) when is_binary(line) do
    text = String.trim(line)

    text != "" and
      (String.match?(
         text,
         ~r/^(?:confidence|quality|priority|urgency|relevance|interrupt|telegram_fit|affinity|product)_?score\s*[:=]/i
       ) or
         String.match?(
           text,
           ~r/^(?:model|model[_ ]name|model[_ ]provider|model[_ ]response|model[_ ]rationale|model[_ ]reasoning|model[_ ]score|reasoning|score|threshold|quality[_ ]verification|source[_ ](?:access|freshness|health|status))\s*[:=]/i
         ) or
         (String.match?(
            text,
            ~r/^[{\[]/i
          ) and
            String.match?(
              text,
              ~r/"(?:confidence|score|model[_ ]|reasoning|threshold|quality[_ ]verification|source[_ ]health)"/i
            )))
  end

  defp replace_internal_source_labels(text) do
    text
    |> String.replace(~r/\bchief_of_staff_morning_briefing\b/i, "the morning briefing")
    |> String.replace(~r/\bchief_of_staff_commitment_tracker\b/i, "the open work review")
    |> String.replace(~r/\bchief_of_staff_holiday(?:_radar)?\b/i, "the holiday review")
    |> String.replace(~r/\bchief_of_staff_weekend\b/i, "the weekend review")
  end

  defp replace_operator_jargon(text) do
    text
    |> String.replace(~r/\breal ask\b/i, "specific request")
    |> String.replace(~r/\bactual ask\b/i, "specific request")
  end

  defp single_line(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    value
    |> binary_part(0, max)
    |> String.replace(~r/\s+\S*$/, "")
    |> Kernel.<>("...")
  rescue
    ArgumentError -> String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value
end
