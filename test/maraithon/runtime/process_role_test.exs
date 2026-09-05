defmodule Maraithon.Runtime.ProcessRoleTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Runtime
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.Config

  setup do
    previous_role = Application.get_env(:maraithon, :process_role)
    Application.put_env(:maraithon, :process_role, :web)

    on_exit(fn ->
      if is_nil(previous_role),
        do: Application.delete_env(:maraithon, :process_role),
        else: Application.put_env(:maraithon, :process_role, previous_role)
    end)

    :ok
  end

  test "web supervision keeps request support but excludes runtime ownership" do
    ids = child_ids(:web)

    assert Maraithon.Runtime.AgentRegistry in ids
    assert Maraithon.Runtime.EffectSupervisor in ids
    assert Maraithon.Runtime.ToolCallSupervisor in ids
    assert Maraithon.Runtime.Effects.LLMRateLimiter in ids
    assert MaraithonWeb.Endpoint in ids

    refute Maraithon.Runtime.AgentWatcher in ids
    refute Maraithon.Runtime.Supervisor in ids
    refute Maraithon.Todos.IngestionCoordinator in ids

    assert Maraithon.Application.children_for_role(:maintenance) == []
  end

  test "web readiness proves the durable protocol without claiming local runtime readiness" do
    assert Config.web_process?()
    refute Config.runtime_process?()
    assert Config.exact_agent_protocol_ready?()
    refute Config.exact_agent_runtime_ready?()
    refute Config.multinode_coordination_ready?()
  end

  test "web start persists runnable desired state without creating a lease or process" do
    email = "web-start-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(email)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: email,
        behavior: "prompt_agent",
        install_status: "enabled",
        status: "stopped",
        config: %{}
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))

    assert {:ok, started} = Runtime.start_existing_agent(agent.id)
    assert started.status == "running"
    assert Agents.get_agent(agent.id).status == "running"
    assert AgentLeases.get(agent.id) == nil
    assert Registry.lookup(Maraithon.Runtime.AgentRegistry, agent.id) == []
  end

  test "web lifecycle finalizes immediately when no runtime lease exists" do
    email = "web-stop-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(email)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: email,
        behavior: "prompt_agent",
        install_status: "enabled",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{}
      })

    assert {:ok, %{drain_status: :quiesced}} = Runtime.stop_agent(agent.id)
    assert Agents.get_agent(agent.id).status == "stopped"
  end

  test "web can prove a runtime-won lifecycle from its original token and durable postcondition" do
    email = "web-lifecycle-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(email)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: email,
        behavior: "prompt_agent",
        install_status: "enabled",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{"revision" => 1}
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))

    request = %{"params" => %{"config" => %{"revision" => 2}}}

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(agent.id, :update, request, fn locked ->
               %{
                 "action" => "update",
                 "attrs" => %{
                   "behavior" => locked.behavior,
                   "config" => %{"revision" => 2}
                 }
               }
             end)

    assert {:ok, %{status: :finalized}} =
             AgentLifecycleOperations.finalize_for_reconciliation(
               agent.id,
               fence.operation_token
             )

    assert AgentLifecycleOperations.get(agent.id) == nil

    assert {:ok, %{status: :finalized, resume_after: true, agent: recovered}} =
             AgentLifecycleOperations.confirm_finalized_postcondition(
               agent.id,
               fence.operation_token,
               fence.operation
             )

    assert recovered.config == %{"revision" => 2}

    {:ok, _changed} = Agents.update_agent(recovered, %{config: %{"revision" => 3}})

    assert {:error, :lifecycle_completion_unproven} =
             AgentLifecycleOperations.confirm_finalized_postcondition(
               agent.id,
               fence.operation_token,
               fence.operation
             )

    forged = %{fence.operation | operation_token: Ecto.UUID.generate()}

    assert {:error, :lifecycle_completion_unproven} =
             AgentLifecycleOperations.confirm_finalized_postcondition(
               agent.id,
               fence.operation_token,
               forged
             )
  end

  defp child_ids(role) do
    role
    |> Maraithon.Application.children_for_role()
    |> Enum.map(fn child -> Supervisor.child_spec(child, []).id end)
  end
end
