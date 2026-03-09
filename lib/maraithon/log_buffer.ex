defmodule Maraithon.LogBuffer do
  @moduledoc """
  Bounded in-memory buffer of recent application logs for admin inspection.
  """

  use GenServer

  @default_max_entries 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record(entry) when is_map(entry) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:record, normalize_entry(entry)})
    else
      :ok
    end
  end

  def recent(limit \\ 100) when is_integer(limit) and limit > 0 do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:recent, limit})
    else
      []
    end
  end

  def clear do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :clear)
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:maraithon, __MODULE__, [])

    max_entries =
      Keyword.get(opts, :max_entries, Keyword.get(config, :max_entries, @default_max_entries))

    {:ok, %{entries: :queue.new(), max_entries: max_entries}}
  end

  @impl true
  def handle_cast({:record, entry}, state) do
    entries =
      :queue.in(entry, state.entries)
      |> trim_to_limit(state.max_entries)

    {:noreply, %{state | entries: entries}}
  end

  @impl true
  def handle_call({:recent, limit}, _from, state) do
    entries =
      state.entries
      |> :queue.to_list()
      |> Enum.take(-limit)
      |> Enum.reverse()

    {:reply, entries, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: :queue.new()}}
  end

  defp trim_to_limit(entries, max_entries) do
    if :queue.len(entries) > max_entries do
      {_dropped, trimmed} = :queue.out(entries)
      trim_to_limit(trimmed, max_entries)
    else
      entries
    end
  end

  defp normalize_entry(entry) do
    %{
      timestamp:
        Map.get(entry, :timestamp) || Map.get(entry, "timestamp") ||
          DateTime.utc_now() |> DateTime.to_iso8601(),
      level: Map.get(entry, :level) || Map.get(entry, "level") || :info,
      message: Map.get(entry, :message) || Map.get(entry, "message") || "",
      metadata:
        entry
        |> Map.get(:metadata, Map.get(entry, "metadata", %{}))
        |> normalize_metadata()
    }
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_metadata(_), do: %{}
end
