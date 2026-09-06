defmodule Maraithon.Todos.PublicMetadata do
  @moduledoc """
  Filters todo and people metadata down to fields safe for product surfaces.

  Source pipelines keep internal identifiers, scoring hints, and model runtime
  data in metadata. This module is the boundary before that data reaches web,
  mobile, or assistant-visible output.
  """

  alias Maraithon.Todos.UserFacingCopy

  @public_todo_keys MapSet.new(~w(
    account
    account_email
    bcc
    body_excerpt
    cc
    channel_name
    company
    contact
    context_brief
    conversation_name
    due_context
    email_subject
    from
    recipient
    team_name
    to
    workspace_name
    holiday_date
    holiday_name
    life_domain
    omni_project
    organization
    person
    project
    project_name
    quote
    relationship
    relationship_context
    requested_by
    resolution_note
    sender_name
    source_account_label
    source_excerpt
    source_quote
    subject
    thread_state
    thread_subject
    topic
    why_it_matters
    why_now
  ))

  @public_person_keys MapSet.new(~w(
    deal_stage
    deal_value
    family_member
    family_role
    mobile_status
    relationship_domain
    relationship_preset
    relationship_preset_label
    todo_policy
  ))

  @internal_terms ~w(
    agent
    assistant
    confidence
    generation
    heuristic
    internal
    json
    llm
    model
    metadata
    prompt
    quality
    rationale
    reasoning
    score
    source_backed
    source_health
    threshold
    token
  )

  def todo(metadata), do: filter(metadata, @public_todo_keys)

  def person(metadata), do: filter(metadata, @public_person_keys)

  def public_text?(value) when is_binary(value), do: public_value?(value)
  def public_text?(_value), do: false

  defp filter(metadata, public_keys) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)

      with true <- public_key?(key, public_keys),
           {:ok, public_value} <- public_value(value) do
        Map.put(acc, key, public_value)
      else
        _ -> acc
      end
    end)
  end

  defp filter(_metadata, _public_keys), do: %{}

  defp public_key?(key, public_keys) when is_binary(key) do
    MapSet.member?(public_keys, key) and not internal_key?(key)
  end

  defp internal_key?(key) do
    normalized = key |> String.downcase() |> String.replace("_", " ")
    Enum.any?(@internal_terms, &String.contains?(normalized, &1))
  end

  defp public_value?(value) when is_binary(value), do: match?({:ok, _}, public_value(value))

  defp public_value?(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: true

  defp public_value?(_value), do: false

  defp public_value(value) when is_binary(value) do
    value =
      value
      |> String.split(~r/\R/u)
      |> Enum.map(&clean_public_line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      value == "" -> :error
      internal_value?(value) -> :error
      true -> {:ok, value}
    end
  end

  defp public_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: {:ok, value}

  defp public_value(_value), do: :error

  defp clean_public_line(line) when is_binary(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        nil

      internal_value?(line) ->
        nil

      true ->
        line
        |> strip_safe_label()
        |> UserFacingCopy.polish_text()
        |> String.trim()
        |> case do
          "" -> nil
          value -> if internal_value?(value), do: nil, else: value
        end
    end
  end

  defp strip_safe_label(value) do
    Regex.replace(
      ~r/^\s*(?:source[_ ]context|context[_ ]brief|context|why[_ ]now|why[_ ]it[_ ]matters|next[_ ]best[_ ]action|next[_ ]action|decision[_ ]prompt|decision|evidence[_ ]excerpt|evidence|summary|source)\s*[:=-]\s*/i,
      value,
      ""
    )
  end

  # Values are human copy, so this must only catch machine artifacts —
  # JSON-shaped text, internal label lines, and unambiguous system tokens.
  # Substring-matching the key blocklist here vetoed normal business
  # language ("400-agent brokerage", "credit score", "20% discount").
  @internal_value_terms ~w(llm stacktrace source_backed source_health dedupe_key tracking_key)
  @internal_value_pattern ~r/(?<![\p{L}\p{N}_])(?:#{Enum.map_join(@internal_value_terms, "|", &Regex.escape/1)})(?![\p{L}\p{N}_])/iu

  @internal_label_pattern ~r/\b(?:confidence|score|reasoning|rationale|model|prompt|metadata|threshold|heuristic)\s*[:=]\s*\S/iu
  @internal_model_confidence_pattern ~r/\b(?:the\s+model|model\s+score)\b.*\b\d+\s*%/iu

  defp internal_value?(value) do
    normalized = String.downcase(value)

    Regex.match?(~r/^\s*[\{\[]\s*"/u, normalized) or
      Regex.match?(@internal_label_pattern, value) or
      Regex.match?(@internal_model_confidence_pattern, value) or
      Regex.match?(@internal_value_pattern, normalized)
  end
end
