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
  alias Maraithon.PreferenceMemory.Profile
  alias Maraithon.Repo

  require Logger

  @default_timezone_offset_hours -5
  @allowed_kinds ~w(content_filter urgency_boost quiet_hours)
  @default_applies_to ~w(gmail calendar slack telegram)

  @spec prompt_context(String.t() | nil) :: map()
  def prompt_context(user_id) when is_binary(user_id) do
    rules = active_rules(user_id)

    %{
      timezone_offset_hours: timezone_offset_hours(user_id),
      rules: rules,
      summary: Enum.map(rules, &rule_summary/1)
    }
  end

  def prompt_context(_user_id) do
    %{
      timezone_offset_hours: @default_timezone_offset_hours,
      rules: [],
      summary: []
    }
  end

  @spec active_rules(String.t()) :: [map()]
  def active_rules(user_id) when is_binary(user_id) do
    user_id
    |> profile()
    |> profile_rules()
    |> Enum.filter(&active_rule?/1)
    |> Enum.sort_by(&rule_sort_key/1)
  end

  def active_rules(_user_id), do: []

  @spec render_summary(String.t()) :: String.t()
  def render_summary(user_id) when is_binary(user_id) do
    case active_rules(user_id) do
      [] ->
        """
        No saved preference rules yet.

        Send /prefer followed by a durable rule, for example:
        /prefer ignore receipts
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
        now = DateTime.utc_now()

        attrs = %{
          user_id: user_id,
          rules: %{"rules" => retained},
          last_explicit_at: now
        }

        case upsert_profile(attrs) do
          {:ok, _profile} -> {:ok, "Removed preference `#{normalized_id}`."}
          {:error, reason} -> {:error, reason}
        end
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
    - For content_filter, use filters.topics (array of short slugs like receipts, invoices, newsletters, marketing, automated_notifications).
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
    - Strong candidates include: ignore receipt-like items, treat investors as urgent, suppress after-hours Telegram unless external.
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
    existing = active_rules(user_id)

    normalized =
      rules
      |> Enum.map(&normalize_rule(&1, source, now))
      |> Enum.reject(&is_nil/1)

    if normalized == [] do
      []
    else
      merged = merge_rules(existing, normalized)

      attrs =
        %{
          user_id: user_id,
          rules: %{"rules" => merged}
        }
        |> maybe_put_timestamp(explicit?, now)

      case upsert_profile(attrs) do
        {:ok, _profile} ->
          normalized

        {:error, reason} ->
          Logger.warning("Failed to persist preference rules", reason: inspect(reason))
          []
      end
    end
  end

  defp maybe_put_timestamp(attrs, true, now), do: Map.put(attrs, :last_explicit_at, now)
  defp maybe_put_timestamp(attrs, false, now), do: Map.put(attrs, :last_inferred_at, now)

  defp merge_rules(existing, new_rules) do
    existing_by_id =
      Map.new(existing, fn rule ->
        {rule_identifier(rule), rule}
      end)

    new_rules
    |> Enum.reduce(existing_by_id, fn rule, acc ->
      Map.put(acc, rule_identifier(rule), merge_rule(Map.get(acc, rule_identifier(rule)), rule))
    end)
    |> Map.values()
    |> Enum.sort_by(&rule_sort_key/1)
  end

  defp merge_rule(nil, new_rule), do: new_rule

  defp merge_rule(existing, new_rule) do
    existing_source = rule_source(existing)
    new_source = rule_source(new_rule)

    preferred =
      cond do
        existing_source == "explicit_telegram" and new_source != "explicit_telegram" -> existing
        existing_source != "explicit_telegram" and new_source == "explicit_telegram" -> new_rule
        rule_confidence(new_rule) >= rule_confidence(existing) -> new_rule
        true -> existing
      end

    merged_filters =
      existing
      |> Map.get("filters", %{})
      |> Map.merge(Map.get(new_rule, "filters", %{}))

    preferred
    |> Map.merge(new_rule)
    |> Map.put("filters", merged_filters)
  end

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
    normalized = String.downcase(instruction)
    timezone = timezone_offset_hours(user_id)

    cond do
      String.contains?(normalized, "receipt") or String.contains?(normalized, "invoice") ->
        %{
          "reply" =>
            "Understood. I'll stop surfacing receipt-style noise unless there's a real ask.",
          "rules" => [
            %{
              "id" => "ignore_receipts",
              "kind" => "content_filter",
              "label" => "Ignore receipt-style notifications",
              "instruction" =>
                "Suppress receipts, invoices, payment confirmations, and order confirmations unless there is a clear human ask or unresolved commitment.",
              "applies_to" => @default_applies_to,
              "confidence" => 0.96,
              "filters" => %{
                "topics" => [
                  "receipts",
                  "invoices",
                  "payment_confirmations",
                  "order_confirmations"
                ],
                "require_human_ask_to_override" => true
              }
            }
          ]
        }

      String.contains?(normalized, "investor") ->
        %{
          "reply" => "Understood. I'll bias investor-related loops toward urgency.",
          "rules" => [
            %{
              "id" => "treat_investors_urgent",
              "kind" => "urgency_boost",
              "label" => "Treat investors as urgent",
              "instruction" =>
                "Bias investor-related Gmail, Calendar, and Slack loops toward higher urgency and faster interruption.",
              "applies_to" => @default_applies_to,
              "confidence" => 0.94,
              "filters" => %{"topics" => ["investor"], "priority_bias" => "high"}
            }
          ]
        }

      String.contains?(normalized, "after 8") and String.contains?(normalized, "external") ->
        %{
          "reply" => "Understood. After hours, I'll only interrupt for external loops.",
          "rules" => [
            %{
              "id" => "after_hours_external_only",
              "kind" => "quiet_hours",
              "label" => "After-hours Telegram only for external loops",
              "instruction" =>
                "After 8pm local time, suppress Telegram interruptions unless the counterparty is external.",
              "applies_to" => ["telegram"],
              "confidence" => 0.92,
              "filters" => %{
                "start_hour_local" => 20,
                "end_hour_local" => if(timezone <= -8, do: 8, else: 8),
                "allow_if_external" => true
              }
            }
          ]
        }

      true ->
        nil
    end
  end

  defp fallback_infer_from_feedback(_user_id, %Insight{} = insight, "not_helpful") do
    metadata_text =
      [
        insight.title,
        insight.summary,
        get_in(insight.metadata || %{}, ["record", "commitment"]),
        get_in(insight.metadata || %{}, ["context_brief"])
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    if String.contains?(metadata_text, "receipt") or String.contains?(metadata_text, "payment") or
         String.contains?(metadata_text, "invoice") or String.contains?(metadata_text, "order") do
      %{
        "reply" => "Learned that receipt-style notifications are usually noise for you.",
        "rules" => [
          %{
            "id" => "ignore_receipts",
            "kind" => "content_filter",
            "label" => "Ignore receipt-style notifications",
            "instruction" =>
              "Suppress receipts, invoices, payment confirmations, and order confirmations unless there is a clear human ask or unresolved commitment.",
            "applies_to" => @default_applies_to,
            "confidence" => 0.88,
            "filters" => %{
              "topics" => [
                "receipts",
                "invoices",
                "payment_confirmations",
                "order_confirmations"
              ],
              "require_human_ask_to_override" => true
            }
          }
        ]
      }
    else
      nil
    end
  end

  defp fallback_infer_from_feedback(_user_id, %Insight{} = insight, "helpful") do
    metadata_text =
      [
        insight.title,
        insight.summary,
        get_in(insight.metadata || %{}, ["record", "commitment"]),
        get_in(insight.metadata || %{}, ["context_brief"])
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    if String.contains?(metadata_text, "investor") or String.contains?(metadata_text, "board") do
      %{
        "reply" => "Learned to treat investor-related loops as urgent.",
        "rules" => [
          %{
            "id" => "treat_investors_urgent",
            "kind" => "urgency_boost",
            "label" => "Treat investors as urgent",
            "instruction" =>
              "Bias investor-related Gmail, Calendar, and Slack loops toward higher urgency and faster interruption.",
            "applies_to" => @default_applies_to,
            "confidence" => 0.84,
            "filters" => %{"topics" => ["investor", "board"], "priority_bias" => "high"}
          }
        ]
      }
    else
      nil
    end
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

  defp timezone_offset_hours(user_id) when is_binary(user_id) do
    Agent
    |> where(
      [agent],
      agent.user_id == ^user_id and agent.behavior == "founder_followthrough_agent"
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

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
