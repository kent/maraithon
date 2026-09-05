defmodule Maraithon.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Maraithon.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Maraithon.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Maraithon.DataCase
    end
  end

  setup tags do
    Maraithon.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    opts = [shared: not tags[:async]]

    opts =
      case tags[:sandbox_isolation] do
        isolation when is_binary(isolation) -> Keyword.put(opts, :isolation, isolation)
        _ -> opts
      end

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Maraithon.Repo, opts)

    # Local-proof capabilities are sent only when PostgreSQL bind values cannot
    # enter statement or error logs. Reset any database-level default role so
    # the test session owner establishes the superuser-only logging policy,
    # then narrow back to the role requested by the test.
    Maraithon.Repo.query!("SET LOCAL ROLE NONE", [], log: false)
    Maraithon.Repo.query!("SET LOCAL log_parameter_max_length = 0", [], log: false)
    Maraithon.Repo.query!("SET LOCAL log_parameter_max_length_on_error = 0", [], log: false)

    unless tags[:database_role] == :session do
      Maraithon.Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    end

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc "Returns a complete explicit same-user Binding consent envelope for tests."
  def binding_consent(agent, overrides \\ %{}) when is_map(overrides) do
    %{
      "actor_id" => agent.user_id,
      "user_id" => agent.user_id,
      "identity_key" => "agent:#{agent.id}",
      "credential_refs" => %{},
      "connector_scope" => agent.connector_grants || %{},
      "memory_scope" => agent.memory_scope || %{},
      "tool_policy" => %{},
      "routing_bindings" => %{},
      "metadata" => %{"source" => "test_explicit_consent"}
    }
    |> Map.merge(Maraithon.Normalization.stringify_keys(overrides))
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
