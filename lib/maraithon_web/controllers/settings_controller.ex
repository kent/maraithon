defmodule MaraithonWeb.SettingsController do
  use MaraithonWeb, :controller

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Settings",
      current_path: ~p"/settings",
      current_user: conn.assigns.current_user,
      runtime_items: runtime_items(),
      security_items: security_items(),
      oauth_items: oauth_items()
    )
  end

  defp runtime_items do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    llm_provider = runtime |> Keyword.get(:llm_provider) |> inspect()

    [
      %{name: "Endpoint URL", value: MaraithonWeb.Endpoint.url()},
      %{name: "LLM provider module", value: llm_provider},
      %{name: "Anthropic model", value: Keyword.get(runtime, :anthropic_model, "not set")},
      %{name: "Tool timeout (ms)", value: to_string(Keyword.get(runtime, :tool_timeout_ms, 0))},
      %{
        name: "Heartbeat interval (ms)",
        value: to_string(Keyword.get(runtime, :heartbeat_interval_ms, 0))
      }
    ]
  end

  defp security_items do
    admin_auth = Application.get_env(:maraithon, :admin_auth, [])
    api_auth = Application.get_env(:maraithon, :api_auth, [])

    [
      %{
        name: "PRIMARY_ADMIN_EMAIL",
        required?: true,
        present?: present?(System.get_env("PRIMARY_ADMIN_EMAIL", ""))
      },
      %{
        name: "POSTMARK_SERVER_TOKEN",
        required?: true,
        present?: present?(System.get_env("POSTMARK_SERVER_TOKEN", ""))
      },
      %{
        name: "AUTH_EMAIL_FROM",
        required?: true,
        present?: present?(System.get_env("AUTH_EMAIL_FROM", ""))
      },
      %{
        name: "API_BEARER_TOKEN",
        required?: true,
        present?: present?(Keyword.get(api_auth, :bearer_token))
      },
      %{
        name: "ADMIN_USERNAME (fallback)",
        required?: false,
        present?: present?(Keyword.get(admin_auth, :username))
      },
      %{
        name: "ADMIN_PASSWORD (fallback)",
        required?: false,
        present?: present?(Keyword.get(admin_auth, :password))
      },
      %{
        name: "CLOAK_KEY",
        required?: true,
        present?: present?(Application.get_env(:maraithon, Maraithon.Vault)[:ciphers])
      }
    ]
  end

  defp oauth_items do
    [
      oauth_item(
        "Google",
        Application.get_env(:maraithon, :google, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "GitHub",
        Application.get_env(:maraithon, :github, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "Linear",
        Application.get_env(:maraithon, :linear, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "Notion",
        Application.get_env(:maraithon, :notion, []),
        :client_id,
        :client_secret
      )
    ]
  end

  defp oauth_item(name, config, client_key, secret_key) do
    %{
      name: name,
      client_id_present?: present?(Keyword.get(config, client_key)),
      client_secret_present?: present?(Keyword.get(config, secret_key)),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value), do: not is_nil(value)
end
