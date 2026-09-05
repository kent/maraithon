defmodule Maraithon.Release do
  @moduledoc """
  Release tasks for running migrations.
  """

  @app :maraithon

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Runs pending migrations only through an exact version boundary."
  def migrate_to(version) when is_integer(version) and version > 0 do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, to: version))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def validate_authorized_todo_launch do
    target = System.get_env("TODO_VALIDATION_USER", "")

    if target != "kent@runner.now" do
      raise "TODO_VALIDATION_USER is not the authorized launch account"
    end

    load_app()
    {:ok, _apps} = Application.ensure_all_started(:req)
    {:ok, vault} = Maraithon.Vault.start_link([])

    {:ok, tool_call_supervisor} =
      Task.Supervisor.start_link(name: Maraithon.Runtime.ToolCallSupervisor)

    try do
      for repo <- repos() do
        {:ok, result, _apps} =
          Ecto.Migrator.with_repo(repo, fn _repo ->
            case Maraithon.Todos.ProductionValidator.run(target) do
              {:ok, report} -> report
              {:error, reason} -> raise "Todo launch validation failed: #{reason}"
            end
          end)

        IO.puts("TODO_LAUNCH_VALIDATION=" <> Jason.encode!(result))
      end
    after
      Supervisor.stop(tool_call_supervisor)
      GenServer.stop(vault)
    end
  end

  def replay_authorized_gmail_source_window do
    target = System.get_env("GMAIL_REPLAY_USER", "")
    lower = parse_integer_env("GMAIL_REPLAY_LOWER")
    upper = parse_integer_env("GMAIL_REPLAY_UPPER")
    expected_account_count = parse_integer_env("GMAIL_REPLAY_EXPECTED_ACCOUNT_COUNT")

    if target != "kent@runner.now" do
      raise "GMAIL_REPLAY_USER is not the authorized replay account"
    end

    load_app()
    {:ok, _apps} = Application.ensure_all_started(:req)
    {:ok, vault} = Maraithon.Vault.start_link([])

    {:ok, tool_call_supervisor} =
      Task.Supervisor.start_link(name: Maraithon.Runtime.ToolCallSupervisor)

    try do
      for repo <- repos() do
        {:ok, result, _apps} =
          Ecto.Migrator.with_repo(repo, fn _repo ->
            case Maraithon.Runtime.GmailSourceReplayAudit.run(
                   target,
                   lower,
                   upper,
                   expected_account_count
                 ) do
              {:ok, report} ->
                report

              {:error, reason} ->
                code = Maraithon.Runtime.GmailSourceReplayAudit.error_code(reason)
                IO.puts("GMAIL_SOURCE_REPLAY_AUDIT_ERROR=" <> code)
                raise "Gmail source replay audit failed"
            end
          end)

        IO.puts("GMAIL_SOURCE_REPLAY_AUDIT=" <> Jason.encode!(result))
      end
    after
      Supervisor.stop(tool_call_supervisor)
      GenServer.stop(vault)
    end
  end

  def replay_authorized_slack_source_window do
    target = System.get_env("SLACK_REPLAY_USER", "")
    lower = parse_integer_env("SLACK_REPLAY_LOWER")
    upper = parse_integer_env("SLACK_REPLAY_UPPER")

    if target != "kent@runner.now" do
      raise "SLACK_REPLAY_USER is not the authorized replay account"
    end

    load_app()
    {:ok, _apps} = Application.ensure_all_started(:req)
    {:ok, vault} = Maraithon.Vault.start_link([])

    {:ok, tool_call_supervisor} =
      Task.Supervisor.start_link(name: Maraithon.Runtime.ToolCallSupervisor)

    try do
      for repo <- repos() do
        {:ok, result, _apps} =
          Ecto.Migrator.with_repo(repo, fn _repo ->
            case Maraithon.Runtime.SlackSourceReplayAudit.run(target, lower, upper) do
              {:ok, report} ->
                report

              {:error, reason} ->
                code = Maraithon.Runtime.SlackSourceReplayAudit.error_code(reason)
                IO.puts("SLACK_SOURCE_REPLAY_AUDIT_ERROR=" <> code)
                raise "Slack source replay audit failed"
            end
          end)

        IO.puts("SLACK_SOURCE_REPLAY_AUDIT=" <> Jason.encode!(result))
      end
    after
      Supervisor.stop(tool_call_supervisor)
      GenServer.stop(vault)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp parse_integer_env(name) do
    case name |> System.get_env("") |> Integer.parse() do
      {value, ""} when value >= 0 -> value
      _invalid -> raise "#{name} must be a nonnegative integer"
    end
  end
end
