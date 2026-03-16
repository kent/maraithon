defmodule Maraithon.TestSupport.TravelCalendarStub do
  @moduledoc false

  def configure(opts) when is_list(opts) do
    Application.put_env(:maraithon, __MODULE__, opts)
  end

  def list_events(_user_id, _opts \\ []) do
    {:ok, config(:events, [])}
  end

  defp config(key, default) do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
