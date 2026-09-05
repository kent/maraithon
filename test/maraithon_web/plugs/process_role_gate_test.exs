defmodule MaraithonWeb.Plugs.ProcessRoleGateTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias MaraithonWeb.Plugs.ProcessRoleGate

  setup do
    previous = Application.get_env(:maraithon, :process_role, :combined)

    on_exit(fn -> Application.put_env(:maraithon, :process_role, previous) end)
  end

  test "web processes keep the public surface" do
    Application.put_env(:maraithon, :process_role, :web)

    conn = call(:get, "/todos")

    refute conn.halted
    assert call(:get, "/api/v1/runtime/status").halted
    assert call(:post, "/api/v1/runtime/drain").halted
    assert call(:post, "/api/v1/runtime/rejoin").halted
  end

  test "runtime processes expose only health and exact control requests" do
    Application.put_env(:maraithon, :process_role, :runtime)

    refute call(:get, "/health").halted
    refute call(:head, "/health/").halted
    refute call(:get, "/api/v1/runtime/status").halted
    refute call(:post, "/api/v1/runtime/drain").halted
    refute call(:post, "/api/v1/runtime/rejoin").halted

    assert call(:get, "/todos").halted
    assert call(:post, "/api/v1/agents").halted
    assert call(:get, "/api/v1/runtime/drain").halted
  end

  test "maintenance processes expose no HTTP surface" do
    Application.put_env(:maraithon, :process_role, :maintenance)

    assert call(:get, "/health").halted
  end

  defp call(method, path) do
    method
    |> conn(path)
    |> ProcessRoleGate.call(ProcessRoleGate.init([]))
  end
end
