defmodule Maraithon.Runtime.DbResilience do
  @moduledoc false

  require Logger

  @max_backoff_ms 60_000

  def with_database(operation, fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    exception in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      log_database_failure(operation, exception)
      {:error, exception}
  catch
    kind, reason ->
      case find_database_exception(reason) do
        nil ->
          :erlang.raise(kind, reason, __STACKTRACE__)

        exception ->
          log_database_failure(operation, exception)
          {:error, exception}
      end
  end

  def backoff_ms(base_ms, attempt, max_ms \\ @max_backoff_ms)
      when is_integer(base_ms) and base_ms > 0 and is_integer(attempt) and attempt >= 0 do
    multiplier = :math.pow(2, attempt) |> round()
    min(base_ms * multiplier, max_ms)
  end

  defp log_database_failure(operation, exception) do
    Logger.warning("#{operation} deferred because database access failed",
      operation: operation,
      error: Exception.message(exception)
    )
  end

  defp find_database_exception(%DBConnection.ConnectionError{} = exception), do: exception
  defp find_database_exception(%DBConnection.OwnershipError{} = exception), do: exception
  defp find_database_exception(%Postgrex.Error{} = exception), do: exception

  defp find_database_exception(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.find_value(&find_database_exception/1)
  end

  defp find_database_exception(reason) when is_list(reason) do
    Enum.find_value(reason, &find_database_exception/1)
  end

  defp find_database_exception(reason) when is_map(reason) do
    reason
    |> Map.values()
    |> Enum.find_value(&find_database_exception/1)
  end

  defp find_database_exception(_reason), do: nil
end
