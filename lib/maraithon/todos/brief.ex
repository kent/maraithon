defmodule Maraithon.Todos.Brief do
  @moduledoc """
  The chief-of-staff brief for one todo: why it matters, what is actually
  going on, the single best move, the steps only the user can take, and a
  ready-to-send reply when one is warranted.

  Briefs are generated on the brief model tier (`Maraithon.LLM.complete_brief/1`)
  from the full source context (`Maraithon.Todos.Brief.Context`), then stored
  on the todo under `metadata["brief"]`. A content fingerprint marks the brief
  stale when the todo itself changes. When the brief includes a reply, the
  todo's `action_draft` is replaced with it so mobile, Telegram, and the chat
  primer all offer the same wording.
  """

  alias Maraithon.Drafts
  alias Maraithon.LLM
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Todos
  alias Maraithon.Todos.Brief.Context
  alias Maraithon.Todos.Todo

  require Logger

  @version 3
  @sentinel "TODO_BRIEF_JSON_V1"
  @metadata_key "brief"
  @lease_key "brief_generation"
  @lease_seconds 240
  @max_tokens 6_000
  @timeout_ms 240_000
  @reply_channels ~w(gmail slack imessage whatsapp)
  @efforts ~w(under_2_min under_15_min longer)
  @max_steps 8
  @max_open_questions 3
  @max_prompt_bytes 100_000

  def version, do: @version
  def sentinel, do: @sentinel
  def metadata_key, do: @metadata_key

  @doc """
  Returns the stored brief when it is current for this todo, otherwise nil.

  A brief is current when its version matches and its fingerprint still
  matches the todo's content. Status is deliberately not part of the
  fingerprint so a brief survives Mark done.
  """
  def current(%Todo{} = todo) do
    case stored(todo) do
      %{"version" => @version, "fingerprint" => fingerprint} = brief ->
        if fingerprint == fingerprint(todo), do: brief, else: nil

      _other ->
        nil
    end
  end

  def current(_todo), do: nil

  @doc "The stored brief regardless of freshness, or nil."
  def stored(%Todo{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @metadata_key) do
      %{} = brief -> brief
      _other -> nil
    end
  end

  def stored(_todo), do: nil

  @doc "True when another process holds an active generation lease."
  def generating?(%Todo{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @lease_key) do
      %{"lease_until" => until} when is_binary(until) -> future?(until)
      _other -> false
    end
  end

  def generating?(_todo), do: false

  @doc "The reply prepared by the brief, or nil."
  def reply(%Todo{} = todo) do
    case current(todo) do
      %{"reply" => %{"body" => body} = reply} when is_binary(body) and body != "" -> reply
      _other -> nil
    end
  end

  def reply(_todo), do: nil

  @doc "Public projection for API surfaces (no fingerprint)."
  def public(%Todo{} = todo) do
    case current(todo) do
      nil -> nil
      brief -> Map.drop(brief, ["fingerprint"])
    end
  end

  def public(_todo), do: nil

  @doc "Durably schedules a missing or stale brief on the per-user model lane."
  def enqueue_generation(%Todo{} = todo) do
    cond do
      todo.status not in ~w(open snoozed) ->
        {:ok, nil}

      current(todo) ->
        {:ok, nil}

      true ->
        BackgroundJobs.enqueue("todo_brief_generation", %{
          user_id: todo.user_id,
          queue: "runtime_model_user",
          partition_key: tenant_partition(todo.user_id),
          rate_limit_key: "model",
          dedupe_key: "todo-brief:#{todo.id}:#{fingerprint(todo)}",
          max_attempts: 3,
          payload: %{"todo_id" => todo.id}
        })
    end
  end

  def enqueue_generation(_todo), do: {:error, :invalid_todo}

  @doc """
  Generates the brief for a todo and stores it on the todo.

  Options:
    * `:force` - regenerate even when a current brief exists
    * `:on_progress` - `fn label -> any` for live status
    * `:llm_complete` - override for tests (`fn params -> {:ok, response}`)

  Returns `{:ok, %Todo{}}` with the refreshed todo, `{:error, :in_progress}`
  when another generation holds the lease, or `{:error, reason}`.
  """
  def generate_and_store(user_id, todo_id, opts \\ [])

  def generate_and_store(user_id, todo_id, opts)
      when is_binary(user_id) and is_binary(todo_id) and is_list(opts) do
    force? = Keyword.get(opts, :force, false)

    with %Todo{} = todo <- Todos.get_for_user(user_id, todo_id),
         :ok <- ensure_generation_needed(todo, force?),
         {:ok, todo} <- claim_lease(user_id, todo, force?),
         {:ok, brief, model} <- generate(user_id, todo, opts) do
      stored_brief =
        brief
        |> Map.put("version", @version)
        |> Map.put(
          "generated_at",
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        )
        |> Map.put("model", model)
        |> Map.put("fingerprint", fingerprint(todo))

      Todos.put_brief(user_id, todo.id, stored_brief, action_draft_from_reply(brief["reply"]))
    else
      {:error, :already_current} ->
        {:ok, Todos.get_for_user(user_id, todo_id)}

      {:error, reason} = error ->
        _ = release_lease(user_id, todo_id)

        Logger.warning("todo brief generation failed",
          target_reference: Maraithon.Redaction.fingerprint(todo_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        error

      nil ->
        {:error, :not_found}
    end
  end

  def generate_and_store(_user_id, _todo_id, _opts), do: {:error, :not_found}

  @doc """
  Generates a brief without storing it. Returns `{:ok, brief, model}`.
  """
  def generate(user_id, %Todo{} = todo, opts \\ []) when is_binary(user_id) do
    progress = Keyword.get(opts, :on_progress, fn _label -> :ok end)
    context = Context.build(user_id, todo, opts)

    progress.("Thinking it through")

    params = %{
      "messages" => [
        %{"role" => "system", "content" => system_prompt()},
        %{"role" => "user", "content" => user_prompt(context)}
      ],
      "max_tokens" => @max_tokens,
      "timeout_ms" => @timeout_ms,
      "temperature" => 0.3
    }

    complete = Keyword.get(opts, :llm_complete, &default_complete/1)

    with {:ok, response} <- complete.(params),
         {:ok, content} <- response_content(response),
         {:ok, parsed} <- decode_json(content),
         {:ok, brief} <- normalize(parsed, context) do
      {:ok,
       brief
       |> maybe_put("source_history", Context.source_history(context))
       |> maybe_put("source_subject", Context.source_subject(context)), response_model(response)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_brief_response, other}}
    end
  end

  @doc """
  Content fingerprint used to detect a stale brief.
  """
  def fingerprint(%Todo{} = todo) do
    metadata = todo.metadata || %{}

    [
      todo.title,
      todo.summary,
      todo.next_action,
      todo.action_plan,
      todo.notes,
      todo.source_item_id,
      iso(todo.due_at),
      Map.get(metadata, "source_quote"),
      Map.get(metadata, "source_excerpt"),
      Map.get(metadata, "matching_message_excerpt")
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  # Same unconfigured-provider fallback the todo intelligence pipeline uses,
  # so test and local environments without an LLM key still produce briefs.
  defp default_complete(params) do
    case LLM.complete_brief(params) do
      {:error, {:llm_provider_not_configured, _message}} = error ->
        if mock_when_unconfigured?() do
          Maraithon.LLM.MockProvider.complete(params)
        else
          error
        end

      result ->
        result
    end
  end

  defp mock_when_unconfigured? do
    :maraithon
    |> Application.get_env(:todos, [])
    |> Keyword.get(:mock_llm_when_unconfigured, false)
  end

  # ---------------------------------------------------------------------------
  # Lease
  # ---------------------------------------------------------------------------

  defp ensure_generation_needed(todo, false) do
    if current(todo), do: {:error, :already_current}, else: :ok
  end

  defp ensure_generation_needed(_todo, true), do: :ok

  defp claim_lease(user_id, %Todo{} = todo, force?) do
    if generating?(todo) and not force? do
      {:error, :in_progress}
    else
      lease = %{
        "lease_until" =>
          DateTime.utc_now()
          |> DateTime.add(@lease_seconds, :second)
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()
      }

      Todos.merge_metadata(user_id, todo.id, %{@lease_key => lease})
    end
  end

  defp release_lease(user_id, todo_id) do
    Todos.merge_metadata(user_id, todo_id, %{@lease_key => nil})
  end

  # ---------------------------------------------------------------------------
  # Prompt
  # ---------------------------------------------------------------------------

  defp system_prompt do
    """
    You are the user's chief of staff. You are briefing them on ONE work item so they can act immediately.

    Your bar:
    - Be specific. Use names, dates, numbers, and facts from the sources. Never invent facts; if something is unknown, name exactly what to check.
    - No preamble, no hedging, no filler, no praise. Every sentence must earn its place.
    - Think about what the other person actually needs and what the user is on the hook for. Point out anything the user already did that resolves or partly resolves this.
    - Plain hyphens only. Never use em dashes or en dashes anywhere in the output.

    Field rules:
    - why_it_matters: 1-2 sentences on the concrete stakes and timing (who is waiting, what is blocked, when it is due).
    - situation: 2-4 sentences on what is actually being asked, grounded in the source thread, including any relevant history with the person.
    - recommendation: one sentence. The single best move.
    - steps: only actions the user must do themselves (settings to open, files to gather, decisions to make). Imperative, specific to the platform mentioned (macOS System Settings paths, Gmail, Slack). Leave empty when the reply is the whole job. Max 6.
    - reply: the finished message, or null when no message is warranted (a personal task with no counterpart, or the user already answered). Write it AS the user in the first person, in their voice from the voice profile. Match the channel: Slack and messages are short and casual, no subject, no sign-off; email has a subject, a greeting, a brief body, and signs with the user's first name. No placeholders like [insert link] unless the user truly must fill something in. If a fact is missing, either ask for it in the reply or set expectations with a specific time. Set resolves_todo to true only if sending this message fully completes the work item.
    - open_questions: only decisions the user alone can make, phrased so a one-word answer works. Max 2. Usually empty.
    - effort: under_2_min, under_15_min, or longer.

    Return STRICT JSON only. No markdown, no code fences, no commentary. Marker: #{@sentinel}
    """
    |> String.trim()
  end

  defp user_prompt(context) do
    sections =
      [
        {"NOW", context.now},
        {"USER IDENTITY", context.identity},
        {"WORK ITEM (JSON)", encode(context.todo)},
        {"CHIEF OF STAFF READ (JSON)", encode(context.card)},
        {"SOURCE THREAD (JSON)", encode(context.source)},
        {"PEOPLE INVOLVED (JSON)", encode(context.people)},
        {"USER VOICE PROFILE FOR #{String.upcase(context.channel || "MESSAGES")}", context.voice},
        {"REPLY CHANNEL", context.channel || "none (no conversation source)"}
      ]
      |> Enum.reject(fn {_label, value} -> value in [nil, "", "null", "[]", "{}"] end)
      |> Enum.map(fn {label, value} -> "#{label}:\n#{value}" end)

    prompt =
      (sections ++
         [
           """
           Return JSON with exactly this shape:
           {"why_it_matters": "string", "situation": "string", "recommendation": "string", "steps": ["string"], "reply": {"channel": "gmail|slack|imessage|whatsapp", "to": "string or null", "subject": "string or null", "body": "string", "resolves_todo": true} or null, "open_questions": ["string"], "effort": "under_2_min|under_15_min|longer"}
           #{@sentinel}
           """
           |> String.trim()
         ])
      |> Enum.join("\n\n")

    fit_prompt(prompt, context)
  end

  # Drops the deepest source detail first when the prompt would exceed the
  # provider budget, so a long thread never turns into a request failure.
  defp fit_prompt(prompt, context) do
    cond do
      byte_size(prompt) <= @max_prompt_bytes ->
        prompt

      Map.get(context.source, "thread") ->
        user_prompt(%{context | source: Map.delete(context.source, "thread")})

      is_list(Map.get(context.source, "messages")) and
          length(Map.get(context.source, "messages")) > 10 ->
        messages = context.source |> Map.get("messages") |> Enum.take(-10)
        user_prompt(%{context | source: Map.put(context.source, "messages", messages)})

      is_map(Map.get(context.source, "message")) ->
        message =
          context.source |> Map.get("message") |> Map.update("body", nil, &truncate(&1, 2_000))

        user_prompt(%{context | source: Map.put(context.source, "message", message)})

      true ->
        binary_part(prompt, 0, @max_prompt_bytes)
    end
  end

  defp encode(value) do
    case Jason.encode(value, pretty: false) do
      {:ok, json} -> json
      {:error, _reason} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Response handling
  # ---------------------------------------------------------------------------

  defp response_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp response_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp response_content(content) when is_binary(content), do: {:ok, content}
  defp response_content(_response), do: {:error, :missing_llm_content}

  defp response_model(%{model: model}) when is_binary(model), do: model
  defp response_model(%{"model" => model}) when is_binary(model), do: model
  defp response_model(_response), do: LLM.brief_model()

  defp decode_json(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = parsed} ->
        {:ok, parsed}

      _ ->
        case Regex.run(~r/\{.*\}/s, trimmed) do
          [candidate] ->
            case Jason.decode(candidate) do
              {:ok, %{} = parsed} -> {:ok, parsed}
              _ -> {:error, :invalid_brief_json}
            end

          _ ->
            {:error, :invalid_brief_json}
        end
    end
  end

  defp normalize(parsed, context) when is_map(parsed) do
    why = clean(parsed["why_it_matters"])
    situation = clean(parsed["situation"])
    recommendation = clean(parsed["recommendation"])

    if is_nil(why) and is_nil(recommendation) do
      {:error, :empty_brief}
    else
      {:ok,
       %{
         "why_it_matters" => why,
         "situation" => situation,
         "recommendation" => recommendation,
         "steps" => string_list(parsed["steps"], @max_steps),
         "reply" => normalize_reply(parsed["reply"], context),
         "open_questions" => string_list(parsed["open_questions"], @max_open_questions),
         "effort" => normalize_effort(parsed["effort"])
       }}
    end
  end

  defp normalize(_parsed, _context), do: {:error, :invalid_brief_shape}

  defp normalize_reply(%{} = reply, context) do
    body = clean_multiline(reply["body"] || reply["text"])

    if is_nil(body) do
      nil
    else
      channel =
        case reply["channel"] do
          value when value in @reply_channels -> value
          "email" -> "gmail"
          _ -> context.channel
        end

      %{
        "channel" => channel,
        "to" => clean(reply["to"]),
        "subject" => if(channel == "gmail", do: clean(reply["subject"]), else: nil),
        "body" => body,
        "resolves_todo" => reply["resolves_todo"] == true
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp normalize_reply(_reply, _context), do: nil

  defp normalize_effort(value) when value in @efforts, do: value
  defp normalize_effort(_value), do: nil

  defp string_list(values, max) when is_list(values) do
    values
    |> Enum.map(&clean/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(max)
  end

  defp string_list(_values, _max), do: []

  defp clean(value) when is_binary(value) do
    value
    |> Drafts.sanitize_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp clean(_value), do: nil

  defp clean_multiline(value) when is_binary(value) do
    value
    |> Drafts.sanitize_text()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp clean_multiline(_value), do: nil

  # ---------------------------------------------------------------------------
  # Draft projection
  # ---------------------------------------------------------------------------

  @doc """
  Builds the `action_draft` map for a brief reply so every other surface
  (mobile, Telegram, chat primer) sends the same wording.
  """
  def action_draft_from_reply(%{"body" => body} = reply) when is_binary(body) and body != "" do
    channel = Map.get(reply, "channel")

    %{
      "kind" => "reply",
      "label" => draft_label(channel),
      "channel" => channel,
      "subject" => Map.get(reply, "subject"),
      "to" => Map.get(reply, "to"),
      "text" => body,
      "body" => body,
      "source" => "todo_brief",
      "style" => "ready_to_send"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def action_draft_from_reply(_reply), do: nil

  defp draft_label("gmail"), do: "Email reply ready"
  defp draft_label("slack"), do: "Slack reply ready"
  defp draft_label(_channel), do: "Reply ready"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp future?(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> DateTime.compare(at, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_value), do: ""

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> " [truncated]"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp tenant_partition(user_id) when is_binary(user_id) do
    digest = :crypto.hash(:sha256, user_id) |> Base.url_encode64(padding: false)
    "tenant:#{digest}"
  end
end
