defmodule MaraithonWeb.RuntimeControllerTest do
  use MaraithonWeb.ConnCase, async: false

  test "status identifies the runtime role and deployment generation", %{conn: conn} do
    previous_role = Application.get_env(:maraithon, :process_role)
    previous_auth = Application.get_env(:maraithon, :api_auth)

    Application.put_env(:maraithon, :process_role, :runtime)
    Application.put_env(:maraithon, :api_auth, bearer_token: "")

    on_exit(fn ->
      restore_env(:process_role, previous_role)
      restore_env(:api_auth, previous_auth)
    end)

    response = conn |> get("/api/v1/runtime/status") |> json_response(200)

    assert response["process_role"] == "runtime"

    assert response["deployment_generation"] ==
             Maraithon.Runtime.Coordination.Authority.deployment_generation()

    assert Map.has_key?(response, "deployment_gate")
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)
end
