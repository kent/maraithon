defmodule Maraithon.LogFormatter do
  @moduledoc """
  JSON log formatter for Cloud Logging (GCP).
  Outputs structured logs that Cloud Logging can parse automatically.
  """

  def format(level, message, timestamp, metadata) do
    {date, {hour, minute, second, microsecond}} = timestamp

    iso_timestamp =
      NaiveDateTime.new!(
        Date.from_erl!(date),
        Time.new!(hour, minute, second, microsecond)
      )
      |> NaiveDateTime.to_iso8601()

    log_entry = %{
      severity: severity(level),
      message: IO.iodata_to_binary(message),
      timestamp: iso_timestamp,
      "logging.googleapis.com/labels": metadata_to_labels(metadata)
    }

    # Add optional fields if present
    log_entry =
      metadata
      |> Keyword.take([
        :request_id,
        :agent_id,
        :effect_id,
        :job_id,
        :error,
        :reason,
        :provider,
        :user_id,
        :status,
        :duration_ms
      ])
      |> Enum.reduce(log_entry, fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    [Jason.encode!(log_entry), "\n"]
  rescue
    _ ->
      # Fallback to simple format if JSON encoding fails
      "#{level} #{message}\n"
  end

  defp severity(:debug), do: "DEBUG"
  defp severity(:info), do: "INFO"
  defp severity(:warn), do: "WARNING"
  defp severity(:warning), do: "WARNING"
  defp severity(:error), do: "ERROR"
  defp severity(_), do: "DEFAULT"

  defp metadata_to_labels(metadata) do
    metadata
    |> Keyword.take([:module, :function, :line])
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
