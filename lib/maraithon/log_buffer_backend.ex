defmodule Maraithon.LogBufferBackend do
  @moduledoc """
  Logger backend that mirrors recent log entries into `Maraithon.LogBuffer`.
  """

  @behaviour :gen_event

  require Logger

  @default_level :debug

  def init(__MODULE__) do
    {:ok, %{level: configured_level([])}}
  end

  def init({__MODULE__, opts}) do
    {:ok, %{level: configured_level(opts)}}
  end

  def handle_call({:configure, opts}, state) do
    {:ok, :ok, %{state | level: configured_level(opts, state.level)}}
  end

  def handle_event({level, _group_leader, {Logger, message, timestamp, metadata}}, state) do
    level = normalize_level(level)
    configured_level = normalize_level(state.level)

    if Logger.compare_levels(level, configured_level) != :lt do
      Maraithon.LogBuffer.record(%{
        timestamp: to_iso8601(timestamp),
        level: level,
        message: format_message(message),
        metadata: metadata |> Enum.into(%{}) |> stringify_metadata()
      })
    end

    {:ok, state}
  end

  def handle_event(:flush, state), do: {:ok, state}
  def handle_event(_event, state), do: {:ok, state}

  def handle_info(_msg, state), do: {:ok, state}

  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  def terminate(_reason, _state), do: :ok

  defp configured_level(opts, fallback \\ @default_level) do
    case Keyword.get(opts, :level, fallback) do
      level
      when level in [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] ->
        level

      :warn ->
        :warning

      _ ->
        fallback
    end
  end

  defp format_message({format, args})
       when (is_binary(format) or is_list(format)) and is_list(args) do
    format
    |> :io_lib.format(args)
    |> IO.iodata_to_binary()
  rescue
    _ -> inspect({format, args}, pretty: false, limit: 20)
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message) when is_list(message), do: IO.iodata_to_binary(message)
  defp format_message(message), do: inspect(message, pretty: false, limit: 20)

  defp to_iso8601({date, {hour, minute, second, microsecond}}) do
    date
    |> NaiveDateTime.new!(Time.new!(hour, minute, second, microsecond * 1000))
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  rescue
    _ -> DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp to_iso8601({date, time}) do
    date
    |> NaiveDateTime.new!(Time.from_erl!(time))
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  rescue
    _ -> DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp to_iso8601(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp stringify_metadata(metadata) do
    Map.new(metadata, fn {key, value} ->
      {to_string(key), metadata_value(value)}
    end)
  end

  defp metadata_value(value) when is_binary(value), do: value
  defp metadata_value(value) when is_number(value), do: value
  defp metadata_value(value) when is_boolean(value), do: value
  defp metadata_value(nil), do: nil
  defp metadata_value(value), do: inspect(value, pretty: false, limit: 20)

  defp normalize_level(:warn), do: :warning
  defp normalize_level(level), do: level
end
