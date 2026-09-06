defmodule Maraithon.ActionCards do
  @moduledoc """
  Product-level decision cards for the chief-of-staff surfaces.

  Cards are projections over existing durable objects. The first supported
  projection is a todo, because todos already represent the open-loop source of
  truth used by Telegram, briefings, dashboard, and mobile surfaces.
  """

  alias Maraithon.SourceFreshness
  alias Maraithon.SourceLabels
  alias Maraithon.Timezones
  alias Maraithon.Todos
  alias Maraithon.Todos.{AttentionRanker, PublicMetadata, SurfaceQuality, Todo, UserFacingCopy}

  @open_statuses ~w(open snoozed)
  @fallback_title "Review open work"
  @fallback_summary "This saved open work needs a keep, delegate, or dismiss decision."
  @fallback_action "Open the source context, confirm the request, then keep, delegate, or dismiss it."
  @assistant_sources ~w(
    chief_of_staff_morning_briefing
    chief_of_staff_commitment_tracker
    chief_of_staff_holiday
    chief_of_staff_weekend
  )

  @source_evidence_keys ~w(
    source_quote quote source_excerpt body_excerpt excerpt evidence source_body source_evidence
    checked_evidence body ask commitment summary
  )

  @draft_preview_keys ~w(body text message reply draft content)

  @unsafe_source_gap_markers ~w(
    <redacted
    authorization
    bearer
    dbconnection
    ecto.
    http_status
    internal
    password
    phoenix.
    postgrex
    private_key
    stacktrace
    token
  )

  @local_context_terms [
    "apple notes",
    "apple reminders",
    "birthday",
    "browser history",
    "calendar_local",
    "camp",
    "child",
    "children",
    "daughter",
    "dentist",
    "doctor",
    "dropoff",
    "drop-off",
    "family",
    "flight",
    "health",
    "home",
    "household",
    "husband",
    "imessage",
    "kid",
    "kids",
    "local context",
    "local file",
    "local files",
    "medical",
    "medication",
    "parent",
    "personal",
    "pickup",
    "pick-up",
    "reservation",
    "rsvp",
    "school",
    "son",
    "spouse",
    "teacher",
    "text message",
    "travel",
    "voice memo",
    "wife"
  ]

  @local_context_boolean_keys ~w(
    companion_context_relevant
    desktop_context_relevant
    include_local_sources
    local_context_relevant
    mac_context_relevant
    needs_local_context
  )

  @generic_person_candidate_words ~w(
    Account Action Approval Attachment Board Browser Calendar Call Campaign Context Customer
    Deck Decision Email Event Finance Follow Gmail Inbox Investor Jira Link Meeting Memo Message
    Note Notes Person Plan Project Reminder Report Review Slack Source Status Task Team Thread
    Today Tomorrow Update Voice Work Yesterday
  )

  @decision_action_verbs ~w(
    add attach book buy call cancel close complete create draft email escalate file finalize finish
    follow get handle make message pay plan prepare publish renew schedule share ship submit text
    unblock update upload verify
  )

  @doc """
  Returns ranked action cards for open work items.
  """
  def list_for_user(user_id, opts \\ [])

  def list_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 20)

    opts =
      user_id
      |> put_source_health_snapshots(opts)
      |> put_user_timezone(user_id)

    user_id
    |> Todos.list_for_user(limit: limit, statuses: @open_statuses, open_due_only: true)
    |> AttentionRanker.sort()
    |> Enum.map(&for_todo(&1, opts))
  end

  def list_for_user(_user_id, _opts), do: []

  @doc """
  Builds a decision card projection for a todo.
  """
  def for_todo(todo, opts \\ [])

  def for_todo(%Todo{} = todo, opts) when is_list(opts) do
    todo = polish_todo_copy(todo)
    metadata = todo.metadata || %{}
    public_metadata = PublicMetadata.todo(metadata)
    profile = AttentionRanker.profile(todo)
    quality = SurfaceQuality.assess(todo, attention_profile: profile)
    context_pack = context_pack(todo, metadata, profile, public_metadata)
    attention_mode = card_attention_mode(todo, profile)
    source_health = source_health_snapshot(todo.user_id, todo, profile, opts)

    card =
      %{
        "id" => "todo:#{todo.id}",
        "kind" => todo_kind(todo, profile),
        "source_object_type" => "todo",
        "source_object_id" => todo.id,
        "headline" => headline(todo, context_pack, attention_mode),
        "decision_prompt" => decision_prompt(todo, context_pack, attention_mode),
        "rank_reason" => rank_reason(profile),
        "why_now" =>
          why_now(todo, metadata, profile, attention_mode, opts, context_pack, public_metadata),
        "context_pack" => context_pack,
        "next_best_action" => next_best_action(todo, attention_mode),
        "prepared_actions" => prepared_actions(todo, profile),
        "draft_preview" => draft_preview(todo),
        "available_buttons" => available_buttons(todo, attention_mode),
        "estimated_effort" => estimated_effort(todo),
        "attention_mode" => attention_mode,
        "confidence" => confidence(metadata, quality, source_health, public_metadata),
        "source_health" => source_health,
        "created_from" => created_from(metadata),
        "quality" => quality
      }

    Map.put(card, "product_score", product_score(card))
  end

  def for_todo(todo, opts) when is_map(todo) and is_list(opts) do
    todo
    |> map_to_todo()
    |> for_todo(opts)
  end

  @doc """
  Scores a card against the product bar from the spec.

  The score is intentionally strict. A card should not score 10/10 unless it
  gives the user enough context to decide, explains source confidence, and
  offers a concrete next move.
  """
  def product_score(card) when is_map(card) do
    checks = product_checks(card)
    passed = Enum.count(checks, fn {_name, passed?} -> passed? end)

    %{
      "score" => passed,
      "max_score" => length(checks),
      "passed" => passed == length(checks),
      "missing" =>
        checks
        |> Enum.reject(fn {_name, passed?} -> passed? end)
        |> Enum.map(fn {name, _passed?} -> name end)
    }
  end

  def product_score(_card) do
    %{"score" => 0, "max_score" => 10, "passed" => false, "missing" => ["card"]}
  end

  @doc """
  Renders a todo card for Telegram.
  """
  def render_telegram_todo(todo, opts \\ []) do
    card = for_todo(todo, opts)
    prefix_text = Keyword.get(opts, :prefix_text)

    [
      html_line(prefix_text),
      "<b>#{safe(card["headline"])}</b>",
      telegram_context_line(card),
      telegram_decision_line(card),
      telegram_why_line(card),
      telegram_thread_line(card),
      telegram_next_line(card),
      telegram_draft_preview_line(card),
      telegram_prepared_line(card),
      telegram_evidence_line(card),
      telegram_source_health_line(card),
      telegram_learning_line(card)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @doc """
  Renders a plain-text todo card for native mobile chat.

  Mobile uses its own controls for actions, so this keeps the high-signal
  context from the Telegram card without HTML markup.
  """
  def render_mobile_todo(todo, opts \\ []) do
    card = for_todo(todo, opts)
    prefix_text = Keyword.get(opts, :prefix_text)

    [
      plain_line(prefix_text),
      read_field(card, "headline"),
      mobile_context_line(card),
      mobile_decision_line(card),
      mobile_why_line(card),
      mobile_thread_line(card),
      mobile_next_line(card),
      mobile_draft_preview_line(card),
      mobile_prepared_line(card),
      mobile_evidence_line(card),
      mobile_source_health_line(card),
      mobile_learning_line(card)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @doc """
  Renders source freshness as executive-facing copy.

  Source freshness metadata can contain connector identifiers or transport
  errors. Product surfaces only need the user-level confidence boundary.
  """
  def source_health_note(card) when is_map(card) do
    source_health = read_map(card, "source_health")
    blocking = read_field(source_health, "blocking_gaps") |> List.wrap() |> Enum.reject(&blank?/1)

    checked =
      read_field(source_health, "checked_sources") |> List.wrap() |> Enum.reject(&blank?/1)

    cond do
      blocking != [] ->
        blocked_sources = source_gap_sources(blocking)

        checked_without_blockers =
          Enum.reject(checked, &(normalize_source(&1) in blocked_sources))

        [
          if(checked_without_blockers != [],
            do: "Used #{source_list(checked_without_blockers)}."
          ),
          source_gap_note(blocking, blocked_sources),
          source_setup_action(blocked_sources)
        ]
        |> Enum.reject(&blank?/1)
        |> Enum.join(" ")

      checked != [] ->
        "Used #{source_list(checked)}."

      true ->
        nil
    end
  end

  def source_health_note(_card), do: nil

  def context_items(card_or_todo) do
    card = ensure_card(card_or_todo)
    context = read_map(card, "context_pack")

    [
      %{label: "Person", value: people_label(read_field(context, "people"))},
      %{label: "Project", value: read_field(context, "project_or_topic")},
      %{label: "Relationship", value: read_field(context, "relationship_context")}
    ]
    |> Kernel.++(state_context_items(context))
    |> Enum.reject(fn item -> blank?(item.value) end)
  end

  def evidence_excerpt(card_or_todo) do
    card = ensure_card(card_or_todo)

    card
    |> get_in(["context_pack", "source_evidence"])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"excerpt" => excerpt} when is_binary(excerpt) -> excerpt
      _other -> nil
    end)
  end

  def prepared_action_hint(card_or_todo) do
    card = ensure_card(card_or_todo)

    case read_field(card, "prepared_actions") do
      [%{"label" => label} | _] when is_binary(label) -> label
      _other -> nil
    end
  end

  def draft_preview(%Todo{} = todo) do
    if placeholder_draft?(todo.action_draft) do
      nil
    else
      todo.action_draft
      |> draft_preview_values()
      |> Enum.find_value(&public_draft_preview/1)
    end
  end

  def draft_preview(card_or_todo) do
    card = ensure_card(card_or_todo)

    case read_field(card, "draft_preview") do
      value when is_binary(value) -> public_draft_preview(value)
      _other -> nil
    end
  end

  defp product_checks(card) do
    context = read_map(card, "context_pack")
    source_health = read_map(card, "source_health")

    [
      {"personalized_copy", personalized_copy?(card)},
      {"decision_prompt", present?(read_field(card, "decision_prompt"))},
      {"why_now", present?(read_field(card, "why_now"))},
      {"person_or_explicit_unknown",
       people_present?(read_field(context, "people")) or
         present?(read_field(context, "missing_context"))},
      {"project_or_topic",
       present?(read_field(context, "project_or_topic")) or
         present?(read_field(context, "summary"))},
      {"thread_or_owed_state",
       meaningful_state?(read_field(context, "thread_state")) or
         meaningful_state?(read_field(context, "owed_direction"))},
      {"source_evidence", source_evidence_present?(context)},
      {"source_health", source_health_present?(source_health)},
      {"next_best_action", present?(read_field(card, "next_best_action"))},
      {"safe_actions", read_field(card, "available_buttons") |> List.wrap() |> Enum.any?()}
    ]
  end

  defp ensure_card(%Todo{} = todo), do: for_todo(todo)
  defp ensure_card(%{"context_pack" => _context} = card), do: card
  defp ensure_card(%{context_pack: _context} = card), do: stringify_keys(card)
  defp ensure_card(map) when is_map(map), do: for_todo(map)

  defp polish_todo_copy(%Todo{} = todo) do
    attrs =
      %{
        "title" => todo.title,
        "summary" => todo.summary,
        "next_action" => todo.next_action,
        "metadata" => todo.metadata || %{}
      }
      |> UserFacingCopy.polish_attrs()

    %Todo{
      todo
      | title: read_string(attrs, "title") || todo.title,
        summary: read_string(attrs, "summary") || todo.summary,
        next_action: read_string(attrs, "next_action") || todo.next_action
    }
  end

  defp first_public_context_string(values) when is_list(values) do
    Enum.find_value(values, &public_context_string/1)
  end

  defp public_context_string(value) when is_binary(value) do
    value =
      value
      |> externalize_copy()
      |> single_line()

    cond do
      blank?(value) -> nil
      public_card_text?(value) -> value
      true -> nil
    end
  end

  defp public_context_string(_value), do: nil

  defp context_pack(%Todo{} = todo, metadata, profile, public_metadata) do
    record = read_map(metadata, "record")
    person_context = first_person_context(metadata)

    person =
      first_public_context_string([
        read_string(record, "person"),
        read_string(metadata, "person"),
        read_string(person_context, "display_name"),
        read_string(person_context, "name"),
        read_string(metadata, "contact"),
        read_string(metadata, "requested_by"),
        read_string(metadata, "sender_name"),
        inferred_person_name(todo)
      ])

    company =
      first_public_context_string([
        read_string(record, "company"),
        read_string(metadata, "company"),
        read_string(person_context, "company"),
        read_string(record, "organization"),
        read_string(metadata, "organization"),
        read_string(person_context, "organization"),
        read_string(metadata, "account_name")
      ])

    relationship =
      [
        read_string(record, "relationship"),
        read_string(metadata, "relationship"),
        read_string(person_context, "relationship"),
        read_string(record, "relationship_context"),
        read_string(metadata, "relationship_context"),
        read_string(person_context, "relationship_context"),
        read_string(metadata, "context_brief")
      ]
      |> Enum.find_value(&compact_relationship_label/1)

    project =
      first_public_context_string([
        read_string(metadata, "project"),
        read_string(metadata, "project_name"),
        read_string(metadata, "omni_project"),
        read_string(metadata, "topic"),
        read_string(metadata, "subject"),
        read_string(metadata, "thread_subject"),
        read_string(record, "project"),
        company
      ]) || source_label(todo.source)

    %{
      "summary" => context_summary(todo, metadata, record, person, company, relationship),
      "people" => people_context(person, company, relationship, profile),
      "project_or_topic" => project,
      "relationship_context" => relationship,
      "thread_state" => thread_state(metadata, profile),
      "owed_direction" => owed_direction(todo, metadata, profile),
      "source_evidence" => source_evidence(todo, metadata, record),
      "related_open_loops" => [],
      "last_interaction" => last_interaction(todo, metadata),
      "confidence_reason" => confidence_reason(public_metadata),
      "missing_context" => missing_context(todo, metadata, person)
    }
  end

  defp headline(_todo, context, "stale_check") do
    person = primary_person_name(context)

    cond do
      present?(person) -> "Should this older follow-up with #{person} stay active?"
      true -> "Should this older work item stay active?"
    end
  end

  defp headline(todo, context, _attention_mode) do
    person = primary_person_name(context)
    title = clean_title(todo.title || todo.next_action || @fallback_title)

    cond do
      present?(person) and title_mentions_person?(title, person) ->
        title

      present?(person) ->
        "#{person}: #{title}"

      true ->
        title
    end
  end

  defp decision_prompt(_todo, _context, "stale_check") do
    "Keep it active if it still matters, or dismiss it so it stops resurfacing."
  end

  defp decision_prompt(todo, context, _attention_mode) do
    person = primary_person_name(context)

    cond do
      present?(person) ->
        "Choose the next move with #{person}."

      true ->
        fallback_decision_prompt(todo, context)
    end
  end

  defp fallback_decision_prompt(todo, context) do
    first_present([
      decision_prompt_from_action(todo.next_action),
      decision_prompt_from_action(todo.title),
      contextual_decision_prompt(todo, context)
    ])
  end

  defp decision_prompt_from_action(value) when is_binary(value) do
    action =
      value
      |> naturalize_action_copy()
      |> strip_leading_action_label()
      |> strip_operator_action_prefix()
      |> String.trim()

    cond do
      blank?(action) ->
        nil

      generic_decision_subject?(action) ->
        nil

      Regex.match?(~r/^(decide|choose)\s+whether\b/i, action) ->
        ensure_terminal_punctuation(action)

      Regex.match?(~r/^confirm\s+whether\b/i, action) ->
        ensure_terminal_punctuation(action)

      Regex.match?(
        ~r/^(approve|ask|check|choose|confirm|decide|dismiss|keep|mark|reply|respond|review|send)\b/i,
        action
      ) ->
        action =
          action
          |> strip_terminal_punctuation()
          |> lowercase_first_character()

        "Decide whether to #{action}."

      starts_with_decision_action_verb?(action) ->
        action =
          action
          |> strip_terminal_punctuation()
          |> lowercase_first_character()

        "Decide whether to #{action}."

      true ->
        nil
    end
  end

  defp decision_prompt_from_action(_value), do: nil

  defp starts_with_decision_action_verb?(action) when is_binary(action) do
    Enum.any?(@decision_action_verbs, fn verb ->
      Regex.match?(~r/^#{Regex.escape(verb)}\b/i, action)
    end)
  end

  defp contextual_decision_prompt(todo, context) do
    source = source_label(todo.source)
    project = read_field(context, "project_or_topic")

    cond do
      present?(project) and project != source ->
        "Choose the next move for #{project}."

      useful_source_decision_label?(source) ->
        "Choose whether to act on this #{String.downcase(source)} work."

      true ->
        "Choose whether to keep, delegate, or dismiss this work."
    end
  end

  defp generic_decision_subject?(action) when is_binary(action) do
    action
    |> strip_terminal_punctuation()
    |> String.downcase()
    |> then(&(&1 in ["review open work", "review this item", "open todo", "open work"]))
  end

  defp generic_decision_subject?(_action), do: false

  defp useful_source_decision_label?(source) when is_binary(source) do
    normalized =
      source
      |> String.replace(~r/[\s\p{Zs}]+/u, " ")
      |> String.trim()
      |> String.downcase()

    present?(source) and
      normalized not in [
        "maraithon",
        "manual",
        "added by you",
        "created by you",
        "system",
        "connected context"
      ]
  end

  defp useful_source_decision_label?(_source), do: false

  defp why_now(todo, _metadata, profile, "stale_check", _opts, _context, _public_metadata) do
    age_days = read_field(profile, "age_days")

    cond do
      match?(%DateTime{}, todo.due_at) and due_in_past?(todo.due_at) ->
        "This passed its due date with no handled evidence. It is not urgent — keep it only if it still matters, otherwise dismiss it."

      is_integer(age_days) ->
        "This item is #{age_days} days old with no handled evidence. It is not urgent, but it needs a keep-or-close decision."

      true ->
        "This has been open long enough to need a keep-or-close decision."
    end
  end

  defp why_now(todo, metadata, profile, _attention_mode, opts, context, public_metadata) do
    first_present([
      read_string(public_metadata, "why_now"),
      read_string(public_metadata, "why_it_matters"),
      due_sentence(todo, metadata, opts),
      manual_capture_why_now(todo, metadata),
      profile_why_now(profile, todo, context),
      contextual_why_now(todo, context),
      nudge_why_now(todo, profile),
      fallback_why_now()
    ])
  end

  defp due_in_past?(%DateTime{} = due_at), do: DateTime.compare(due_at, DateTime.utc_now()) == :lt
  defp due_in_past?(_due_at), do: false

  # SPEC 05 R4: surfaces nudge state ("waiting 9 days, never nudged" vs
  # "nudged Tuesday") as a low-priority why_now candidate — it only fires
  # once every richer, more specific signal above has nothing to say, and
  # only for commitment-shaped todos (never for the neutral "fyi" default).
  @nudge_min_age_days 3

  defp nudge_why_now(%Todo{direction: direction} = todo, profile)
       when direction in ["owed_by_me", "owed_to_me"] do
    age_days = read_field(profile, "age_days")

    cond do
      is_integer(todo.nudge_count) and todo.nudge_count > 0 and
          match?(%DateTime{}, todo.last_nudged_at) ->
        nudge_subject_phrase(direction, age_days) <>
          " nudged #{relative_nudge_label(todo.last_nudged_at)}" <>
          next_nudge_phrase(todo.next_nudge_at)

      true ->
        # SPEC 01 R5: "never nudged" copy is reserved for the actual
        # zero-nudge case — a nudged row missing last_nudged_at falls back
        # to the neutral phrasing instead of lying about nudge history.
        nudged_before? = is_integer(todo.nudge_count) and todo.nudge_count > 0

        cond do
          nudged_before? ->
            nudge_subject_phrase(direction, age_days) <>
              ", nudged before" <> next_nudge_phrase(todo.next_nudge_at)

          is_integer(age_days) and age_days >= @nudge_min_age_days ->
            nudge_subject_phrase(direction, age_days) <> ", never nudged."

          true ->
            nil
        end
    end
  end

  defp nudge_why_now(_todo, _profile), do: nil

  defp next_nudge_phrase(%DateTime{} = next_nudge_at) do
    "; next follow-up around #{Calendar.strftime(next_nudge_at, "%b %-d")}."
  end

  defp next_nudge_phrase(_next_nudge_at), do: "."

  defp nudge_subject_phrase("owed_to_me", age_days) when is_integer(age_days),
    do: "You've been waiting #{age_days} days"

  defp nudge_subject_phrase("owed_to_me", _age_days), do: "You've been waiting on this"

  defp nudge_subject_phrase(_direction, age_days) when is_integer(age_days),
    do: "This has been open #{age_days} days"

  defp nudge_subject_phrase(_direction, _age_days), do: "This has been open"

  defp relative_nudge_label(%DateTime{} = nudged_at) do
    case Date.diff(Date.utc_today(), DateTime.to_date(nudged_at)) do
      0 -> "today"
      1 -> "yesterday"
      days when days > 1 -> "#{days} days ago"
      _ -> "recently"
    end
  end

  defp manual_capture_why_now(todo, metadata) do
    captured_from = read_string(metadata, "captured_from")

    cond do
      captured_from in ["telegram_message", "mobile_chat"] ->
        "You asked Maraithon to keep this on your work queue until it is handled."

      todo.source in ["telegram", "mobile_assistant"] and
          present?(read_string(metadata, "request_text")) ->
        "You asked Maraithon to keep this on your work queue until it is handled."

      true ->
        nil
    end
  end

  defp contextual_why_now(todo, context) do
    context = if is_map(context), do: context, else: %{}

    [
      read_field(context, "summary"),
      todo.summary,
      todo.title
    ]
    |> Enum.find_value(&waiting_reason_sentence/1)
  end

  defp fallback_why_now do
    "No deadline or waiting signal is clear, so review it once and either keep it active or dismiss it."
  end

  defp next_best_action(_todo, "stale_check") do
    "Keep it active only if it still matters; otherwise dismiss it so future briefings stay focused."
  end

  defp next_best_action(todo, _attention_mode) do
    first_present([
      todo.next_action,
      read_string(todo.metadata || %{}, "next_action"),
      "Open the source item, confirm the specific request, and decide whether this still matters."
    ])
    |> naturalize_action_copy()
  end

  defp card_attention_mode(todo, profile) do
    cond do
      read_field(profile, "stale_confirmation_candidate") == true -> "stale_check"
      todo.attention_mode == "monitor" -> "monitor"
      true -> "review"
    end
  end

  defp todo_kind(todo, profile) do
    cond do
      read_field(profile, "personal_family") == true -> "personal_logistics"
      read_field(profile, "meeting_request") == true -> "meeting_prep"
      todo.source in ["gmail", "slack"] -> "reply_debt"
      true -> "todo"
    end
  end

  defp rank_reason(profile) do
    case read_field(profile, "bucket") do
      "personal_family" -> "Personal or family logistics are ranked first."
      "strong_relationship_waiting" -> "A close relationship appears to be waiting on you."
      "business_project_waiting" -> "An active business objective may be waiting on you."
      "intro_request" -> "This looks like relationship-capital work."
      "meeting_request" -> "This appears to be meeting or scheduling work."
      _ -> "This remains open and reviewable."
    end
  end

  defp prepared_actions(todo, profile) do
    next_action = String.downcase(todo.next_action || "")
    source = todo.source

    base =
      cond do
        real_draft?(todo.action_draft) ->
          [%{"type" => "review_draft", "label" => "Draft material is ready for approval."}]

        source == "gmail" and String.contains?(next_action, ["reply", "email"]) ->
          [%{"type" => "draft_email", "label" => "Draft the reply for approval."}]

        source == "slack" and String.contains?(next_action, ["reply", "respond", "message"]) ->
          [
            %{
              "type" => "draft_slack",
              "label" => "Draft the Slack response for approval."
            }
          ]

        true ->
          []
      end

    base ++ nudge_prepared_actions(todo, profile)
  end

  # SPEC 01 R5 (was SPEC 05 R4): suggests sending a follow-up nudge for aged
  # "owed_to_me" work. The old `nudge_count > 0 -> []` guard made a single
  # nudge permanently silence this suggestion; it is now cadence-aware — a
  # 2nd/3rd/Nth nudge reappears once the scheduled `next_nudge_at` has
  # elapsed (with a short 24h backoff after any send so the suggestion never
  # instantly re-fires right after a nudge completes). Legacy rows with a
  # prior nudge but no cadence (`next_nudge_at: nil`) re-suggest on the
  # existing age/last-nudged signals rather than never or always.
  @nudge_repeat_backoff_hours 24

  defp nudge_prepared_actions(%Todo{direction: "owed_to_me", status: status} = todo, profile)
       when status in @open_statuses do
    nudge_count = if is_integer(todo.nudge_count), do: todo.nudge_count, else: 0
    age_days = read_field(profile, "age_days")

    cond do
      nudge_scheduled_in_future?(todo) ->
        []

      nudged_within_backoff?(todo) ->
        []

      nudge_count > 0 and nudge_cadence_elapsed?(todo) ->
        [repeat_nudge_action(nudge_count)]

      nudge_count > 0 ->
        # next_nudge_at is nil on every pre-cadence row: "cadence unknown,
        # safe to re-suggest" once the last nudge is old enough — not "never
        # suggest again" (the old bug) and not "always suggest".
        if legacy_renudge_due?(todo, age_days), do: [repeat_nudge_action(nudge_count)], else: []

      is_integer(age_days) and age_days >= @nudge_min_age_days ->
        [
          %{
            "type" => "send_nudge",
            "label" => "Send a follow-up nudge; none has gone out yet."
          }
        ]

      true ->
        []
    end
  end

  defp nudge_prepared_actions(_todo, _profile), do: []

  defp repeat_nudge_action(nudge_count) do
    %{
      "type" => "send_nudge",
      "label" => repeat_nudge_label(nudge_count)
    }
  end

  defp repeat_nudge_label(1), do: "Send a follow-up nudge; 1 has gone out already."
  defp repeat_nudge_label(count), do: "Send a follow-up nudge; #{count} have gone out already."

  defp nudge_scheduled_in_future?(%Todo{next_nudge_at: %DateTime{} = next_nudge_at}) do
    DateTime.compare(next_nudge_at, DateTime.utc_now()) == :gt
  end

  defp nudge_scheduled_in_future?(_todo), do: false

  defp nudge_cadence_elapsed?(%Todo{next_nudge_at: %DateTime{} = next_nudge_at}) do
    DateTime.compare(next_nudge_at, DateTime.utc_now()) != :gt
  end

  defp nudge_cadence_elapsed?(_todo), do: false

  defp nudged_within_backoff?(%Todo{last_nudged_at: %DateTime{} = last_nudged_at}) do
    DateTime.diff(DateTime.utc_now(), last_nudged_at, :hour) < @nudge_repeat_backoff_hours
  end

  defp nudged_within_backoff?(_todo), do: false

  defp legacy_renudge_due?(%Todo{last_nudged_at: %DateTime{} = last_nudged_at}, _age_days) do
    Date.diff(Date.utc_today(), DateTime.to_date(last_nudged_at)) >= @nudge_min_age_days
  end

  defp legacy_renudge_due?(_todo, age_days) do
    is_integer(age_days) and age_days >= @nudge_min_age_days
  end

  defp available_buttons(%Todo{status: status}, _attention_mode)
       when status not in @open_statuses,
       do: ["open_dashboard"]

  defp available_buttons(_todo, "stale_check"),
    do: ["important", "dismiss", "see_less", "more_context"]

  defp available_buttons(_todo, _attention_mode),
    do: ["done", "dismiss", "snooze", "helpful", "not_helpful", "see_less", "more_context"]

  defp estimated_effort(todo) do
    action = String.downcase(todo.next_action || "")

    cond do
      String.contains?(action, ["draft", "reply", "respond", "confirm"]) -> "under_2_min"
      String.contains?(action, ["research", "prep", "prepare"]) -> "deep_work"
      true -> "5_min"
    end
  end

  defp confidence(metadata, quality, source_health, public_metadata) do
    explicit = read_string(metadata, "confidence") || read_string(metadata, "scope_confidence")
    source_issue? = read_field(source_health, "blocking_gaps") |> List.wrap() |> Enum.any?()

    level =
      cond do
        present?(explicit) -> explicit_confidence_level(explicit)
        source_issue? -> "medium"
        quality["score"] >= 85 -> "high"
        quality["score"] >= 65 -> "medium"
        true -> "low"
      end

    %{
      "level" => level,
      "reason" =>
        confidence_reason(public_metadata) ||
          "Based on saved work, evidence, and available context."
    }
  end

  defp source_health_snapshot(nil, _todo, _profile, _opts), do: empty_source_health()

  defp source_health_snapshot(user_id, %Todo{} = todo, profile, opts) do
    include_disconnected? = Keyword.get(opts, :include_disconnected, true)
    source = todo.source

    snapshots =
      Keyword.get_lazy(opts, :source_health_snapshots, fn ->
        SourceFreshness.compact_for_prompt(user_id)
      end)

    relevant_extra_sources = relevant_extra_sources(todo, profile, include_disconnected?)
    checked_sources = checked_sources(source, snapshots, relevant_extra_sources)
    relevant = filter_source_snapshots(snapshots, source)
    fresh = Enum.filter(relevant, &(read_field(&1, "status") == "fresh"))

    stale =
      Enum.filter(
        relevant,
        &(read_field(&1, "status") in ~w(stale error reauth_required never_synced))
      )

    missing = missing_relevant_sources(todo, profile, snapshots, include_disconnected?)

    %{
      "checked_sources" => checked_sources,
      "fresh_sources" => Enum.map(fresh, &read_field(&1, "provider")),
      "stale_sources" => Enum.map(stale, &read_field(&1, "provider")),
      "missing_sources" => missing,
      "last_success_at_by_source" =>
        Map.new(relevant, fn snapshot ->
          {read_field(snapshot, "provider"), read_field(snapshot, "last_successful_sync")}
        end),
      "blocking_gaps" => blocking_gaps(stale, missing),
      "setup_suggestion" => setup_suggestion(missing)
    }
  end

  defp empty_source_health do
    %{
      "checked_sources" => [],
      "fresh_sources" => [],
      "stale_sources" => [],
      "missing_sources" => [],
      "last_success_at_by_source" => %{},
      "blocking_gaps" => [],
      "setup_suggestion" => nil
    }
  end

  defp put_source_health_snapshots(user_id, opts) do
    if Keyword.has_key?(opts, :source_health_snapshots) do
      opts
    else
      Keyword.put(opts, :source_health_snapshots, SourceFreshness.compact_for_prompt(user_id))
    end
  end

  defp source_evidence(todo, metadata, record) do
    values =
      []
      |> Kernel.++(source_evidence_values(metadata))
      |> Kernel.++(source_evidence_values(record))
      |> Kernel.++([todo.summary, todo.notes])
      |> Enum.reject(&blank?/1)
      |> Enum.map(&externalize_copy/1)
      |> Enum.filter(&public_card_text?/1)
      |> Enum.uniq()
      |> Enum.take(3)

    source = todo.source || "todo"

    Enum.map(values, fn value ->
      %{
        "source" => source,
        "source_account_label" => todo.source_account_label,
        "source_ref" => todo.source_item_id || todo.dedupe_key,
        "occurred_at" => datetime_iso(todo.source_occurred_at || todo.inserted_at),
        "excerpt" => truncate(value, 240),
        "evidence_type" => evidence_type(value)
      }
    end)
  end

  defp source_evidence_values(map) when is_map(map) do
    Enum.flat_map(@source_evidence_keys, fn key ->
      value = read_field(map, key)

      cond do
        is_binary(value) -> [value]
        is_list(value) -> Enum.flat_map(value, &source_evidence_item/1)
        is_map(value) -> source_evidence_values(value)
        true -> []
      end
    end)
  end

  defp source_evidence_values(_map), do: []

  defp source_evidence_item(value) when is_binary(value), do: [value]

  defp source_evidence_item(value) when is_map(value) do
    [
      read_string(value, "detail"),
      read_string(value, "excerpt"),
      read_string(value, "quote"),
      read_string(value, "text")
    ]
    |> Enum.reject(&blank?/1)
  end

  defp source_evidence_item(_value), do: []

  defp first_person_context(metadata) when is_map(metadata) do
    case read_field(metadata, "people") || read_field(metadata, "crm_people") do
      [%{} = person | _] -> stringify_keys(person)
      %{} = person -> stringify_keys(person)
      _ -> %{}
    end
  end

  defp first_person_context(_metadata), do: %{}

  defp inferred_person_name(%Todo{} = todo) do
    [todo.title, todo.next_action, todo.summary]
    |> Enum.find_value(&inferred_person_from_text/1)
  end

  defp inferred_person_from_text(value) when is_binary(value) do
    text = String.trim(value)

    [
      ~r/\b(?i:(?:reply|respond|follow\s+up|follow-up|check\s+in|circle\s+back|sync|confirm))\s+(?i:(?:with|to))\s+(?<name>\p{Lu}[\p{L}'-]+(?:\s+\p{Lu}[\p{L}'-]+){0,2})\b/u,
      ~r/\b(?i:(?:ask|call|email|message|ping|text))\s+(?<name>\p{Lu}[\p{L}'-]+(?:\s+\p{Lu}[\p{L}'-]+){0,2})\b/u,
      ~r/\b(?i:send)\s+(?<name>\p{Lu}[\p{L}'-]+(?:\s+\p{Lu}[\p{L}'-]+){0,2})\b/u,
      ~r/\b(?<name>\p{Lu}[\p{L}'-]+(?:\s+\p{Lu}[\p{L}'-]+){0,2})\s+(?i:(?:asked|requested|needs|wants|is\s+waiting))\b/u
    ]
    |> Enum.find_value(fn pattern ->
      case Regex.named_captures(pattern, text) do
        %{"name" => candidate} -> normalize_person_candidate(candidate)
        _ -> nil
      end
    end)
  end

  defp inferred_person_from_text(_value), do: nil

  defp normalize_person_candidate(candidate) when is_binary(candidate) do
    candidate =
      candidate
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    words = String.split(candidate, " ", trim: true)
    last_word = List.last(words)

    cond do
      blank?(candidate) ->
        nil

      candidate in @generic_person_candidate_words ->
        nil

      last_word in @generic_person_candidate_words ->
        nil

      true ->
        candidate
    end
  end

  defp context_summary(todo, metadata, record, person, company, relationship) do
    commitment = read_string(record, "commitment")

    summary =
      first_present([
        read_string(metadata, "context"),
        todo.summary,
        read_string(record, "summary")
      ])

    identity = identity_label(person, company, relationship)

    cond do
      present?(person) and present?(summary) and title_mentions_person?(summary, person) ->
        externalize_copy(summary)

      present?(identity) and present?(summary) ->
        "#{identity}. #{externalize_copy(summary)}"

      present?(identity) and present?(commitment) ->
        "#{identity} is tied to this open commitment: #{externalize_copy(commitment)}"

      present?(summary) ->
        externalize_copy(summary)

      true ->
        "This is an open #{source_label(todo.source)} item."
    end
    |> truncate(360)
  end

  defp people_context(nil, _company, _relationship, _profile), do: []

  defp people_context(person, company, relationship, profile) do
    [
      %{
        "name" => person,
        "company" => company,
        "relationship" => relationship,
        "familiarity" => familiarity(profile),
        "relationship_strength" => read_field(profile, "relationship_strength")
      }
    ]
  end

  defp thread_state(metadata, profile) do
    conversation_context = read_map(metadata, "conversation_context")

    first_present([
      read_string(conversation_context, "momentum_state"),
      read_string(conversation_context, "notification_posture"),
      read_string(metadata, "thread_state"),
      if(read_field(profile, "stale_confirmation_candidate") == true, do: "stale")
    ])
  end

  # Responsibility labels must come from durable direction / thread state, or
  # unmistakable waiting copy — never from broad "actively_waiting" keyword
  # hints that used to mark ordinary open work as "Waiting on you".
  defp owed_direction(todo, metadata, profile) do
    if read_field(profile, "stale_confirmation_candidate") == true do
      nil
    else
      case read_field(todo, "direction") do
        "owed_to_me" ->
          "they_owe"

        "fyi" ->
          nil

        "owed_by_me" ->
          explicit_owed_direction(metadata) || inferred_user_owes_from_copy(todo, metadata)

        _other ->
          explicit_owed_direction(metadata) || inferred_user_owes_from_copy(todo, metadata)
      end
    end
  end

  @user_owes_directions ~w(
    waiting_on_kent waiting_on_user waiting_on_me user_owes i_owe asked_of_me pending_reply
  )
  @they_owe_directions ~w(waiting_on_them they_owe)

  defp explicit_owed_direction(metadata) when is_map(metadata) do
    candidates =
      [
        read_string(metadata, "commitment_direction"),
        read_string(read_map(metadata, "record"), "commitment_direction"),
        read_string(metadata, "thread_state"),
        read_string(read_map(metadata, "conversation_context"), "momentum_state"),
        read_string(read_map(metadata, "conversation_context"), "notification_posture")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.map(&normalize_direction_token/1)

    cond do
      Enum.any?(candidates, &(&1 in @user_owes_directions)) -> "user_owes"
      Enum.any?(candidates, &(&1 in @they_owe_directions)) -> "they_owe"
      true -> nil
    end
  end

  defp explicit_owed_direction(_metadata), do: nil

  defp inferred_user_owes_from_copy(todo, metadata) do
    text =
      [
        todo.summary,
        todo.title,
        todo.next_action,
        read_string(metadata, "why_now"),
        read_string(metadata, "why_it_matters"),
        read_string(read_map(metadata, "record"), "ask"),
        read_string(read_map(metadata, "record"), "commitment")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    if strong_waiting_on_user_copy?(text), do: "user_owes"
  end

  defp strong_waiting_on_user_copy?(text) when is_binary(text) do
    Enum.any?(
      [
        "is waiting",
        "are waiting",
        "waiting on you",
        "waiting on your",
        "needs your reply",
        "needs your decision",
        "needs your approval",
        "awaiting your",
        "you owe",
        "no later reply",
        "no later sent reply"
      ],
      &String.contains?(text, &1)
    )
  end

  defp strong_waiting_on_user_copy?(_text), do: false

  defp normalize_direction_token(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_direction_token(_value), do: ""

  defp last_interaction(todo, metadata) do
    first_present([
      read_string(metadata, "last_interaction_at"),
      datetime_iso(todo.source_occurred_at),
      datetime_iso(todo.updated_at)
    ])
  end

  defp confidence_reason(public_metadata) do
    first_present([
      read_string(public_metadata, "why_it_matters"),
      read_string(public_metadata, "why_now")
    ])
  end

  defp public_card_text?(value) when is_binary(value), do: PublicMetadata.public_text?(value)
  defp public_card_text?(_value), do: false

  defp missing_context(todo, metadata, person) do
    cond do
      blank?(person) ->
        "No specific person is linked to this item yet."

      read_field(metadata, "source_health_missing") ->
        read_string(metadata, "source_health_missing")

      todo.source in ["gmail", "calendar"] ->
        nil

      true ->
        nil
    end
  end

  defp checked_sources(source, snapshots, extra_sources) do
    wanted =
      [source | List.wrap(extra_sources)]
      |> Enum.map(&normalize_source/1)
      |> Enum.reject(&blank?/1)
      |> MapSet.new()

    matched =
      snapshots
      |> Enum.map(&read_field(&1, "provider"))
      |> Enum.map(&normalize_source/1)
      |> Enum.reject(&blank?/1)
      |> Enum.filter(&MapSet.member?(wanted, &1))

    [normalize_source(source) | matched]
    |> Enum.reject(&blank?/1)
    |> Enum.filter(&source_checkable?/1)
    |> Enum.uniq()
  end

  defp relevant_extra_sources(%Todo{} = todo, profile, true) do
    if local_context_relevant?(todo, profile), do: ["desktop"], else: []
  end

  defp relevant_extra_sources(_todo, _profile, _include_disconnected?), do: []

  defp source_checkable?(source) when source in @assistant_sources, do: false
  defp source_checkable?(source) when source in ["manual", "system"], do: false
  defp source_checkable?(source) when is_binary(source), do: source != ""
  defp source_checkable?(_source), do: false

  defp filter_source_snapshots(snapshots, source) do
    normalized_source = normalize_source(source)

    Enum.filter(snapshots, fn snapshot ->
      normalize_source(read_field(snapshot, "provider")) == normalized_source
    end)
  end

  defp missing_relevant_sources(%Todo{} = todo, profile, snapshots, include_disconnected?) do
    providers =
      snapshots
      |> Enum.map(&normalize_source(read_field(&1, "provider")))
      |> Enum.reject(&blank?/1)
      |> MapSet.new()

    relevant =
      cond do
        todo.source in ["gmail", "calendar"] and local_context_relevant?(todo, profile) ->
          ["desktop"]

        todo.source in ["manual", "telegram"] ->
          []

        true ->
          []
      end

    if include_disconnected? do
      Enum.reject(relevant, &MapSet.member?(providers, &1))
    else
      []
    end
  end

  defp local_context_relevant?(%Todo{} = todo, profile) do
    metadata = todo.metadata || %{}

    read_field(profile, "personal_family") == true or
      explicit_local_context?(metadata) or
      local_context_text(todo, metadata)
      |> String.downcase()
      |> contains_any?(@local_context_terms)
  end

  defp explicit_local_context?(metadata) when is_map(metadata) do
    Enum.any?(@local_context_boolean_keys, fn key ->
      truthy?(read_field(metadata, key))
    end)
  end

  defp explicit_local_context?(_metadata), do: false

  defp local_context_text(%Todo{} = todo, metadata) do
    record = read_map(metadata, "record")

    [
      todo.title,
      todo.summary,
      todo.next_action,
      todo.notes,
      read_field(metadata, "source_tags"),
      read_string(metadata, "life_domain"),
      read_string(metadata, "suggested_life_domain"),
      read_string(metadata, "omni_project"),
      read_string(metadata, "source_health_missing"),
      read_string(metadata, "context"),
      read_string(metadata, "context_brief"),
      read_string(metadata, "topic"),
      read_string(metadata, "project"),
      read_string(metadata, "project_name"),
      read_string(record, "person"),
      read_string(record, "relationship_context"),
      read_string(record, "summary"),
      read_string(record, "commitment")
    ]
    |> Enum.flat_map(&local_context_text_values/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp local_context_text_values(value) when is_binary(value), do: [value]

  defp local_context_text_values(values) when is_list(values) do
    Enum.flat_map(values, &local_context_text_values/1)
  end

  defp local_context_text_values(%{} = map) do
    map
    |> Map.values()
    |> Enum.flat_map(&local_context_text_values/1)
  end

  defp local_context_text_values(_value), do: []

  defp blocking_gaps(stale, missing) do
    stale_gaps =
      Enum.map(stale, fn snapshot ->
        provider = read_field(snapshot, "provider")
        reason = read_field(snapshot, "stale_reason") || read_field(snapshot, "last_error")
        "#{provider}: #{reason || "not fresh"}"
      end)

    missing_gaps = Enum.map(missing, &"#{&1}: not connected")
    stale_gaps ++ missing_gaps
  end

  defp setup_suggestion(missing) do
    if "desktop" in missing do
      "Connect the Maraithon Mac companion app to include iMessage, Apple Notes, files, reminders, and local context securely."
    end
  end

  defp telegram_context_line(card) do
    context = read_map(card, "context_pack")
    summary = read_field(context, "summary")

    if present?(summary), do: "Context: #{safe(summary)}"
  end

  defp telegram_decision_line(card) do
    decision = read_field(card, "decision_prompt")

    if present?(decision), do: "Decision: #{safe(decision)}"
  end

  defp telegram_why_line(card) do
    why_now = read_field(card, "why_now")

    if present?(why_now), do: "Why now: #{safe(why_now)}"
  end

  defp telegram_thread_line(card) do
    context = read_map(card, "context_pack")
    thread_state = state_label(read_field(context, "thread_state"))
    owed = owed_label(read_field(context, "owed_direction"))

    cond do
      present?(thread_state) and thread_state == owed ->
        "State: #{safe(thread_state)}"

      present?(thread_state) and present?(owed) ->
        "State: #{safe(thread_state)} · #{safe(owed)}"

      present?(thread_state) ->
        "State: #{safe(thread_state)}"

      present?(owed) ->
        "State: #{safe(owed)}"

      true ->
        nil
    end
  end

  defp telegram_next_line(card) do
    next = read_field(card, "next_best_action")
    if present?(next), do: "Next: #{safe(next)}"
  end

  defp telegram_draft_preview_line(card) do
    case draft_preview(card) do
      value when is_binary(value) -> "Suggested reply: #{safe(truncate(value, 360))}"
      _other -> nil
    end
  end

  defp telegram_prepared_line(card) do
    case read_field(card, "prepared_actions") do
      [%{"label" => label} | _] when is_binary(label) -> "Prepared: #{safe(label)}"
      _other -> nil
    end
  end

  defp telegram_evidence_line(card) do
    case evidence_excerpt(card) do
      value when is_binary(value) -> "Evidence: #{safe(truncate(value, 180))}"
      _ -> nil
    end
  end

  defp telegram_source_health_line(card) do
    case source_health_note(card) do
      "Used " <> rest -> "Context used: #{rest}"
      note -> note
    end
  end

  defp telegram_learning_line(card) do
    case read_field(card, "attention_mode") do
      "stale_check" ->
        "This choice helps Maraithon keep older work visible only when it still matters."

      _ ->
        nil
    end
  end

  defp mobile_context_line(card) do
    context = read_map(card, "context_pack")
    summary = read_field(context, "summary")

    if present?(summary), do: "Context: #{summary}"
  end

  defp mobile_decision_line(card) do
    decision = read_field(card, "decision_prompt")

    if present?(decision), do: "Decision: #{decision}"
  end

  defp mobile_why_line(card) do
    why_now = read_field(card, "why_now")

    if present?(why_now), do: "Why now: #{why_now}"
  end

  defp mobile_thread_line(card) do
    context = read_map(card, "context_pack")
    thread_state = state_label(read_field(context, "thread_state"))
    owed = owed_label(read_field(context, "owed_direction"))

    cond do
      present?(thread_state) and thread_state == owed ->
        "State: #{thread_state}"

      present?(thread_state) and present?(owed) ->
        "State: #{thread_state} · #{owed}"

      present?(thread_state) ->
        "State: #{thread_state}"

      present?(owed) ->
        "State: #{owed}"

      true ->
        nil
    end
  end

  defp mobile_next_line(card) do
    next = read_field(card, "next_best_action")
    if present?(next), do: "Next: #{next}"
  end

  defp mobile_draft_preview_line(card) do
    case draft_preview(card) do
      value when is_binary(value) -> "Suggested reply: #{truncate(value, 360)}"
      _other -> nil
    end
  end

  defp mobile_prepared_line(card) do
    case read_field(card, "prepared_actions") do
      [%{"label" => label} | _] when is_binary(label) -> "Prepared: #{label}"
      _other -> nil
    end
  end

  defp mobile_evidence_line(card) do
    case evidence_excerpt(card) do
      value when is_binary(value) -> "Evidence: #{truncate(value, 180)}"
      _ -> nil
    end
  end

  defp mobile_source_health_line(card) do
    case source_health_note(card) do
      "Used " <> rest -> "Context used: #{rest}"
      note -> note
    end
  end

  defp mobile_learning_line(card) do
    case read_field(card, "attention_mode") do
      "stale_check" ->
        "This choice helps Maraithon keep older work visible only when it still matters."

      _ ->
        nil
    end
  end

  defp source_health_present?(source_health) do
    checked =
      read_field(source_health, "checked_sources") |> List.wrap() |> Enum.reject(&blank?/1)

    fresh = read_field(source_health, "fresh_sources") |> List.wrap() |> Enum.reject(&blank?/1)
    stale = read_field(source_health, "stale_sources") |> List.wrap() |> Enum.reject(&blank?/1)

    checked != [] or fresh != [] or stale != []
  end

  defp source_evidence_present?(context) do
    context
    |> read_field("source_evidence")
    |> List.wrap()
    |> Enum.any?(fn
      %{"excerpt" => excerpt} -> present?(excerpt)
      _ -> false
    end)
  end

  defp people_present?(people) when is_list(people) do
    Enum.any?(people, fn
      %{"name" => name} -> present?(name)
      _ -> false
    end)
  end

  defp people_present?(_people), do: false

  defp personalized_copy?(card) do
    card
    |> user_visible_card_text()
    |> Enum.reject(&blank?/1)
    |> then(fn values ->
      values != [] and Enum.all?(values, &(not generic_user_facing_copy?(&1)))
    end)
  end

  defp user_visible_card_text(card) do
    context = read_map(card, "context_pack")

    [
      read_field(card, "headline"),
      read_field(card, "decision_prompt"),
      read_field(card, "why_now"),
      read_field(card, "next_best_action"),
      read_field(context, "summary"),
      read_field(context, "relationship_context"),
      read_field(context, "project_or_topic")
    ]
  end

  defp generic_user_facing_copy?(value) when is_binary(value) do
    text = String.downcase(value)

    Enum.any?(
      [
        "user committed",
        "the user committed",
        "follow-up not yet sent",
        "no later reply or follow-through",
        "reply now with owner",
        "with owner, eta, and",
        "with owner and eta.",
        "exact artifact or update",
        "confirm artifact status",
        "review and decide the next step",
        "decide whether this needs action now",
        "this appears to be waiting on you"
      ],
      &String.contains?(text, &1)
    )
  end

  defp generic_user_facing_copy?(_value), do: false

  defp primary_person_name(context) do
    case read_field(context, "people") do
      [%{"name" => name} | _] when is_binary(name) -> name
      _other -> nil
    end
  end

  defp people_label([%{"name" => name} = person | _]) do
    # Keep the person chip scannable: name + company only. Long CRM bios in
    # relationship_context used to dump into every Decision row subtitle.
    case compact_company_label(read_field(person, "company")) do
      company when is_binary(company) -> "#{name} (#{company})"
      _ -> name
    end
  end

  defp people_label(_people), do: nil

  defp identity_label(person, company, _relationship) do
    cond do
      blank?(person) ->
        nil

      true ->
        case compact_company_label(company) do
          company_label when is_binary(company_label) -> "#{person} (#{company_label})"
          _ -> person
        end
    end
  end

  defp compact_company_label(value) when is_binary(value) do
    value
    |> single_line()
    |> String.trim()
    |> case do
      "" -> nil
      company when byte_size(company) <= 48 -> company
      _long -> nil
    end
  end

  defp compact_company_label(_value), do: nil

  # Short role labels ("Investor", "Agency partner") are useful. Full CRM
  # dossier sentences are not — they duplicate People records and make
  # Decision rows look invented.
  defp compact_relationship_label(value) when is_binary(value) do
    cleaned =
      value
      |> externalize_copy()
      |> single_line()
      |> String.trim()

    cond do
      blank?(cleaned) -> nil
      not public_card_text?(cleaned) -> nil
      String.length(cleaned) > 48 -> nil
      String.contains?(cleaned, ". ") -> nil
      true -> cleaned
    end
  end

  defp compact_relationship_label(_value), do: nil

  defp profile_why_now(profile, todo, context) do
    cond do
      read_field(profile, "personal_family") == true ->
        "Personal or family logistics are ranked first."

      read_field(profile, "actively_waiting") == true ->
        active_waiting_why_now(todo, context) ||
          "This source item appears to be waiting on your reply or commitment."

      read_field(profile, "business_project") == true ->
        "This is tied to an active business objective."

      true ->
        nil
    end
  end

  defp active_waiting_why_now(todo, context) do
    context = if is_map(context), do: context, else: %{}

    [
      read_field(context, "summary"),
      todo.summary,
      todo.title
    ]
    |> Enum.find_value(&waiting_reason_sentence/1)
  end

  defp waiting_reason_sentence(value) when is_binary(value) do
    sentence =
      value
      |> externalize_copy()
      |> first_sentence()

    if waiting_reason?(sentence), do: ensure_terminal_punctuation(sentence)
  end

  defp waiting_reason_sentence(_value), do: nil

  defp waiting_reason?(value) when is_binary(value) do
    value = String.downcase(value)

    contains_any?(value, [
      "asked",
      "waiting",
      "needs",
      "requires",
      "approval",
      "approve",
      "reply",
      "commitment",
      "confirm",
      "blocked"
    ])
  end

  defp waiting_reason?(_value), do: false

  defp due_sentence(%Todo{due_at: %DateTime{} = due_at, user_id: user_id}, metadata, opts) do
    timezone = due_timezone(metadata, opts, user_id)
    offset_hours = Timezones.offset_at(timezone.name, due_at, timezone.offset_hours)
    display_time = DateTime.add(due_at, offset_hours, :hour)
    timezone_label = Timezones.label(timezone.name, offset_hours)

    "Due #{Calendar.strftime(display_time, "%b %-d at %-I:%M %p")} #{timezone_label}."
  end

  defp due_sentence(_todo, _metadata, _opts), do: nil

  defp due_timezone(metadata, opts, user_id) do
    case first_present_timezone([
           Keyword.get(opts, :timezone_info),
           explicit_timezone(opts),
           metadata_timezone(metadata)
         ]) do
      nil -> user_timezone(user_id)
      timezone -> timezone
    end
  end

  defp put_user_timezone(opts, user_id) when is_list(opts) and is_binary(user_id) do
    if Keyword.has_key?(opts, :timezone_info) do
      opts
    else
      Keyword.put(opts, :timezone_info, user_timezone(user_id))
    end
  end

  defp put_user_timezone(opts, _user_id), do: opts

  defp user_timezone(user_id) when is_binary(user_id) do
    user_id
    |> Maraithon.BriefingSchedules.summarize_for_prompt()
    |> case do
      %{timezone_name: timezone_name, timezone_offset_hours: offset_hours} ->
        normalize_timezone(timezone_name, offset_hours)

      _other ->
        default_timezone()
    end
  rescue
    _exception -> default_timezone()
  end

  defp user_timezone(_user_id), do: default_timezone()

  defp explicit_timezone(opts) when is_list(opts) do
    timezone_name = Keyword.get(opts, :timezone_name) || Keyword.get(opts, :timezone)
    offset_hours = Keyword.get(opts, :timezone_offset_hours)

    if present?(timezone_name) or not is_nil(offset_hours) do
      normalize_timezone(timezone_name, offset_hours)
    end
  end

  defp explicit_timezone(_opts), do: nil

  defp metadata_timezone(metadata) when is_map(metadata) do
    public_metadata = PublicMetadata.todo(metadata)

    timezone_name =
      read_string(public_metadata, "timezone") ||
        read_string(public_metadata, "timezone_name") ||
        read_string(metadata, "timezone") ||
        read_string(metadata, "timezone_name")

    offset_hours =
      read_field(public_metadata, "timezone_offset_hours") ||
        read_field(metadata, "timezone_offset_hours")

    if present?(timezone_name) or not is_nil(offset_hours) do
      normalize_timezone(timezone_name, offset_hours)
    end
  end

  defp metadata_timezone(_metadata), do: nil

  defp normalize_timezone(timezone_name, offset_hours) do
    case Timezones.normalize(to_string(timezone_name || "")) do
      "offset:" <> offset ->
        %{name: nil, offset_hours: Timezones.normalize_offset(offset)}

      normalized when is_binary(normalized) ->
        fallback = offset_hours || Timezones.standard_offset(normalized)
        %{name: normalized, offset_hours: Timezones.normalize_offset(fallback)}

      _other ->
        %{name: nil, offset_hours: Timezones.normalize_offset(offset_hours)}
    end
  end

  defp first_present_timezone(values) do
    Enum.find(values, fn
      %{offset_hours: offset_hours} -> is_integer(offset_hours)
      _other -> false
    end)
  end

  defp default_timezone, do: %{name: nil, offset_hours: -5}

  defp created_from(metadata) do
    first_present([
      read_string(metadata, "created_from"),
      read_string(metadata, "origin"),
      read_string(metadata, "source_skill"),
      "todo"
    ])
  end

  defp familiarity(profile) do
    strength = read_field(profile, "relationship_strength") || 0
    count = read_field(profile, "interaction_count") || 0

    cond do
      strength >= 70 or count >= 20 -> "close"
      strength >= 35 or count >= 5 -> "known"
      true -> "unknown"
    end
  end

  defp explicit_confidence_level(value) when is_binary(value) do
    value = String.downcase(String.trim(value))

    cond do
      value in ["high", "strong"] -> "high"
      value in ["medium", "med", "moderate"] -> "medium"
      value in ["low", "weak"] -> "low"
      true -> value
    end
  end

  defp action_draft_present?(value) when is_binary(value), do: String.trim(value) != ""

  defp action_draft_present?(values) when is_list(values),
    do: Enum.any?(values, &action_draft_present?/1)

  defp action_draft_present?(value) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&action_draft_present?/1)

  defp action_draft_present?(value), do: not is_nil(value)

  # The todo write boundary guarantees every todo an action_draft by
  # synthesizing a "next_step"/"todo_write_boundary" placeholder, which is
  # not real reviewable draft material. Mirrors
  # Maraithon.TelegramAssistant.TodoActions.real_draft_ready?/1.
  defp real_draft?(draft),
    do: action_draft_present?(draft) and not placeholder_draft?(draft)

  defp placeholder_draft?(draft) when is_map(draft) do
    read_field(draft, "kind") == "next_step" or
      read_field(draft, "source") == "todo_write_boundary"
  end

  defp placeholder_draft?(_draft), do: false

  defp draft_preview_values(%{} = draft) do
    preferred =
      @draft_preview_keys
      |> Enum.map(&read_field(draft, &1))

    nested =
      draft
      |> Map.values()
      |> Enum.reject(&is_binary/1)

    (preferred ++ nested)
    |> Enum.flat_map(&draft_preview_values/1)
  end

  defp draft_preview_values(values) when is_list(values),
    do: Enum.flat_map(values, &draft_preview_values/1)

  defp draft_preview_values(value) when is_binary(value), do: [value]
  defp draft_preview_values(_value), do: []

  defp public_draft_preview(value) when is_binary(value) do
    value =
      value
      |> externalize_copy()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      blank?(value) -> nil
      public_card_text?(value) -> truncate(value, 500)
      true -> nil
    end
  end

  defp public_draft_preview(_value), do: nil

  defp evidence_type(value) when is_binary(value) do
    value = String.downcase(value)

    cond do
      String.contains?(value, ["due", "deadline", "by "]) -> "deadline"
      String.contains?(value, ["asked", "request"]) -> "request"
      String.contains?(value, ["commit", "promise"]) -> "commitment"
      String.contains?(value, ["reply", "respond"]) -> "reply"
      true -> "source_context"
    end
  end

  defp normalize_source("google_calendar"), do: "calendar"
  defp normalize_source("calendar_local"), do: "desktop"
  defp normalize_source("imessage"), do: "desktop"
  defp normalize_source("notes"), do: "desktop"
  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(_source), do: nil

  defp source_gap_labels(gaps) do
    gaps
    |> Enum.take(2)
    |> Enum.map(&source_gap_label/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "the source"
      labels -> source_list(labels)
    end
  end

  defp source_gap_label(value) when is_binary(value) do
    [source | _reason] = String.split(value, ":", parts: 2)

    case safe_source_name(source) do
      nil -> nil
      safe_source -> source_label(safe_source)
    end
  end

  defp source_gap_label(_value), do: nil

  defp source_gap_note(gaps, blocked_sources) do
    other_gaps =
      Enum.reject(gaps, fn gap ->
        source_gap_source(gap) == "desktop"
      end)

    [
      if(MapSet.member?(blocked_sources, "desktop"),
        do:
          "Mac companion context was not available, so iMessage, Notes, files, reminders, and browser context may be missing."
      ),
      if(other_gaps != [],
        do:
          "#{source_gap_labels(other_gaps)} context is incomplete; review the source before sending this."
      )
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp source_gap_sources(gaps) do
    gaps
    |> Enum.map(&source_gap_source/1)
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
  end

  defp source_gap_source(value) when is_binary(value) do
    [source | _reason] = String.split(value, ":", parts: 2)

    case safe_source_name(source) do
      nil -> nil
      safe_source -> normalize_source(safe_source)
    end
  end

  defp source_gap_source(_value), do: nil

  defp source_setup_action(blocked_sources) do
    if MapSet.member?(blocked_sources, "desktop") do
      "Open the Mac companion to refresh it."
    end
  end

  defp source_list(sources) do
    sources
    |> Enum.take(4)
    |> Enum.map(&source_list_label/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "the source"
      labels -> safe(Enum.join(labels, ", "))
    end
  end

  defp source_list_label(source) when is_binary(source) do
    case safe_source_name(source) do
      nil -> nil
      safe_source -> source_label(safe_source)
    end
  end

  defp source_list_label(_source), do: nil

  defp safe_source_name(value) when is_binary(value) do
    trimmed = String.trim(value)
    lower = String.downcase(trimmed)

    if trimmed == "" or Enum.any?(@unsafe_source_gap_markers, &String.contains?(lower, &1)),
      do: nil,
      else: trimmed
  end

  defp safe_source_name(_value), do: nil

  defp source_label(source) when source in @assistant_sources, do: "Maraithon"
  defp source_label("system"), do: "Maraithon"
  defp source_label("desktop"), do: "Mac companion"
  defp source_label(source) when is_binary(source), do: SourceLabels.label(source)
  defp source_label(_source), do: "Maraithon"

  defp state_context_items(context) do
    thread_state = state_label(read_field(context, "thread_state"))
    owed = owed_label(read_field(context, "owed_direction"))

    cond do
      present?(thread_state) and thread_state == owed ->
        [%{label: "State", value: thread_state}]

      present?(thread_state) and present?(owed) ->
        [%{label: "State", value: thread_state}, %{label: "Responsibility", value: owed}]

      present?(thread_state) ->
        [%{label: "State", value: thread_state}]

      present?(owed) ->
        [%{label: "State", value: owed}]

      true ->
        []
    end
  end

  defp meaningful_state?(value), do: present?(state_label(value))

  defp state_label(value) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    case normalized do
      "" -> nil
      "unknown" -> nil
      "unclear" -> nil
      "none" -> nil
      "na" -> nil
      "n_a" -> nil
      "not_applicable" -> nil
      "waiting_on_kent" -> "Waiting on you"
      "waiting_on_user" -> "Waiting on you"
      "waiting_on_me" -> "Waiting on you"
      "user_owes" -> "Waiting on you"
      "i_owe" -> "Waiting on you"
      "asked_of_me" -> "Waiting on you"
      "pending_reply" -> "Waiting on you"
      "waiting_on_them" -> "Waiting on them"
      "they_owe" -> "Waiting on them"
      "stale" -> "Older item"
      "active" -> "Active thread"
      "open" -> "Open"
      "resolved" -> "Handled"
      "completed" -> "Handled"
      "done" -> "Handled"
      _ -> titleize_state(normalized)
    end
  end

  defp state_label(_value), do: nil

  defp owed_label(value), do: state_label(value)

  defp humanize(nil), do: nil
  defp humanize(""), do: nil

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
  end

  defp humanize(value), do: to_string(value)

  defp titleize_state(value) when is_binary(value) do
    value
    |> humanize()
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp strip_leading_action_label(text) when is_binary(text) do
    String.replace(text, ~r/^\s*(next step|next|action|todo|decision)\s*:\s*/i, "")
  end

  defp strip_operator_action_prefix(text) when is_binary(text) do
    text
    |> String.replace(~r/^\s*(you should|you need to|you need|please)\s+/i, "")
    |> String.replace(~r/^\s*(i should|i need to|i need)\s+/i, "")
  end

  defp ensure_terminal_punctuation(text) when is_binary(text) do
    text = String.trim(text)

    if String.match?(text, ~r/[.!?]$/) do
      text
    else
      "#{text}."
    end
  end

  defp strip_terminal_punctuation(text) when is_binary(text) do
    String.replace(text, ~r/[.!?]\s*$/, "")
  end

  defp lowercase_first_character(<<first::utf8, rest::binary>>) do
    String.downcase(<<first::utf8>>) <> rest
  end

  defp lowercase_first_character(value), do: value

  defp naturalize_action_copy(value) when is_binary(value) do
    value
    |> UserFacingCopy.polish_text()
    |> String.replace(
      ~r/\s+for a one-line status update covering current state, owner, fix window if still open, and any user or customer impact\.?/i,
      ": is it resolved, who owns it, and were any users or customers affected?"
    )
    |> String.replace(
      ~r/\s+for a one-line status update covering current state, fix window if still open, and any user or customer impact\.?/i,
      ": is it resolved, who owns it, and were any users or customers affected?"
    )
    |> single_line()
  end

  defp naturalize_action_copy(value), do: value

  defp externalize_copy(value) when is_binary(value) do
    value
    |> UserFacingCopy.polish_text()
    |> strip_internal_lines()
    |> replace_internal_language()
    |> naturalize_action_copy()
  end

  defp externalize_copy(value), do: value

  defp strip_internal_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.match?(line, ~r/^\s*(open|title|priority|status|source|from)\s*:/i)
    end)
    |> Enum.join("\n")
  end

  defp replace_internal_language(text) do
    text
    |> String.replace(~r/\bthe user wants\b/i, "You want")
    |> String.replace(~r/\bthe user needs\b/i, "You need")
    |> String.replace(~r/\bthe user has\b/i, "You have")
    |> String.replace(~r/\bthe user is\b/i, "You are")
    |> String.replace(~r/\bthe user should\b/i, "You should")
    |> String.replace(~r/\bKent needs\b/i, "you need")
    |> String.replace(~r/\bKent has\b/i, "you have")
    |> String.replace(~r/\bKent should\b/i, "you should")
    |> String.replace(~r/\bKent is\b/i, "you are")
    |> String.replace(
      ~r/\bquick status check on whether the issue is resolved, who owns it, and whether users or customers were affected\b/i,
      "quick answer on whether it is fixed, who owns the follow-up, and whether any users or customers were affected"
    )
    |> String.replace(~r/\bChief_of_staff_morning_briefing\b/i, "the morning briefing")
    |> String.replace(~r/\bchief_of_staff_morning_briefing\b/i, "the morning briefing")
    |> String.replace(~r/\bChief_of_staff_commitment_tracker\b/i, "the open work review")
    |> String.replace(~r/\bchief_of_staff_commitment_tracker\b/i, "the open work review")
  end

  defp clean_title(value) when is_binary(value) do
    title =
      value
      |> UserFacingCopy.polish_text()
      |> String.replace(~r/^\s*(todo|action|next)\s*:\s*/i, "")
      |> single_line()

    if present?(title), do: truncate(title, 120), else: @fallback_title
  end

  defp clean_title(_value), do: @fallback_title

  defp title_mentions_person?(title, person) when is_binary(title) and is_binary(person) do
    title = String.downcase(title)

    person
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> case do
      [] -> false
      parts -> Enum.all?(parts, &String.contains?(title, &1))
    end
  end

  defp title_mentions_person?(_title, _person), do: false

  defp map_to_todo(map) do
    metadata = read_map(map, "metadata")

    %Todo{
      id: read_string(map, "id") || "preview",
      user_id: read_string(map, "user_id"),
      source: read_string(map, "source") || "manual",
      source_account_label: read_string(map, "source_account_label"),
      kind: read_string(map, "kind") || "general",
      attention_mode: read_string(map, "attention_mode") || "act_now",
      title: read_string(map, "title") || read_string(map, "next_action") || @fallback_title,
      summary: read_string(map, "summary") || @fallback_summary,
      next_action: read_string(map, "next_action") || @fallback_action,
      due_at: read_datetime(map, "due_at"),
      notes: read_string(map, "notes"),
      action_draft: read_map(map, "action_draft"),
      priority: read_integer(map, "priority", 50),
      status: read_string(map, "status") || "open",
      source_item_id: read_string(map, "source_item_id"),
      source_occurred_at: read_datetime(map, "source_occurred_at"),
      dedupe_key: read_string(map, "dedupe_key") || "preview",
      metadata: metadata,
      inserted_at: read_datetime(map, "inserted_at") || DateTime.utc_now(),
      updated_at: read_datetime(map, "updated_at") || DateTime.utc_now()
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      value = if is_map(value), do: stringify_keys(value), else: value
      {key, value}
    end)
  end

  defp read_map(map, key) when is_map(map) do
    case read_field(map, key) do
      value when is_map(value) -> stringify_keys(value)
      _other -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, safe_existing_atom(key))
  end

  defp read_field(_map, _key), do: nil

  defp read_string(map, key) when is_map(map) do
    case read_field(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _other ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp read_integer(map, key, default) when is_map(map) do
    case read_field(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_integer(_map, _key, default), do: default

  defp read_datetime(map, key) when is_map(map) do
    case read_field(map, key) do
      %DateTime{} = value ->
        value

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_datetime(_map, _key), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp contains_any?(text, terms) when is_binary(text) do
    Enum.any?(terms, &term_present?(text, &1))
  end

  defp contains_any?(_text, _terms), do: false

  defp term_present?(text, term) when is_binary(term) do
    if String.match?(term, ~r/^[a-z0-9_]+$/) do
      Regex.match?(~r/(^|[^a-z0-9_])#{Regex.escape(term)}($|[^a-z0-9_])/, text)
    else
      String.contains?(text, term)
    end
  end

  defp term_present?(_text, _term), do: false

  defp truthy?(true), do: true

  defp truthy?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "y"]))
  end

  defp truthy?(_value), do: false

  defp first_present(values), do: Enum.find(values, &present?/1)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value), do: not is_nil(value)
  defp blank?(value), do: not present?(value)

  defp single_line(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp first_sentence(text) when is_binary(text) do
    text = single_line(text)

    case Regex.run(~r/^(.+?[.!?])(?:\s|$)/, text) do
      [_, sentence] -> sentence
      _ -> text
    end
    |> truncate(180)
  end

  defp first_sentence(text), do: text

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      text
      |> String.slice(0, max_length)
      |> String.trim()
      |> Kernel.<>("...")
    else
      text
    end
  end

  defp datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso(_datetime), do: nil

  defp html_line(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: safe(value)
  end

  defp html_line(_value), do: nil

  defp plain_line(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp plain_line(_value), do: nil

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: value |> to_string() |> safe()
end
