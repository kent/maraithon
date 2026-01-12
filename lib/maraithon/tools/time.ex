defmodule Maraithon.Tools.Time do
  @moduledoc """
  Simple tool that returns current time.
  """

  def execute(_args) do
    {:ok,
     %{
       utc: DateTime.utc_now() |> DateTime.to_iso8601(),
       unix: System.system_time(:second)
     }}
  end
end
