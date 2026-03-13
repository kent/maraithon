defmodule Maraithon.AgentsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo

  @valid_attrs %{behavior: "prompt_agent", config: %{prompt: "test"}}

  setup do
    Repo.delete_all(Agent)
    :ok
  end

  describe "list_agents/0" do
    test "returns empty list when no agents" do
      assert Agents.list_agents() == []
    end

    test "returns all agents" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      agents = Agents.list_agents()

      assert length(agents) == 1
      assert hd(agents).id == agent.id
    end
  end

  describe "get_agent/1" do
    test "returns agent when exists" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)

      assert Agents.get_agent(agent.id).id == agent.id
    end

    test "returns nil when agent does not exist" do
      assert Agents.get_agent(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_agent!/1" do
    test "returns agent when exists" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)

      assert Agents.get_agent!(agent.id).id == agent.id
    end

    test "raises when agent does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_agent/1" do
    test "creates agent with valid attrs" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)

      assert agent.behavior == "prompt_agent"
      assert agent.config == %{prompt: "test"}
      assert agent.status == "stopped"
    end

    test "returns error with invalid behavior" do
      {:error, changeset} = Agents.create_agent(%{behavior: "nonexistent_behavior"})

      assert %{behavior: ["unknown behavior: nonexistent_behavior"]} = errors_on(changeset)
    end

    test "returns error when behavior is missing" do
      {:error, changeset} = Agents.create_agent(%{})

      assert %{behavior: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "update_agent/2" do
    test "updates agent with valid attrs" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:ok, updated} = Agents.update_agent(agent, %{status: "running"})

      assert updated.status == "running"
    end

    test "returns error with invalid status" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:error, changeset} = Agents.update_agent(agent, %{status: "invalid"})

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "delete_agent/1" do
    test "deletes agent" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:ok, _} = Agents.delete_agent(agent)

      assert Agents.get_agent(agent.id) == nil
    end
  end

  describe "count_by_status/1" do
    test "counts agents by status" do
      Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      Agents.create_agent(Map.put(@valid_attrs, :status, "stopped"))

      assert Agents.count_by_status("running") == 2
      assert Agents.count_by_status("stopped") == 1
      assert Agents.count_by_status("degraded") == 0
    end
  end

  describe "list_resumable_agents/0" do
    test "returns agents with running or degraded status" do
      {:ok, running} = Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      {:ok, degraded} = Agents.create_agent(Map.put(@valid_attrs, :status, "degraded"))
      Agents.create_agent(Map.put(@valid_attrs, :status, "stopped"))

      resumable = Agents.list_resumable_agents()
      ids = Enum.map(resumable, & &1.id)

      assert length(resumable) == 2
      assert running.id in ids
      assert degraded.id in ids
    end
  end

  describe "mark_running/1" do
    test "updates status to running and sets started_at" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:ok, running} = Agents.mark_running(agent)

      assert running.status == "running"
      assert running.started_at != nil
    end
  end

  describe "mark_stopped/1" do
    test "updates status to stopped and sets stopped_at" do
      {:ok, agent} = Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      {:ok, stopped} = Agents.mark_stopped(agent)

      assert stopped.status == "stopped"
      assert stopped.stopped_at != nil
    end
  end

  describe "mark_degraded/1" do
    test "updates status to degraded" do
      {:ok, agent} = Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      {:ok, degraded} = Agents.mark_degraded(agent)

      assert degraded.status == "degraded"
    end
  end
end
