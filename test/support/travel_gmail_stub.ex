defmodule Maraithon.TestSupport.TravelGmailStub do
  @moduledoc false

  def configure(opts) when is_list(opts) do
    Application.put_env(:maraithon, __MODULE__, opts)
  end

  def fetch_messages(_user_id, _opts \\ []) do
    {:ok, config(:messages, [])}
  end

  def fetch_message_content(_user_id, message_id) when is_binary(message_id) do
    case config(:contents, %{}) do
      %{^message_id => content} -> {:ok, content}
      _ -> {:error, :not_found}
    end
  end

  defp config(key, default) do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
