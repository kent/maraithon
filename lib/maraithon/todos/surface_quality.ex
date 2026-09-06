defmodule Maraithon.Todos.SurfaceQuality do
  @moduledoc """
  Scores whether a todo has enough source, person, and action context to be
  safely surfaced as a Telegram chief-of-staff card.
  """

  alias Maraithon.Todos.AttentionRanker
  alias Maraithon.Todos.Todo

  @source_context_keys ~w(
    body_excerpt checked_evidence evidence evidence_summary excerpt gmail_message_id
    gmail_thread_id html_link message_id permalink quote source_body source_evidence
    source_excerpt source_ref source_refs source_url thread_id url
  )

  @human_context_keys ~w(
    company context context_brief family_member family_role life_domain organization person
    people project project_name relationship relationship_context relationship_domain
    sensitivity source_tags todo_policy user_requested why_it_matters why_now
  )

  @why_now_keys ~w(
    deadline due_by due_date due_at next_event_at source_insight_due_at why_it_matters why_now
    user_requested
  )

  @specific_context_keys ~w(
    body_excerpt context context_brief email_subject evidence evidence_summary excerpt
    goal_category holiday_date holiday_name holiday_phase_key message_subject project project_name quote relationship_context
    source_evidence source_excerpt source_refs source_subject subject thread_subject topic
    todo_policy why_it_matters why_now
  )

  @confidence_keys ~w(confidence false_positive_risk scope_confidence telegram_fit_score)

  @doc """
  Returns a compact scorecard for a todo or serialized todo map.
  """
  def assess(todo_or_map, opts \\ []) do
    todo = todo_map(todo_or_map)
    metadata = read_map(todo, "metadata")

    profile =
      Keyword.get_lazy(opts, :attention_profile, fn -> attention_profile(todo_or_map, todo) end)

    named_person? = named_person?(todo, metadata, profile)
    familiar? = familiar_relationship?(metadata, profile)

    checks = %{
      "action" => present?(read_field(todo, "next_action")),
      "personalized_copy" => personalized_copy?(todo),
      "source_evidence" => source_evidence?(todo, metadata),
      "human_context" => human_context?(todo, metadata, profile, named_person?, familiar?),
      "specific_context" => specific_context?(todo, metadata),
      "why_now" => why_now?(todo, metadata, profile),
      "action_buttons" => not Map.has_key?(todo, "id") or present?(read_field(todo, "id"))
    }

    required_missing =
      checks
      |> Enum.reject(fn {_key, passed?} -> passed? end)
      |> Enum.map(fn {key, _passed?} -> key end)
      |> Enum.sort()

    warnings =
      []
      |> maybe_warn(
        "crm_write_through",
        named_person? and not crm_write_through?(metadata, profile)
      )
      |> maybe_warn("generic_copy", not personalized_copy?(todo))
      |> maybe_warn("confidence", not confidence_present?(metadata))
      |> maybe_warn("source_quote", not source_quote_present?(todo, metadata))

    %{
      "score" => score(required_missing, warnings),
      "surfaceable" => required_missing == [],
      "missing" => required_missing,
      "warnings" => warnings,
      "source_backed" => checks["source_evidence"],
      "human_context" => checks["human_context"],
      "specific_context" => checks["specific_context"],
      "why_now" => checks["why_now"],
      "crm_write_through" => crm_write_through?(metadata, profile),
      "named_person" => named_person?,
      "familiar_relationship" => familiar?
    }
  end

  def surfaceable?(todo_or_map) do
    todo_or_map
    |> assess()
    |> Map.get("surfaceable", false)
  end

  def annotate_attrs(attrs) when is_map(attrs) do
    metadata =
      attrs
      |> read_map("metadata")
      |> Map.put("surface_quality", assess(attrs))

    Map.put(attrs, "metadata", metadata)
  end

  def annotate_attrs(attrs), do: attrs

  defp source_evidence?(todo, metadata) do
    present?(read_field(todo, "source")) and
      (present?(read_field(todo, "source_item_id")) or
         present?(read_field(todo, "dedupe_key")) or
         any_present?(metadata, @source_context_keys) or
         record_has_context?(read_map(metadata, "record")))
  end

  defp source_quote_present?(todo, metadata) do
    present?(read_field(todo, "source_item_id")) or
      any_present?(
        metadata,
        ~w(body_excerpt checked_evidence evidence evidence_summary excerpt quote source_body source_evidence source_excerpt source_refs)
      ) or
      record_has_context?(read_map(metadata, "record"))
  end

  defp human_context?(todo, metadata, profile, true, false) do
    any_present?(metadata, @human_context_keys) or
      (source_evidence?(todo, metadata) and present?(read_field(todo, "summary"))) or
      profile_context_present?(
        profile,
        ~w(company organization relationship why project life_domain)
      )
  end

  defp human_context?(todo, metadata, profile, _named_person?, _familiar?) do
    present?(read_field(todo, "summary")) or
      any_present?(metadata, @human_context_keys) or
      profile_context_present?(
        profile,
        ~w(person company organization relationship why project life_domain)
      )
  end

  defp why_now?(todo, metadata, profile) do
    present?(read_field(todo, "due_at")) or
      read_field(todo, "attention_mode") == "act_now" or
      any_present?(metadata, @why_now_keys) or
      read_field(profile, "personal_family") == true or
      read_field(profile, "actively_waiting") == true or
      read_field(profile, "business_project") == true or
      read_field(profile, "stale_confirmation_candidate") == true
  end

  defp specific_context?(todo, metadata) do
    any_present?(metadata, @specific_context_keys) or
      record_has_context?(read_map(metadata, "record")) or
      source_text_mentions_topic?(read_field(todo, "title")) or
      source_text_mentions_topic?(read_field(todo, "summary")) or
      source_text_mentions_topic?(read_field(todo, "next_action"))
  end

  defp crm_write_through?(metadata, profile) do
    people_present?(read_field(metadata, "people")) or
      people_present?(read_field(metadata, "crm_people")) or
      present?(read_field(metadata, "person_id")) or
      present?(read_field(metadata, "person")) or
      profile_context_present?(profile, ~w(person company organization relationship))
  end

  defp named_person?(todo, metadata, profile) do
    crm_write_through?(metadata, profile) or
      person_name_like?(read_field(todo, "title")) or
      person_name_like?(read_field(todo, "summary")) or
      person_name_like?(read_field(todo, "next_action"))
  end

  defp familiar_relationship?(metadata, profile) do
    relationship_strength(metadata, profile) >= 90 or
      integer_value(read_field(metadata, "interaction_count"), 0) >= 12 or
      integer_value(read_field(profile, "interaction_count"), 0) >= 12
  end

  defp confidence_present?(metadata), do: any_present?(metadata, @confidence_keys)

  defp record_has_context?(record) when is_map(record) do
    any_present?(record, ~w(ask body body_excerpt commitment evidence source_body summary))
  end

  defp record_has_context?(_record), do: false

  defp personalized_copy?(todo) do
    not generic_copy?(user_facing_text(todo))
  end

  defp user_facing_text(todo) when is_map(todo) do
    [
      read_field(todo, "title"),
      read_field(todo, "summary"),
      read_field(todo, "next_action"),
      read_field(todo, "recommended_action")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
  end

  defp user_facing_text(_todo), do: ""

  defp generic_copy?(text) when is_binary(text) do
    text = String.downcase(text)

    Enum.any?(
      [
        "user committed",
        "the user committed",
        "follow-up not yet sent",
        "follow up not yet sent",
        "no later reply or follow-through",
        "no sent follow-up",
        "reply now with owner, eta",
        "with owner, eta, and",
        "with owner and eta.",
        "exact artifact or update",
        "confirm artifact status",
        "confirm the artifact status",
        "review and decide the next step",
        "open this item and decide whether it still needs action"
      ],
      &String.contains?(text, &1)
    )
  end

  defp generic_copy?(_text), do: false

  defp source_text_mentions_topic?(text) when is_binary(text) do
    text = String.downcase(text)

    not generic_copy?(text) and
      (String.contains?(text, " about ") or
         String.contains?(text, " on ") or
         String.contains?(text, " asked for ") or
         String.contains?(text, " asked to ") or
         String.contains?(text, " needs ") or
         String.contains?(text, " due ") or
         String.contains?(text, " before ") or
         String.contains?(text, " blocked until ") or
         String.contains?(text, " waiting on ") or
         String.contains?(text, " because ") or
         String.contains?(text, " context: "))
  end

  defp source_text_mentions_topic?(_text), do: false

  defp people_present?(people) when is_list(people), do: Enum.any?(people, &is_map/1)
  defp people_present?(%{}), do: true
  defp people_present?(_people), do: false

  defp profile_context_present?(profile, keys) when is_map(profile) do
    profile
    |> read_map("context")
    |> any_present?(keys)
  end

  defp profile_context_present?(_profile, _keys), do: false

  defp any_present?(map, keys) when is_map(map) do
    Enum.any?(keys, &(present?(read_field(map, &1)) or nested_present?(read_field(map, &1))))
  end

  defp any_present?(_map, _keys), do: false

  defp nested_present?(value) when is_list(value), do: Enum.any?(value, &nested_present?/1)
  defp nested_present?(value) when is_map(value), do: map_size(value) > 0
  defp nested_present?(_value), do: false

  defp attention_profile(%Todo{} = todo, _map), do: AttentionRanker.profile(todo)

  defp attention_profile(todo_or_map, map) when is_map(todo_or_map) do
    case read_field(map, "attention_profile") do
      profile when is_map(profile) -> profile
      _other -> AttentionRanker.profile(map)
    end
  rescue
    _error -> %{}
  end

  defp attention_profile(_todo_or_map, map), do: AttentionRanker.profile(map)

  defp todo_map(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "source" => todo.source,
      "kind" => todo.kind,
      "attention_mode" => todo.attention_mode,
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "due_at" => todo.due_at,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => todo.source_occurred_at,
      "dedupe_key" => todo.dedupe_key,
      "metadata" => todo.metadata || %{}
    }
  end

  defp todo_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp todo_map(_value), do: %{}

  defp read_map(map, key) when is_map(map) do
    case read_field(map, key) do
      value when is_map(value) -> Map.new(value, fn {k, v} -> {to_string(k), v} end)
      _other -> %{}
    end
  end

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp read_field(_map, _key), do: nil

  defp relationship_strength(metadata, profile) do
    max(
      integer_value(read_field(metadata, "relationship_strength"), 0),
      integer_value(read_field(profile, "relationship_strength"), 0)
    )
  end

  defp integer_value(value, _default) when is_integer(value), do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp person_name_like?(value) when is_binary(value) do
    Regex.match?(~r/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b/u, value)
  end

  defp person_name_like?(_value), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(%DateTime{}), do: true
  defp present?(%Date{}), do: true
  defp present?(%NaiveDateTime{}), do: true
  defp present?(true), do: true
  defp present?(value) when is_integer(value), do: true
  defp present?(value) when is_float(value), do: true
  defp present?(_value), do: false

  defp maybe_warn(warnings, warning, true), do: [warning | warnings]
  defp maybe_warn(warnings, _warning, false), do: warnings

  defp score(missing, warnings) do
    max(0, 100 - length(missing) * 24 - length(warnings) * 5)
  end
end
