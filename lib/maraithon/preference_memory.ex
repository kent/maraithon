defmodule Maraithon.PreferenceMemory do
  @moduledoc """
  Durable operator preference memory shared across insight generation and delivery.

  Preferences are stored as normalized rules so the LLM can reason over them and
  Telegram delivery can enforce the small subset of rules that must be honored
  synchronously, such as quiet hours.
  """

  import Ecto.Query

  alias Maraithon.Agents.Agent
  alias Maraithon.Insights.Insight
  alias Maraithon.LLM
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory.{Profile, Rule, RuleEvent}
  alias Maraithon.Repo

  require Logger

  @default_timezone_offset_hours -5
  @allowed_kinds ~w(content_filter urgency_boost quiet_hours routing_preference action_preference style_preference)
  @default_applies_to ~w(gmail calendar slack telegram)
  @autosave_threshold 0.90
  @confirm_threshold 0.70

  @spec prompt_context(String.t() | nil) :: map()
  def prompt_context(user_id) when is_binary(user_id) do
    rules = active_rules(user_id)

    %{
      timezone_offset_hours: timezone_offset_hours(user_id),
      rules: rules,
      summary: Enum.map(rules, &rule_summary/1),
      operator_memory_summaries: OperatorMemory.summaries_for_prompt(user_id)
    }
  end

  def prompt_context(_user_id) do
    %{
      timezone_offset_hours: @default_timezone_offset_hours,
      rules: [],
      summary: [],
      operator_memory_summaries: []
    }
  end

  @spec active_rules(String.t()) :: [map()]
  def active_rules(user_id) when is_binary(user_id) do
    case active_rule_rows(user_id) do
      [] ->
        user_id
        |> profile()
        |> profile_rules()
        |> Enum.filter(&active_rule?/1)
        |> Enum.sort_by(&rule_sort_key/1)

      rows ->
        Enum.sort_by(rows, &rule_sort_key/1)
    end
  end

  def active_rules(_user_id), do: []

  def pending_rules(user_id) when is_binary(user_id) do
    Rule
    |> where([rule], rule.user_id == ^user_id and rule.status == "pending_confirmation")
    |> order_by([rule], desc: rule.updated_at, desc: rule.inserted_at)
    |> Repo.all()
    |> Enum.map(&serialize_rule/1)
  end

  def pending_rules(_user_id), do: []

  @spec render_summary(String.t()) :: String.t()
  def render_summary(user_id) when is_binary(user_id) do
    case active_rules(user_id) do
      [] ->
        """
        No saved preference rules yet.

        Send /prefer followed by a durable rule, for example:
        /prefer ignore receipts
        /prefer ignore sales outreach unless I've engaged
        /prefer treat investors as urgent
        /prefer don't interrupt after 8pm unless external
        """
        |> String.trim()

      rules ->
        rendered =
          rules
          |> Enum.map_join("\n", fn rule ->
            "- `#{rule["id"]}`: #{rule_summary(rule)}"
          end)

        """
        Current preference memory:
        #{rendered}

        Use /prefer ... to add or update a rule.
        Use /forget RULE_ID to remove one.
        """
        |> String.trim()
    end
  end

  @spec apply_explicit_instruction(String.t(), String.t(), keyword()) ::
          {:ok, %{reply: String.t(), learned: [map()]}} | {:error, term()}
  def apply_explicit_instruction(user_id, instruction, opts \\ [])
      when is_binary(user_id) and is_binary(instruction) do
    instruction = String.trim(instruction)

    if instruction == "" do
      {:ok,
       %{reply: "Send /prefer followed by the rule you want Maraithon to remember.", learned: []}}
    else
      result =
        parse_explicit_instruction(user_id, instruction, opts) ||
          fallback_parse_instruction(user_id, instruction)

      case result do
        %{"rules" => rules} = parsed ->
          learned = persist_rules(user_id, rules, "explicit_telegram", explicit?: true)
          reply = explicit_reply(parsed, learned)
          {:ok, %{reply: reply, learned: learned}}

        nil ->
          {:error, :unable_to_parse}
      end
    end
  end

  @spec forget_rule(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def forget_rule(user_id, rule_id)
      when is_binary(user_id) and is_binary(rule_id) do
    normalized_id = normalize_rule_id(rule_id)

    if normalized_id == "" do
      {:error, :invalid_rule_id}
    else
      current = active_rules(user_id)
      retained = Enum.reject(current, &(rule_identifier(&1) == normalized_id))

      if length(retained) == length(current) do
        {:error, :rule_not_found}
      else
        Repo.transaction(fn ->
          Rule
          |> where([rule], rule.user_id == ^user_id and rule.status == "active")
          |> Repo.all()
          |> Enum.filter(&(rule_identifier(serialize_rule(&1)) == normalized_id))
          |> Enum.each(fn rule ->
            rule
            |> Rule.changeset(%{status: "superseded"})
            |> Repo.update!()

            log_rule_event(user_id, rule.id, "reverted", %{"source" => "forget_rule"})
          end)

          sync_profile_from_rows!(user_id)
          _ = OperatorMemory.refresh_user_summaries(user_id)
        end)

        {:ok, "Removed preference `#{normalized_id}`."}
      end
    end
  end

  @spec learn_from_feedback(String.t(), Insight.t(), String.t(), keyword()) ::
          {:ok, %{reply: String.t() | nil, learned: [map()]}} | {:error, term()}
  def learn_from_feedback(user_id, insight, feedback, opts \\ [])

  def learn_from_feedback(user_id, %Insight{} = insight, feedback, opts)
      when is_binary(user_id) and feedback in ["helpful", "not_helpful"] do
    result =
      infer_rules_from_feedback(user_id, insight, feedback, opts) ||
        fallback_infer_from_feedback(user_id, insight, feedback)

    case result do
      %{"rules" => rules} = parsed ->
        learned = persist_rules(user_id, rules, "feedback_inference", explicit?: false)
        {:ok, %{reply: inference_reply(parsed, learned), learned: learned}}

      nil ->
        {:ok, %{reply: nil, learned: []}}
    end
  rescue
    error ->
      Logger.warning("Preference learning failed", reason: Exception.message(error))
      {:error, error}
  end

  def learn_from_feedback(_user_id, _insight, _feedback, _opts),
    do: {:ok, %{reply: nil, learned: []}}

  def save_interpreted_rules(user_id, rules, source, opts \\ [])
      when is_binary(user_id) and is_list(rules) and is_binary(source) do
    {:ok, persist_rules(user_id, rules, source, opts)}
  end

  def confirm_rules(user_id, rule_ids, opts \\ [])
      when is_binary(user_id) and is_list(rule_ids) do
    now = DateTime.utc_now()
    conversation_id = Keyword.get(opts, :conversation_id)
    source_turn_id = Keyword.get(opts, :source_turn_id)
    source_delivery_id = Keyword.get(opts, :source_delivery_id)

    rules =
      Rule
      |> where(
        [rule],
        rule.user_id == ^user_id and rule.id in ^rule_ids and
          rule.status == "pending_confirmation"
      )
      |> Repo.all()

    Repo.transaction(fn ->
      Enum.each(rules, fn rule ->
        rule
        |> Rule.changeset(%{status: "active", confirmed_at: now})
        |> Repo.update!()

        log_rule_event(
          user_id,
          rule.id,
          "confirmed",
          %{"source" => "telegram_confirmation"},
          conversation_id: conversation_id,
          source_turn_id: source_turn_id,
          source_delivery_id: source_delivery_id
        )
      end)

      sync_profile_from_rows!(user_id)
      _ = OperatorMemory.refresh_user_summaries(user_id)
    end)

    {:ok, Enum.map(rules, &serialize_rule/1)}
  end

  def reject_rules(user_id, rule_ids, opts \\ [])
      when is_binary(user_id) and is_list(rule_ids) do
    conversation_id = Keyword.get(opts, :conversation_id)
    source_turn_id = Keyword.get(opts, :source_turn_id)
    source_delivery_id = Keyword.get(opts, :source_delivery_id)

    rules =
      Rule
      |> where(
        [rule],
        rule.user_id == ^user_id and rule.id in ^rule_ids and
          rule.status == "pending_confirmation"
      )
      |> Repo.all()

    Repo.transaction(fn ->
      Enum.each(rules, fn rule ->
        rule
        |> Rule.changeset(%{status: "rejected"})
        |> Repo.update!()

        log_rule_event(
          user_id,
          rule.id,
          "rejected",
          %{"source" => "telegram_confirmation"},
          conversation_id: conversation_id,
          source_turn_id: source_turn_id,
          source_delivery_id: source_delivery_id
        )
      end)

      sync_profile_from_rows!(user_id)
      _ = OperatorMemory.refresh_user_summaries(user_id)
    end)

    {:ok, Enum.map(rules, &serialize_rule/1)}
  end

  @spec allow_telegram_interrupt?(String.t(), Insight.t(), DateTime.t()) :: boolean()
  def allow_telegram_interrupt?(user_id, %Insight{} = insight, %DateTime{} = now)
      when is_binary(user_id) do
    rules =
      active_rules(user_id)
      |> Enum.filter(&(rule_kind(&1) == "quiet_hours"))

    Enum.all?(rules, fn rule -> quiet_hours_allows?(user_id, insight, rule, now) end)
  end

  def allow_telegram_interrupt?(_user_id, _insight, _now), do: true

  defp parse_explicit_instruction(user_id, instruction, opts) do
    prompt = explicit_instruction_prompt(user_id, instruction)

    case llm_json(prompt, opts) do
      {:ok, parsed} ->
        parsed

      {:error, :invalid_json} ->
        nil

      {:error, reason} ->
        Logger.warning("Preference instruction parsing failed", reason: inspect(reason))
        nil
    end
  end

  defp infer_rules_from_feedback(user_id, %Insight{} = insight, feedback, opts) do
    prompt = feedback_inference_prompt(user_id, insight, feedback)

    case llm_json(prompt, opts) do
      {:ok, parsed} ->
        parsed

      {:error, :invalid_json} ->
        nil

      {:error, reason} ->
        Logger.warning("Preference feedback inference failed", reason: inspect(reason))
        nil
    end
  end

  defp explicit_instruction_prompt(user_id, instruction) do
    """
    You convert plain-English operator preferences into durable Maraithon policy rules.

    Current preference memory JSON:
    #{Jason.encode!(prompt_context(user_id))}

    Instruction:
    #{instruction}

    Return ONLY valid JSON object:
    {
      "reply":"short confirmation for the operator",
      "rules":[
        {
          "id":"snake_case_identifier",
          "kind":"content_filter|urgency_boost|quiet_hours",
          "label":"short label",
          "instruction":"clear durable policy instruction",
          "applies_to":["gmail","calendar","slack","telegram"],
          "confidence":0.0,
          "filters":{}
        }
      ]
    }

    Rules:
    - Only create durable policies that should affect future triage, not one-off tasks.
    - Prefer empty rules if the instruction is ambiguous or too item-specific.
    - For content_filter, use filters.topics (array of short slugs like receipts, invoices, newsletters, marketing, automated_notifications, sales_outreach, cold_outreach).
    - For urgency_boost, use filters.topics (array like investor, customer, hiring, external) and optionally filters.priority_bias = "high".
    - For quiet_hours, use filters.start_hour_local, filters.end_hour_local, and filters.allow_if_external.
    - Confidence must be between 0 and 1.
    """
  end

  defp feedback_inference_prompt(user_id, %Insight{} = insight, feedback) do
    """
    You infer durable operator preferences from Telegram feedback on Maraithon insights.

    Current preference memory JSON:
    #{Jason.encode!(prompt_context(user_id))}

    Feedback:
    #{feedback}

    Insight JSON:
    #{Jason.encode!(%{source: insight.source, category: insight.category, title: insight.title, summary: insight.summary, recommended_action: insight.recommended_action, priority: insight.priority, confidence: insight.confidence, metadata: insight.metadata || %{}})}

    Return ONLY valid JSON object:
    {
      "reply":"optional short note about what was learned",
      "rules":[
        {
          "id":"snake_case_identifier",
          "kind":"content_filter|urgency_boost|quiet_hours",
          "label":"short label",
          "instruction":"clear durable policy instruction",
          "applies_to":["gmail","calendar","slack","telegram"],
          "confidence":0.0,
          "filters":{}
        }
      ]
    }

    Rules:
    - Use reasoning, not shallow keyword matching.
    - Learn a rule only if the feedback suggests a durable preference that should generalize.
    - Return empty rules for one-off or ambiguous feedback.
    - Strong candidates include: ignore receipt-like items, ignore sales outreach unless the user engaged, treat investors as urgent, suppress after-hours Telegram unless external.
    """
  end

  defp llm_json(prompt, opts) when is_binary(prompt) do
    llm_complete = Keyword.get(opts, :llm_complete) || configured_llm_complete()

    with {:ok, response} <- llm_complete.(prompt),
         {:ok, parsed} <- decode_json_object(response) do
      {:ok, parsed}
    end
  end

  defp configured_llm_complete do
    config = Application.get_env(:maraithon, :preference_memory, [])

    case Keyword.get(config, :llm_complete) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        &default_llm_complete/1
    end
  end

  defp default_llm_complete(prompt) when is_binary(prompt) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 900,
      "temperature" => 0.1,
      "reasoning_effort" => "medium"
    }

    with {:ok, response} <- LLM.provider().complete(params) do
      {:ok, response.content}
    end
  end

  defp decode_json_object(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_json}
    end
  end

  defp persist_rules(user_id, rules, source, opts) when is_list(rules) do
    explicit? = Keyword.get(opts, :explicit?, false)
    now = DateTime.utc_now()

    normalized =
      rules
      |> Enum.map(&normalize_rule(&1, source, now))
      |> Enum.reject(&is_nil/1)

    if normalized == [] do
      []
    else
      save_policy = Keyword.get(opts, :save_policy, :smart)
      conversation_id = Keyword.get(opts, :conversation_id)
      source_turn_id = Keyword.get(opts, :source_turn_id)
      source_delivery_id = Keyword.get(opts, :source_delivery_id)

      Repo.transaction(fn ->
        persisted =
          Enum.map(normalized, fn rule ->
            confidence = rule_confidence(rule)
            conflicts = conflicting_active_rules(user_id, rule)
            stronger_conflict? = Enum.any?(conflicts, &stronger_conflict?(&1, rule, explicit?))

            status =
              cond do
                explicit? -> "active"
                save_policy == :active -> "active"
                save_policy == :confirm -> "pending_confirmation"
                stronger_conflict? -> "pending_confirmation"
                confidence >= @autosave_threshold -> "active"
                confidence >= @confirm_threshold -> "pending_confirmation"
                true -> "rejected"
              end

            attrs =
              rule
              |> Map.put("user_id", user_id)
              |> Map.put("status", status)
              |> maybe_put_confirmed_at(status, now)

            persisted_rule = upsert_rule!(attrs)

            if status == "active" do
              supersede_conflicts!(user_id, persisted_rule, conflicts, source)
            end

            event_type =
              case status do
                "active" when explicit? -> "confirmed"
                "active" -> "auto_saved"
                "pending_confirmation" -> "proposed"
                _ -> "rejected"
              end

            log_rule_event(
              user_id,
              persisted_rule.id,
              event_type,
              %{"source" => source, "rule" => serialize_rule(persisted_rule)},
              conversation_id: conversation_id,
              source_turn_id: source_turn_id,
              source_delivery_id: source_delivery_id
            )

            persisted_rule
          end)

        sync_profile_from_rows!(user_id)
        _ = OperatorMemory.refresh_user_summaries(user_id)

        Enum.map(persisted, &serialize_rule/1)
      end)
      |> case do
        {:ok, saved} ->
          saved

        {:error, reason} ->
          Logger.warning("Failed to persist preference rules", reason: inspect(reason))
          []
      end
    end
  end

  defp maybe_put_confirmed_at(attrs, "active", now), do: Map.put(attrs, "confirmed_at", now)
  defp maybe_put_confirmed_at(attrs, _status, _now), do: attrs

  defp normalize_rule(rule, source, now) when is_map(rule) do
    kind = rule_kind(rule)
    id = rule_identifier(rule)
    label = non_empty_string(rule["label"])
    instruction = non_empty_string(rule["instruction"])

    if id == "" or label == nil or instruction == nil or kind not in @allowed_kinds do
      nil
    else
      %{
        "id" => id,
        "kind" => kind,
        "label" => label,
        "instruction" => instruction,
        "applies_to" => normalize_applies_to(rule["applies_to"]),
        "confidence" => clamp(rule_confidence(rule), 0.0, 1.0),
        "filters" => normalize_filters(kind, rule["filters"]),
        "source" => source,
        "status" => "active",
        "learned_at" => DateTime.to_iso8601(DateTime.truncate(now, :second)),
        "evidence" => normalize_evidence(rule["evidence"], rule["label"])
      }
    end
  end

  defp normalize_rule(_rule, _source, _now), do: nil

  defp normalize_filters("content_filter", filters) when is_map(filters) do
    %{
      "topics" => normalize_topic_list(filters["topics"]),
      "require_human_ask_to_override" =>
        boolean_or_default(filters["require_human_ask_to_override"], true)
    }
  end

  defp normalize_filters("urgency_boost", filters) when is_map(filters) do
    %{
      "topics" => normalize_topic_list(filters["topics"]),
      "priority_bias" => non_empty_string(filters["priority_bias"]) || "high"
    }
  end

  defp normalize_filters("quiet_hours", filters) when is_map(filters) do
    %{
      "start_hour_local" => parse_hour(filters["start_hour_local"], 20),
      "end_hour_local" => parse_hour(filters["end_hour_local"], 8),
      "allow_if_external" => boolean_or_default(filters["allow_if_external"], true)
    }
  end

  defp normalize_filters(_kind, _filters), do: %{}

  defp normalize_topic_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_topic/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_topic_list(_value), do: []

  defp normalize_topic(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp normalize_topic(value), do: value |> to_string() |> normalize_topic()

  defp normalize_applies_to(values) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_binary(value) -> String.downcase(String.trim(value))
      value -> value |> to_string() |> String.downcase() |> String.trim()
    end)
    |> Enum.filter(&(&1 in @default_applies_to))
    |> Enum.uniq()
    |> case do
      [] -> @default_applies_to
      normalized -> normalized
    end
  end

  defp normalize_applies_to(_), do: @default_applies_to

  defp normalize_evidence(value, label) when is_list(value) do
    value
    |> Enum.map(&non_empty_string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> [label || "user preference"]
      items -> items
    end
  end

  defp normalize_evidence(_, label), do: [label || "user preference"]

  defp explicit_reply(parsed, learned) do
    parsed_reply = non_empty_string(parsed["reply"])

    cond do
      learned != [] and parsed_reply != nil ->
        parsed_reply

      learned != [] ->
        "Saved preference: #{learned |> Enum.map(&rule_summary/1) |> Enum.join("; ")}"

      parsed_reply != nil ->
        parsed_reply

      true ->
        "I couldn't turn that into a durable rule yet. Try /prefer with a broader preference."
    end
  end

  defp inference_reply(parsed, learned) do
    parsed_reply = non_empty_string(parsed["reply"])

    cond do
      learned != [] and parsed_reply != nil -> parsed_reply
      learned != [] -> "Learned: #{learned |> Enum.map(&rule_summary/1) |> Enum.join("; ")}"
      true -> nil
    end
  end

  defp fallback_parse_instruction(user_id, instruction) do
    _ = user_id
    _ = instruction
    nil
  end

  defp fallback_infer_from_feedback(_user_id, %Insight{} = insight, "not_helpful") do
    _ = insight
    nil
  end

  defp fallback_infer_from_feedback(_user_id, %Insight{} = insight, "helpful") do
    _ = insight
    nil
  end

  defp fallback_infer_from_feedback(_user_id, _insight, _feedback), do: nil

  defp quiet_hours_allows?(user_id, %Insight{} = insight, rule, now) do
    filters = Map.get(rule, "filters", %{})
    local_hour = local_hour(now, user_id, rule)
    start_hour = parse_hour(filters["start_hour_local"], 20)
    end_hour = parse_hour(filters["end_hour_local"], 8)
    quiet_hours? = within_quiet_hours?(local_hour, start_hour, end_hour)

    cond do
      not quiet_hours? ->
        true

      boolean_or_default(filters["allow_if_external"], true) and external_counterparty?(insight) ->
        true

      true ->
        false
    end
  end

  defp within_quiet_hours?(_hour, start_hour, end_hour) when start_hour == end_hour, do: false

  defp within_quiet_hours?(hour, start_hour, end_hour) when start_hour < end_hour,
    do: hour >= start_hour and hour < end_hour

  defp within_quiet_hours?(hour, start_hour, end_hour),
    do: hour >= start_hour or hour < end_hour

  defp local_hour(%DateTime{} = now, user_id, rule) do
    offset =
      case get_in(rule, ["filters", "timezone_offset_hours"]) do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_integer(value, timezone_offset_hours(user_id))
        _ -> timezone_offset_hours(user_id)
      end

    now
    |> DateTime.add(offset * 3600, :second)
    |> Map.get(:hour)
  end

  defp external_counterparty?(%Insight{source: "gmail"} = insight) do
    metadata = insight.metadata || %{}
    account_domain = email_domain(metadata["account"])

    [metadata["from"], metadata["to"]]
    |> Enum.flat_map(&extract_domains/1)
    |> Enum.any?(fn domain ->
      domain != nil and domain != "" and domain != account_domain
    end)
  end

  defp external_counterparty?(%Insight{source: "calendar"} = insight) do
    metadata = insight.metadata || %{}
    account_domain = email_domain(metadata["account"])

    [metadata["organizer"], metadata["attendee_preview"]]
    |> Enum.flat_map(&extract_domains/1)
    |> Enum.any?(fn domain ->
      domain != nil and domain != "" and domain != account_domain
    end)
  end

  defp external_counterparty?(%Insight{source: "slack"}), do: false
  defp external_counterparty?(_insight), do: false

  defp extract_domains(value) when is_binary(value) do
    Regex.scan(~r/[A-Z0-9._%+\-]+@([A-Z0-9.\-]+\.[A-Z]{2,})/i, value, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
  end

  defp extract_domains(_), do: []

  defp email_domain(value) when is_binary(value) do
    value
    |> extract_domains()
    |> List.first()
  end

  defp email_domain(_), do: nil

  defp upsert_rule!(attrs) do
    user_id = Map.fetch!(attrs, "user_id")
    label = Map.fetch!(attrs, "label")
    kind = Map.fetch!(attrs, "kind")

    existing =
      Rule
      |> where([rule], rule.user_id == ^user_id and rule.label == ^label and rule.kind == ^kind)
      |> order_by([rule], desc: rule.updated_at, desc: rule.inserted_at)
      |> limit(1)
      |> Repo.one()

    case existing do
      nil ->
        %Rule{}
        |> Rule.changeset(normalize_rule_attrs(attrs))
        |> Repo.insert!()

      %Rule{} = rule ->
        rule
        |> Rule.changeset(normalize_rule_attrs(attrs))
        |> Repo.update!()
    end
  end

  defp normalize_rule_attrs(attrs) do
    evidence =
      attrs
      |> Map.get("evidence")
      |> evidence_map()
      |> Map.put_new("memory_id", Map.get(attrs, "id"))

    %{
      user_id: Map.get(attrs, "user_id"),
      status: Map.get(attrs, "status", "active"),
      source: Map.get(attrs, "source", "telegram_inferred"),
      kind: Map.get(attrs, "kind"),
      label: Map.get(attrs, "label"),
      instruction: Map.get(attrs, "instruction"),
      applies_to: Map.get(attrs, "applies_to", @default_applies_to),
      filters: Map.get(attrs, "filters", %{}),
      confidence: clamp(rule_confidence(attrs), 0.0, 1.0),
      evidence: evidence,
      confirmed_at: Map.get(attrs, "confirmed_at")
    }
  end

  defp log_rule_event(user_id, rule_id, event_type, payload, opts \\ []) do
    %RuleEvent{}
    |> RuleEvent.changeset(%{
      user_id: user_id,
      rule_id: rule_id,
      conversation_id: Keyword.get(opts, :conversation_id),
      source_turn_id: Keyword.get(opts, :source_turn_id),
      source_delivery_id: Keyword.get(opts, :source_delivery_id),
      event_type: event_type,
      payload: payload
    })
    |> Repo.insert!()
  end

  defp sync_profile_from_rows!(user_id) do
    now = DateTime.utc_now()

    attrs = %{
      user_id: user_id,
      rules: %{"rules" => active_rule_rows(user_id)},
      last_inferred_at: now,
      last_explicit_at: now
    }

    case upsert_profile(attrs) do
      {:ok, _profile} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp upsert_profile(attrs) do
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")

    case profile(user_id) do
      nil ->
        %Profile{}
        |> Profile.changeset(attrs)
        |> Repo.insert()

      %Profile{} = profile ->
        profile
        |> Profile.changeset(attrs)
        |> Repo.update()
    end
  end

  defp profile(user_id) when is_binary(user_id), do: Repo.get_by(Profile, user_id: user_id)
  defp profile(_user_id), do: nil

  defp profile_rules(nil), do: []

  defp profile_rules(%Profile{} = profile) do
    case profile.rules do
      %{"rules" => rules} when is_list(rules) -> rules
      %{rules: rules} when is_list(rules) -> rules
      _ -> []
    end
  end

  defp active_rule?(rule) do
    is_map(rule) and rule_kind(rule) in @allowed_kinds and rule_status(rule) == "active"
  end

  defp active_rule_rows(user_id) when is_binary(user_id) do
    Rule
    |> where([rule], rule.user_id == ^user_id and rule.status == "active")
    |> order_by([rule], desc: rule.confirmed_at, desc: rule.updated_at, desc: rule.inserted_at)
    |> Repo.all()
    |> Enum.map(&serialize_rule/1)
  end

  defp active_rule_rows(_user_id), do: []

  defp conflicting_active_rules(user_id, rule) when is_binary(user_id) and is_map(rule) do
    incoming_label = non_empty_string(rule["label"])
    incoming_kind = rule_kind(rule)

    Rule
    |> where(
      [stored],
      stored.user_id == ^user_id and stored.status == "active" and stored.kind == ^incoming_kind
    )
    |> Repo.all()
    |> Enum.reject(fn stored ->
      stored.label == incoming_label
    end)
    |> Enum.filter(&rules_conflict?(serialize_rule(&1), rule))
  end

  defp conflicting_active_rules(_user_id, _rule), do: []

  defp stronger_conflict?(%Rule{} = stored, incoming_rule, incoming_explicit?) do
    compare_trust(stored, incoming_rule, incoming_explicit?) == :gt
  end

  defp supersede_conflicts!(user_id, %Rule{} = persisted_rule, conflicts, source) do
    Enum.each(conflicts, fn
      %Rule{id: id} = conflict when id != persisted_rule.id ->
        case compare_trust(
               persisted_rule,
               serialize_rule(conflict),
               persisted_rule.source == "explicit_telegram"
             ) do
          result when result in [:gt, :eq] ->
            conflict
            |> Rule.changeset(%{status: "superseded"})
            |> Repo.update!()

            log_rule_event(
              user_id,
              conflict.id,
              "superseded",
              %{
                "source" => source,
                "superseded_by_rule_id" => persisted_rule.id,
                "superseded_by_label" => persisted_rule.label
              }
            )

          _ ->
            :ok
        end

      _ ->
        :ok
    end)
  end

  defp timezone_offset_hours(user_id) when is_binary(user_id) do
    Agent
    |> where(
      [agent],
      agent.user_id == ^user_id and
        agent.behavior in ["founder_followthrough_agent", "ai_chief_of_staff"]
    )
    |> order_by([agent], desc: agent.updated_at, desc: agent.inserted_at)
    |> limit(1)
    |> select([agent], agent.config)
    |> Repo.one()
    |> case do
      %{} = config ->
        parse_integer(config["timezone_offset_hours"], @default_timezone_offset_hours)

      _ ->
        @default_timezone_offset_hours
    end
  end

  defp timezone_offset_hours(_user_id), do: @default_timezone_offset_hours

  defp rule_summary(rule) do
    label = non_empty_string(rule["label"])
    instruction = non_empty_string(rule["instruction"])

    case rule_kind(rule) do
      "content_filter" -> instruction || label || "Ignore a class of noisy items."
      "urgency_boost" -> instruction || label || "Bias an important class of items upward."
      "quiet_hours" -> instruction || label || "Hold Telegram interruptions during quiet hours."
      _ -> label || instruction || "Saved preference"
    end
  end

  defp rule_sort_key(rule) do
    explicit_score = if rule_source(rule) == "explicit_telegram", do: 0, else: 1

    kind_score =
      case rule_kind(rule) do
        "quiet_hours" -> 0
        "urgency_boost" -> 1
        "content_filter" -> 2
        _ -> 3
      end

    {explicit_score, kind_score, rule_identifier(rule)}
  end

  defp rule_kind(rule), do: non_empty_string(rule["kind"]) || ""
  defp rule_status(rule), do: non_empty_string(rule["status"]) || "active"
  defp rule_source(rule), do: non_empty_string(rule["source"]) || "feedback_inference"

  defp rules_conflict?(stored_rule, incoming_rule) do
    overlap?(stored_rule["applies_to"], incoming_rule["applies_to"]) and
      kind_conflict?(rule_kind(stored_rule), stored_rule, incoming_rule)
  end

  defp kind_conflict?("content_filter", stored_rule, incoming_rule),
    do: topic_overlap?(stored_rule, incoming_rule)

  defp kind_conflict?("urgency_boost", stored_rule, incoming_rule),
    do: topic_overlap?(stored_rule, incoming_rule)

  defp kind_conflict?("quiet_hours", _stored_rule, _incoming_rule), do: true
  defp kind_conflict?("routing_preference", _stored_rule, _incoming_rule), do: true
  defp kind_conflict?("action_preference", _stored_rule, _incoming_rule), do: true
  defp kind_conflict?("style_preference", _stored_rule, _incoming_rule), do: true
  defp kind_conflict?(_, _stored_rule, _incoming_rule), do: false

  defp topic_overlap?(stored_rule, incoming_rule) do
    stored_topics = get_in(stored_rule, ["filters", "topics"]) |> normalize_topic_list()
    incoming_topics = get_in(incoming_rule, ["filters", "topics"]) |> normalize_topic_list()

    stored_topics == [] or incoming_topics == [] or
      MapSet.disjoint?(MapSet.new(stored_topics), MapSet.new(incoming_topics)) == false
  end

  defp overlap?(left, right) do
    left_values = normalize_applies_to(left)
    right_values = normalize_applies_to(right)
    MapSet.disjoint?(MapSet.new(left_values), MapSet.new(right_values)) == false
  end

  defp compare_trust(%Rule{} = stored_rule, incoming_rule, incoming_explicit?) do
    compare_trust(serialize_rule(stored_rule), incoming_rule, incoming_explicit?)
  end

  defp compare_trust(stored_rule, incoming_rule, incoming_explicit?)
       when is_map(stored_rule) and is_map(incoming_rule) do
    stored_score = rule_trust_score(stored_rule, rule_source(stored_rule) == "explicit_telegram")
    incoming_score = rule_trust_score(incoming_rule, incoming_explicit?)

    cond do
      stored_score > incoming_score -> :gt
      stored_score < incoming_score -> :lt
      true -> :eq
    end
  end

  defp rule_trust_score(rule, explicit?) do
    confirmed? = not is_nil(Map.get(rule, "confirmed_at"))

    {
      if(explicit?, do: 1, else: 0),
      if(confirmed?, do: 1, else: 0),
      clamp(rule_confidence(rule), 0.0, 1.0)
    }
  end

  defp serialize_rule(%Rule{} = rule) do
    memory_id = get_in(rule.evidence || %{}, ["memory_id"]) || rule.id

    %{
      "id" => rule_identifier(%{"id" => memory_id, "label" => rule.label}),
      "rule_id" => rule.id,
      "kind" => rule.kind,
      "label" => rule.label,
      "instruction" => rule.instruction,
      "applies_to" => rule.applies_to || [],
      "filters" => rule.filters || %{},
      "confidence" => rule.confidence || 0.0,
      "source" => rule.source,
      "status" => rule.status,
      "confirmed_at" => serialize_datetime(rule.confirmed_at),
      "last_used_at" => serialize_datetime(rule.last_used_at),
      "evidence" => rule.evidence || %{}
    }
  end

  defp serialize_rule(rule) when is_map(rule), do: rule

  defp rule_identifier(rule) do
    case non_empty_string(rule["id"]) do
      nil ->
        rule
        |> Map.get("label", "preference")
        |> to_string()
        |> normalize_rule_id()

      id ->
        normalize_rule_id(id)
    end
  end

  defp normalize_rule_id(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp normalize_rule_id(value), do: value |> to_string() |> normalize_rule_id()

  defp rule_confidence(rule) do
    case rule["confidence"] do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> 0.8
        end

      _ ->
        0.8
    end
  end

  defp parse_hour(value, _default) when is_integer(value) and value >= 0 and value <= 23,
    do: value

  defp parse_hour(value, default) when is_binary(value),
    do: parse_integer(value, default) |> clamp_integer(0, 23)

  defp parse_hour(_value, default), do: default

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp clamp_integer(value, min, _max) when value < min, do: min
  defp clamp_integer(value, _min, max) when value > max, do: max
  defp clamp_integer(value, _min, _max), do: value

  defp non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_string(value) when is_integer(value), do: Integer.to_string(value)
  defp non_empty_string(_value), do: nil

  defp boolean_or_default(value, _default) when value in [true, false], do: value

  defp boolean_or_default(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp boolean_or_default(_value, default), do: default

  defp serialize_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serialize_datetime(_), do: nil

  defp evidence_map(value) when is_map(value), do: value
  defp evidence_map(value) when is_list(value), do: %{"items" => value}
  defp evidence_map(_), do: %{}
end
