defmodule Maraithon.Tools.ActionHelpers do
  @moduledoc """
  Shared argument parsing helpers for outbound action tools.
  """

  def required_string(args, key, message \\ nil) when is_map(args) and is_binary(key) do
    value = Map.get(args, key)
    message = message || "#{key} is required"

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, message}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, message}
    end
  end

  def required_integer(args, key, message \\ nil) when is_map(args) and is_binary(key) do
    message = message || "#{key} is required"

    case Map.get(args, key) do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) -> parse_integer(value, message)
      _ -> {:error, message}
    end
  end

  def optional_string(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def optional_integer(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_optional_integer(value)
      _ -> nil
    end
  end

  def optional_csv(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      values when is_binary(values) ->
        values
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_integer(value, message) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, message}
    end
  end

  defp parse_optional_integer(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end
end
