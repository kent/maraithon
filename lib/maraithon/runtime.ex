defmodule Maraithon.Runtime do
  @moduledoc """
  Runtime facade for managing agents.
  Provides the main API for starting, stopping, and interacting with agents.
  """

  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Events
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.IncidentLog
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.WakeCoordinator

  require Logger

  @web_lifecycle_finalize_wait_ms 30_000
  @web_lifecycle_finalize_poll_ms 500

  @doc """
  Enqueue durable app-level background work.

  Use this for non-interactive processing such as email scans, relationship
  learning, open-loop refreshes, and other long-running user-scoped work.
  """
  def enqueue_background_job(job_type, attrs \\ %{}) when is_binary(job_type) do
    BackgroundJobs.enqueue(job_type, attrs)
  end

  def enqueue_email_processing(user_id, attrs \\ %{}) when is_binary(user_id) do
    BackgroundJobs.enqueue_email_processing(user_id, attrs)
  end

  def enqueue_relationship_learning(user_id, observations, attrs \\ [])
      when is_binary(user_id) and is_list(observations) do
    BackgroundJobs.enqueue_relationship_learning(user_id, observations, attrs)
  end

  def enqueue_open_loop_check(user_id, attrs \\ %{}) when is_binary(user_id) do
    BackgroundJobs.enqueue_open_loop_check(user_id, attrs)
  end

  @doc """
  Start a new agent with the given parameters.
  """
  def start_agent(params) when is_map(params) do
    user_id = params["user_id"] || params[:user_id]
    binding_consent = params["binding_consent"] || params[:binding_consent]

    attrs = %{
      user_id: user_id,
      project_id: normalize_optional_string(params["project_id"] || params[:project_id]),
      behavior: params["behavior"] || params[:behavior],
      config: params["config"] || params[:config] || %{},
      status: "running",
      started_at: DateTime.utc_now(),
      install_status: "enabled",
      installed_at: params["installed_at"] || params[:installed_at] || DateTime.utc_now(),
      agent_package_id: params["agent_package_id"] || params[:agent_package_id],
      agent_package_version_id:
        params["agent_package_version_id"] || params[:agent_package_version_id],
      connector_grants: params["connector_grants"] || params[:connector_grants] || %{},
      schedule_policy: params["schedule_policy"] || params[:schedule_policy] || %{},
      delivery_policy: params["delivery_policy"] || params[:delivery_policy] || %{},
      memory_scope: params["memory_scope"] || params[:memory_scope] || %{}
    }

    attrs =
      if budget = params["budget"] || params[:budget] do
        put_in(attrs, [:config, "budget"], budget)
      else
        put_in(attrs, [:config, "budget"], default_budget())
      end

    with :ok <- exact_runtime_request_ready(),
         :ok <- local_start_preflight(),
         :ok <- AgentIsolation.validate_binding_consent_input(user_id, binding_consent),
         {:ok, agent} <- create_consented_running_agent(attrs, binding_consent),
         {:ok, _pid_or_status} <- start_or_enqueue_with_failure_fence(agent) do
      Logger.info("Accepted agent start #{agent.id}",
        agent_id: agent.id,
        behavior: agent.behavior
      )

      {:ok, agent}
    else
      {:error, reason} = error ->
        Logger.error("Failed to start agent: #{inspect(reason)}")
        error
    end
  end

  def start_agent(_params), do: {:error, :invalid_agent_start}

  @doc """
  Install the latest package version for a user and start its runtime process.
  """
  def install_agent_package(user_id, package_slug, opts \\ [])
      when is_binary(user_id) and is_binary(package_slug) and is_list(opts) do
    consent = Keyword.get(opts, :binding_consent)

    result =
      if is_map(consent) do
        with :ok <- exact_runtime_request_ready(),
             :ok <- local_start_preflight(),
             :ok <- AgentIsolation.validate_binding_consent_input(user_id, consent),
             {:ok, agent} <-
               install_consented_package(user_id, package_slug, opts, consent) do
          with {:ok, _pid_or_status} <- maybe_start_installed_agent(agent) do
            {:ok, agent}
          end
        end
      else
        # Deliberately ignore caller-supplied runnable statuses. The Agents
        # context persists a stopped/setup-required installation.
        Agents.install_agent_package(user_id, package_slug, opts)
      end

    case result do
      {:ok, agent} ->
        Logger.info("Installed package agent #{agent.id}",
          agent_id: agent.id,
          package_slug: package_slug,
          behavior: agent.behavior,
          install_status: agent.install_status
        )

        {:ok, agent}

      {:error, reason} = error ->
        Logger.error("Failed to install package #{package_slug}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Installs the Chief of Staff package and starts it only when setup is complete.
  """
  def install_chief_of_staff(user_id, opts \\ [])
      when is_binary(user_id) and is_list(opts) do
    consent = Keyword.get(opts, :binding_consent)

    if is_map(consent) do
      with :ok <- exact_runtime_request_ready(),
           :ok <- local_start_preflight(),
           :ok <- AgentIsolation.validate_binding_consent_input(user_id, consent),
           {:ok, agent} <- install_consented_chief(user_id, opts, consent),
           {:ok, _pid_or_status} <- maybe_start_installed_agent(agent) do
        {:ok, agent}
      end
    else
      Agents.install_chief_of_staff(user_id, opts)
    end
  end

  @doc """
  Start an existing persisted agent by ID.
  """
  def start_existing_agent(id) when is_binary(id) do
    with :ok <- exact_runtime_request_ready(),
         :ok <- local_start_preflight() do
      with_agent_lifecycle_lock(id, fn -> do_start_existing_agent(id) end)
    end
  end

  defp do_start_existing_agent(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["running", "degraded"] ->
        {:error, :already_running}

      %{status: "recovering"} ->
        {:error, :agent_recovering}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      %{install_status: "paused"} ->
        {:error, :agent_paused}

      %{install_status: "setup_required"} ->
        {:error, :agent_setup_required}

      agent ->
        with :ok <- prepare_explicit_agent_start(agent.id),
             {:ok, updated_agent} <- Agents.claim_agent_start(agent.id) do
          case start_or_enqueue_agent_process(updated_agent) do
            {:ok, _pid_or_status} ->
              Logger.info("Accepted existing agent start #{id}",
                agent_id: id,
                behavior: updated_agent.behavior
              )

              {:ok, updated_agent}

            {:error, reason} = error ->
              # `running` is desired state, not process liveness. An ambiguous
              # spawn may already have crossed init, and an owned remote
              # incarnation is also a successful durable intent. Never roll
              # desired state back based on a launcher return classification.
              Logger.error("Failed to start existing agent #{id}: #{inspect(reason)}",
                agent_id: id
              )

              error
          end
        else
          {:error, reason} = error ->
            Logger.error("Failed to prepare or claim agent start #{id}: #{inspect(reason)}",
              agent_id: id
            )

            error
        end
    end
  end

  # Automatic recovery must remain fenced after the durable crash-loop guard
  # trips. An explicit operator start is different: it is the audited human
  # decision to retry after the failed generation has no lease or processing
  # directive. Reset through the existing exact-protocol helper before claiming
  # a fresh owner generation.
  defp prepare_explicit_agent_start(agent_id) do
    case AgentRestartGuards.get(agent_id) do
      %{tripped: true} -> reset_restart_guard_for_operator(agent_id)
      %{needs_recovery: true} -> reset_restart_guard_for_operator(agent_id)
      _clean_or_missing -> :ok
    end
  end

  defp reset_restart_guard_for_operator(agent_id) do
    case AgentRestartGuards.reset_for_operator(agent_id) do
      {:ok, _guard} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Stop an agent by ID.
  """
  def stop_agent(id, reason \\ "manual_stop")

  def stop_agent(id, reason) when is_binary(id) do
    request = %{"reason" => lifecycle_reason(reason, "manual_stop")}

    case execute_lifecycle(id, :stop, request, fn _agent -> %{"action" => "stop"} end) do
      {:ok, %{status: :finalized, agent: agent}} ->
        Logger.info("Finalized Agent stop", agent_id: id, status: "stopped")
        {:ok, %{stopped_at: agent.stopped_at, drain_status: :quiesced}}

      {:ok, %{status: :reconciliation_pending, agent: agent}} ->
        {:ok, %{stopped_at: agent.stopped_at, drain_status: :reconciliation_pending}}

      {:error, _reason} = error ->
        error
    end
  end

  def stop_agent(_id, _reason), do: {:error, :invalid_agent_id}

  @doc """
  Update an existing agent definition. Running agents are stopped, updated, and restarted.
  """
  def update_agent(id, params) when is_binary(id) and is_map(params) do
    request = %{"params" => params}

    planner = fn agent ->
      with {:ok, attrs} <- planned_agent_update(agent, params) do
        %{"action" => "update", "attrs" => attrs}
      end
    end

    with {:ok, result} <- execute_lifecycle(id, :update, request, planner),
         {:ok, agent} <- require_finalized_agent(result),
         {:ok, final_agent} <- maybe_start_finalized_agent(agent, result.resume_after) do
      Logger.info("Updated agent #{id}", agent_id: id, behavior: final_agent.behavior)
      {:ok, final_agent}
    end
  end

  def update_agent(_id, _params), do: {:error, :invalid_agent_update}

  @doc """
  Delete an agent and all dependent runtime records.
  """
  def delete_agent(id, opts \\ [])

  def delete_agent(id, opts) when is_binary(id) and is_list(opts) do
    request = %{"delete" => true}

    with {:ok, result} <-
           execute_lifecycle(
             id,
             :delete,
             request,
             fn _agent -> %{"action" => "delete"} end,
             opts
           ),
         :ok <- require_finalized_delete(result) do
      Logger.info("Deleted agent",
        agent_reference: Maraithon.Redaction.fingerprint(id),
        status: "deleted"
      )

      :ok
    end
  end

  def delete_agent(_id, _opts), do: {:error, :invalid_agent_delete}

  @doc """
  Soft-remove an installed agent from the user's marketplace workspace.
  """
  def remove_agent_installation(id) when is_binary(id) do
    request = %{"remove" => true}

    with {:ok, result} <-
           execute_lifecycle(id, :remove, request, fn _agent -> %{"action" => "remove"} end),
         {:ok, _agent} <- require_finalized_agent(result) do
      :ok
    end
  end

  @doc """
  Pause an installed marketplace agent and cancel all scheduled work.
  """
  def pause_agent_installation(id) when is_binary(id) do
    request = %{"pause" => true}

    with {:ok, result} <-
           execute_lifecycle(id, :pause, request, fn
             %Agent{install_status: "removed"} -> {:error, :agent_removed}
             _agent -> %{"action" => "pause"}
           end),
         {:ok, agent} <- require_finalized_agent(result) do
      {:ok, agent}
    end
  end

  @doc """
  Resume a paused installed marketplace agent and start its runtime process.
  """
  def resume_agent_installation(id, binding_consent \\ nil)

  def resume_agent_installation(id, binding_consent)
      when is_binary(id) and is_map(binding_consent) do
    with :ok <- exact_runtime_request_ready(),
         :ok <- local_start_preflight(),
         %Agent{} = agent <- Agents.get_agent(id, include_removed: true),
         true <- agent.install_status != "removed" || {:error, :agent_removed},
         :ok <- AgentIsolation.validate_binding_consent_input(agent.user_id, binding_consent),
         {:ok, enabled_agent} <- consent_and_enable_agent(agent, binding_consent),
         {:ok, _pid_or_status} <- start_or_enqueue_with_failure_fence(enabled_agent) do
      {:ok, enabled_agent}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
      true -> {:error, :agent_removed}
    end
  end

  def resume_agent_installation(id, nil) when is_binary(id),
    do: {:error, :binding_consent_required}

  def resume_agent_installation(_id, _binding_consent),
    do: {:error, :binding_consent_required}

  @doc """
  Upgrade an installed marketplace agent to a newer package version.
  """
  def upgrade_agent_installation(id, version_id \\ :latest) when is_binary(id) do
    request = %{"version_id" => if(version_id == :latest, do: "latest", else: version_id)}

    planner = fn
      %Agent{install_status: "removed"} ->
        {:error, :agent_removed}

      agent ->
        with {:ok, version} <- resolve_upgrade_version(agent, version_id),
             true <-
               version.agent_package_id == agent.agent_package_id || {:error, :package_mismatch} do
          config = (agent.config || %{}) |> Map.put("agent_package_version_id", version.id)

          %{
            "action" => "upgrade",
            "attrs" => %{
              "behavior" => version.behavior,
              "agent_package_version_id" => version.id,
              "config" => config
            }
          }
        end
    end

    with {:ok, result} <- execute_lifecycle(id, :upgrade, request, planner),
         {:ok, agent} <- require_finalized_agent(result),
         {:ok, final_agent} <- maybe_start_finalized_agent(agent, result.resume_after) do
      {:ok, final_agent}
    end
  end

  @doc """
  Get detailed status of an agent.
  """
  def get_agent_status(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        status = build_status(agent)
        {:ok, status}
    end
  end

  @doc """
  Send a message to an agent.
  """
  def send_message(id, message, metadata \\ %{}) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{status: status} = agent when status in ["running", "degraded"] ->
        if RuntimeConfig.exact_agent_runtime_enabled?() do
          enqueue_message_directive(agent, message, metadata)
        else
          message_id = Ecto.UUID.generate()
          :ok = Dispatch.dispatch(id, {:message, message, metadata, message_id})
          {:ok, %{message_id: message_id}}
        end

      _agent ->
        {:error, :agent_stopped}
    end
  end

  defp enqueue_message_directive(agent, message, metadata) do
    with {:ok, message_id} <- durable_message_id(metadata),
         {:ok, payload} <- durable_message_payload(message, metadata, message_id),
         {:ok, directive} <-
           AgentDirectives.enqueue(
             agent.id,
             agent.user_id,
             "message",
             payload,
             "message:#{message_id}"
           ) do
      {:ok, %{message_id: message_id, directive_id: directive.id}}
    end
  end

  @doc """
  Send a message to a running agent and wait briefly for a correlated response.
  """
  def request_response(id, message, metadata \\ %{}, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 12_000)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 250)
    correlation_id = correlation_id(metadata)
    after_seq = Events.latest_sequence_num(id)
    enriched_metadata = put_correlation_id(metadata, correlation_id)

    with {:ok, %{message_id: message_id}} <- send_message(id, message, enriched_metadata) do
      wait_for_agent_response(
        id,
        correlation_id,
        message_id,
        after_seq,
        timeout_ms,
        poll_interval_ms
      )
    end
  end

  @doc """
  Get events for an agent.
  """
  def get_events(id, opts \\ []) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      _agent ->
        events = Events.list_events(id, opts)
        {:ok, events}
    end
  end

  @doc """
  Resume all agents that were running before a restart.
  Called during application startup.
  """
  def resume_all_agents do
    with :ok <- exact_runtime_enabled() do
      agents = AgentLeases.list_bootstrap_agents()
      Logger.info("Resuming #{length(agents)} agents")

      case start_resumable_agents(agents) do
        {:ok, _pids} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp start_resumable_agents(agents) do
    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, pids} ->
      case with_agent_lifecycle_lock(agent.id, fn ->
             start_resumable_agent(agent.id,
               resume_trigger: "node_boot",
               admission: :bootstrap
             )
           end) do
        {:ok, pid} when is_pid(pid) ->
          Logger.info("Resumed agent #{agent.id}", agent_id: agent.id)
          {:cont, {:ok, [pid | pids]}}

        {:error, reason}
        when reason in [
               :runtime_lease_owned,
               :partition_not_owned,
               :partition_authority_lost,
               :agent_restart_backoff,
               :agent_lifecycle_busy,
               :agent_binding_not_active,
               :agent_not_resumable,
               :agent_not_runnable,
               :agent_restart_tripped
             ] ->
          # Another exact node owns it, its durable guard is not due, or
          # desired-state/Binding consent makes it intentionally non-resident.
          # No one legacy row may hold global effect admission closed.
          Logger.info("Deferred exact Agent resume", agent_id: agent.id, reason: inspect(reason))
          {:cont, {:ok, pids}}

        {:error, reason} ->
          Logger.error("Failed to resume agent #{agent.id}: #{inspect(reason)}",
            agent_id: agent.id
          )

          {:halt, {:error, :agent_recovery_incomplete}}
      end
    end)
  end

  @doc false
  def resume_finalized_lifecycle(id, opts \\ [])

  def resume_finalized_lifecycle(id, opts) when is_binary(id) and is_list(opts) do
    admission = Keyword.get(opts, :admission, :normal)

    with true <- admission in [:normal, :bootstrap, :recovery] || {:error, :invalid_agent_start},
         :ok <- exact_runtime_enabled(),
         %Agent{status: status, install_status: "enabled"} = agent <-
           Agents.get_agent(id, include_removed: true),
         true <- status in ["running", "degraded"] || {:error, :agent_not_resumable} do
      case start_with_failure_fence(agent, admission: admission) do
        {:error, :runtime_lease_owned} -> {:ok, :already_owned}
        result -> result
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
      _inactive -> {:error, :agent_not_resumable}
    end
  end

  def resume_finalized_lifecycle(_id, _opts), do: {:error, :invalid_agent_start}

  @doc """
  Resume a persisted agent after AgentWatcher detects an abnormal process exit.
  """
  def resume_agent_after_crash(id, metadata \\ %{}) when is_binary(id) and is_map(metadata) do
    case AgentRestartGuards.get(id) do
      %{generation: generation, needs_recovery: true, tripped: false} ->
        resume_agent_after_crash(id, generation, metadata)

      _missing_or_stale ->
        {:error, :stale_recovery_generation}
    end
  end

  def resume_agent_after_crash(id, guard_generation, metadata)
      when is_binary(id) and is_binary(guard_generation) and is_map(metadata) do
    with_agent_lifecycle_lock(id, fn ->
      start_resumable_agent(id,
        resume_trigger: "targeted_reresume",
        admission: :recovery,
        recovery_generation: guard_generation,
        metadata: metadata
      )
    end)
  end

  # Private functions

  defp with_agent_lifecycle_lock(id, fun) when is_binary(id) and is_function(fun, 0) do
    # The database row/lease transactions serialize lifecycle authority. A
    # distributed Erlang lock is neither complete (unconnected nodes) nor
    # durable, so it must not gate exact ownership.
    if byte_size(id) in 1..255 and String.valid?(id) do
      fun.()
    else
      {:error, :invalid_agent_id}
    end
  catch
    :exit, _reason -> {:error, :agent_lifecycle_unavailable}
  end

  defp start_resumable_agent(id, opts) do
    case Agents.get_agent(id, include_removed: true) do
      %{status: status, install_status: "enabled"} = agent
      when status in ["running", "degraded"] ->
        start_agent_process(agent, opts)

      nil ->
        {:error, :not_found}

      _inactive_agent ->
        {:error, :agent_not_resumable}
    end
  end

  defp put_recorded_recovery_generation(agent_id, opts) do
    if Keyword.has_key?(opts, :recovery_generation) do
      opts
    else
      case AgentRestartGuards.get(agent_id) do
        %{generation: generation, needs_recovery: true, tripped: false} ->
          Keyword.put(opts, :recovery_generation, generation)

        _no_due_recovery ->
          opts
      end
    end
  end

  defp create_consented_running_agent(attrs, consent) do
    Repo.transaction(fn ->
      now = DatabaseClock.now!()
      attrs = Map.merge(attrs, %{status: "running", install_status: "enabled", started_at: now})

      with {:ok, agent} <- Agents.create_agent(attrs),
           {:ok, _binding} <- AgentIsolation.grant_binding_consent(agent, consent) do
        agent
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp install_consented_package(user_id, package_slug, opts, consent) do
    Repo.transaction(fn ->
      with {:ok, agent} <-
             Agents.install_agent_package(
               user_id,
               package_slug,
               Keyword.delete(opts, :binding_consent)
             ),
           {:ok, _binding} <- AgentIsolation.grant_binding_consent(agent, consent),
           {:ok, enabled} <- enable_consented_installation(agent) do
        enabled
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp install_consented_chief(user_id, opts, consent) do
    Repo.transaction(fn ->
      with {:ok, agent} <-
             Agents.install_chief_of_staff(user_id, Keyword.delete(opts, :binding_consent)),
           {:ok, _binding} <- AgentIsolation.grant_binding_consent(agent, consent),
           {:ok, enabled} <- enable_consented_installation(agent) do
        enabled
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp consent_and_enable_agent(agent, consent) do
    Repo.transaction(fn ->
      with {:ok, _binding} <- AgentIsolation.grant_binding_consent(agent, consent),
           {:ok, enabled} <- enable_consented_installation(agent) do
        enabled
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp enable_consented_installation(agent) do
    now = DatabaseClock.now!()

    Agents.update_agent(agent, %{
      install_status: "enabled",
      status: "running",
      removed_at: nil,
      started_at: now,
      stopped_at: nil
    })
  end

  defp maybe_start_installed_agent(%{install_status: "enabled", status: "running"} = agent) do
    start_or_enqueue_with_failure_fence(agent)
  end

  defp maybe_start_installed_agent(_agent), do: {:ok, :not_started}

  # Web nodes persist desired state but never claim a lease or start an Agent.
  # WakeCoordinator's PostgreSQL sweep is authoritative; this local cast only
  # removes latency in combined/runtime development topologies.
  defp start_or_enqueue_with_failure_fence(agent, opts \\ []) do
    if RuntimeConfig.runtime_process?() do
      start_with_failure_fence(agent, opts)
    else
      :ok = WakeCoordinator.nudge()
      {:ok, :queued_for_runtime}
    end
  end

  defp start_or_enqueue_agent_process(agent, opts \\ []) do
    if RuntimeConfig.runtime_process?() do
      start_agent_process(agent, opts)
    else
      :ok = WakeCoordinator.nudge()
      {:ok, :queued_for_runtime}
    end
  end

  defp start_with_failure_fence(agent, opts) do
    case start_agent_process(agent, opts) do
      {:ok, _pid} = success ->
        success

      {:error, :runtime_lease_owned} = owned ->
        # A live exact owner is not a stranded desired state.
        owned

      {:error, _reason} = error ->
        _ = Agents.fail_agent_start_intent(agent.id)
        error
    end
  end

  defp start_agent_process(agent, opts) do
    if RuntimeConfig.runtime_process?() do
      opts = put_recorded_recovery_generation(agent.id, opts)

      supervisor_opts =
        opts
        |> Keyword.take([:recovery_generation])
        |> Keyword.put(:admission, start_admission(opts))

      case AgentSupervisor.start_agent(agent, supervisor_opts) do
        {:ok, pid} = result ->
          maybe_record_agent_resumed(agent, pid, opts)
          result

        other ->
          other
      end
    else
      {:error, :runtime_process_required}
    end
  end

  defp start_admission(opts) do
    cond do
      Keyword.get(opts, :admission) in [:normal, :bootstrap, :recovery] ->
        Keyword.fetch!(opts, :admission)

      Keyword.has_key?(opts, :recovery_generation) ->
        :recovery

      Keyword.get(opts, :resume_trigger) == "node_boot" ->
        :bootstrap

      true ->
        :normal
    end
  end

  defp execute_lifecycle(id, kind, request, planner, opts \\ []) do
    requires_external_drain = unfenced_local_agent_present?(id)

    with :ok <- exact_runtime_request_ready(),
         {:ok, fence} <-
           begin_lifecycle(id, kind, request, planner, requires_external_drain, opts, 3) do
      :ok = WakeCoordinator.nudge()
      _route_result = route_lifecycle_fence(fence, lifecycle_route_reason(kind, request))

      id
      |> finalize_lifecycle(fence.operation_token, fence.operation)
      |> case do
        {:ok, %{status: :reconciliation_pending} = pending} ->
          {:ok, Map.put(pending, :agent, Agents.get_agent(id, include_removed: true))}

        {:ok, finalized} ->
          {:ok, finalized}

        {:error, :lifecycle_operation_not_found} ->
          {:error, :agent_drain_pending}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp finalize_lifecycle(agent_id, operation_token, original_operation) do
    result =
      agent_id
      |> AgentLifecycleOperations.finalize(operation_token)
      |> recover_concurrently_finalized_lifecycle(
        agent_id,
        operation_token,
        original_operation
      )

    if RuntimeConfig.process_role() == :web and transient_lifecycle_result?(result) do
      deadline_ms = System.monotonic_time(:millisecond) + @web_lifecycle_finalize_wait_ms

      await_lifecycle_finalization(
        agent_id,
        operation_token,
        original_operation,
        result,
        deadline_ms
      )
    else
      result
    end
  end

  defp await_lifecycle_finalization(
         agent_id,
         operation_token,
         original_operation,
         last_result,
         deadline_ms
       ) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms > 0 and transient_lifecycle_result?(last_result) do
      receive do
      after
        min(@web_lifecycle_finalize_poll_ms, remaining_ms) -> :ok
      end

      result =
        agent_id
        |> AgentLifecycleOperations.finalize(operation_token)
        |> recover_concurrently_finalized_lifecycle(
          agent_id,
          operation_token,
          original_operation
        )

      await_lifecycle_finalization(
        agent_id,
        operation_token,
        original_operation,
        result,
        deadline_ms
      )
    else
      last_result
    end
  end

  defp recover_concurrently_finalized_lifecycle(
         {:error, :lifecycle_operation_not_found} = missing,
         agent_id,
         operation_token,
         original_operation
       ) do
    if RuntimeConfig.process_role() == :web do
      case AgentLifecycleOperations.confirm_finalized_postcondition(
             agent_id,
             operation_token,
             original_operation
           ) do
        {:ok, _result} = confirmed -> confirmed
        {:error, _reason} -> missing
      end
    else
      missing
    end
  end

  defp recover_concurrently_finalized_lifecycle(
         result,
         _agent_id,
         _operation_token,
         _original_operation
       ),
       do: result

  defp transient_lifecycle_result?(
         {:ok,
          %{
            status: :reconciliation_pending,
            reason: reason
          }}
       ) do
    reason in [
      :runtime_lease_owned,
      :active_run_pointer,
      :processing_directive,
      :running_agent_run,
      :requested_agent_run_step,
      :active_effect
    ]
  end

  defp transient_lifecycle_result?(_result), do: false

  defp begin_lifecycle(_id, _kind, _request, _planner, _requires_external_drain, _opts, 0),
    do: {:error, :agent_stop_reconciliation_pending}

  defp begin_lifecycle(
         id,
         kind,
         request,
         planner,
         requires_external_drain,
         opts,
         attempts_remaining
       ) do
    begin_opts = Keyword.put(opts, :requires_external_drain, requires_external_drain)

    case AgentLifecycleOperations.begin(id, kind, request, planner, begin_opts) do
      {:error, {:expired_lease_requires_reconciliation, expired_lease}} ->
        case AgentRestartGuards.record_expired(id, expired_lease.owner_token) do
          {status, _incident} when status in [:requested, :duplicate] ->
            # The incident is a durable replacement fence, not loss proof.
            # Keep the expired lease and lifecycle mutation blocked.
            {:error, :agent_stop_reconciliation_pending}

          {:ignored, :lease_renewed} ->
            begin_lifecycle(
              id,
              kind,
              request,
              planner,
              requires_external_drain,
              opts,
              attempts_remaining - 1
            )

          {:ignored, _reason} ->
            {:error, :agent_stop_reconciliation_pending}

          {:error, reason} ->
            {:error, reason}
        end

      result ->
        result
    end
  end

  defp unfenced_local_agent_present?(agent_id) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{pid, routing_metadata}] when is_pid(pid) ->
        match?(:error, Ecto.UUID.cast(routing_metadata))

      _no_single_local_process ->
        false
    end
  catch
    :exit, _reason -> true
  end

  defp route_lifecycle_fence(%{lease: nil}, _reason), do: :not_routed

  defp route_lifecycle_fence(%{agent: agent, lease: lease}, reason) do
    route_fenced_agent_stop(agent.id, lease, reason)
  end

  defp route_fenced_agent_stop(agent_id, lease, reason) do
    local_node = Atom.to_string(node())

    case Registry.lookup(AgentRegistry, agent_id) do
      [{pid, owner_token}] when is_pid(pid) and owner_token == lease.owner_token ->
        if lease.owner_node == local_node do
          AgentSupervisor.stop_agent(pid, reason, lease.owner_token)
        else
          dispatch_fenced_agent_stop(agent_id, lease.owner_token, reason)
        end

      _not_local_exact_owner ->
        dispatch_fenced_agent_stop(agent_id, lease.owner_token, reason)
    end
  catch
    :exit, _reason -> {:error, :agent_stop_route_unavailable}
  end

  defp dispatch_fenced_agent_stop(agent_id, owner_token, reason) do
    # A delayed cross-node stop can address only the generation captured in the
    # durable operation marker; a successor cannot consume it.
    Dispatch.dispatch(agent_id, {:control, :stop, reason, owner_token})
  end

  defp lifecycle_route_reason(:stop, %{"reason" => reason}), do: reason
  defp lifecycle_route_reason(:delete, _request), do: "deleted_from_admin"
  defp lifecycle_route_reason(:pause, _request), do: "paused_from_marketplace"
  defp lifecycle_route_reason(:remove, _request), do: "removed_from_marketplace"
  defp lifecycle_route_reason(:update, _request), do: "restarting_with_updated_config"
  defp lifecycle_route_reason(:upgrade, _request), do: "restarting_with_upgraded_package"

  defp lifecycle_reason(reason, fallback)
       when is_binary(reason) and byte_size(reason) in 1..255 do
    if String.valid?(reason) and :binary.match(reason, <<0>>) == :nomatch,
      do: reason,
      else: fallback
  end

  defp lifecycle_reason(_reason, fallback), do: fallback

  defp require_finalized_agent(%{status: :finalized, agent: %Agent{} = agent}),
    do: {:ok, agent}

  defp require_finalized_agent(%{status: :reconciliation_pending}),
    do: {:error, :agent_drain_pending}

  defp require_finalized_agent(_result), do: {:error, :agent_lifecycle_incomplete}

  defp require_finalized_delete(%{status: :finalized, action: :deleted}), do: :ok

  defp require_finalized_delete(%{status: :reconciliation_pending}),
    do: {:error, :agent_drain_pending}

  defp require_finalized_delete(_result), do: {:error, :agent_lifecycle_incomplete}

  defp maybe_start_finalized_agent(agent, true) do
    with {:ok, _pid_or_status} <- start_or_enqueue_with_failure_fence(agent), do: {:ok, agent}
  end

  defp maybe_start_finalized_agent(agent, false), do: {:ok, agent}

  defp lookup_agent_process(id) do
    case Registry.lookup(AgentRegistry, id) do
      [{pid, _routing_metadata}] when is_pid(pid) -> {:ok, pid}
      [] -> :not_running
    end
  end

  defp build_status(agent) do
    base = %{
      id: agent.id,
      project_id: agent.project_id,
      status: agent.status,
      behavior: agent.behavior,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      config: agent.config
    }

    # Add runtime info if process is running
    case lookup_agent_process(agent.id) do
      {:ok, pid} ->
        runtime_info = get_runtime_info(pid)
        Map.merge(base, %{runtime: runtime_info})

      :not_running ->
        base
    end
  end

  defp get_runtime_info(pid) do
    try do
      # This would call into the agent process for live stats
      # For now, return basic process info
      info = Process.info(pid, [:message_queue_len, :memory])

      %{
        pid: inspect(pid),
        message_queue_len: info[:message_queue_len],
        memory_bytes: info[:memory]
      }
    rescue
      _ -> %{}
    end
  end

  defp default_budget do
    %{
      "llm_calls" => 500,
      "tool_calls" => 1000
    }
  end

  defp maybe_record_agent_resumed(agent, pid, opts) do
    case Keyword.get(opts, :resume_trigger) do
      nil ->
        :ok

      trigger ->
        metadata =
          %{
            "resume_trigger" => trigger,
            "behavior" => agent.behavior,
            "user_id" => agent.user_id,
            "pid" => inspect(pid)
          }
          |> Map.merge(Keyword.get(opts, :metadata, %{}))

        IncidentLog.record(%{
          kind: :agent_resumed,
          agent_id: agent.id,
          metadata: metadata
        })

        :ok
    end
  end

  defp planned_agent_update(agent, params) do
    existing_config = agent.config || %{}
    incoming_config = params["config"] || params[:config] || %{}
    behavior = params["behavior"] || params[:behavior] || agent.behavior

    config =
      case incoming_config do
        map when is_map(map) -> Map.merge(existing_config, map)
        _ -> existing_config
      end

    with :ok <- validate_unchanged_binding_owner(agent, params) do
      attrs = %{"behavior" => behavior, "config" => config}

      attrs =
        case fetch_optional_param(params, "project_id") do
          :missing -> attrs
          value -> Map.put(attrs, "project_id", normalize_optional_string(value))
        end

      budget = params["budget"] || params[:budget] || Map.get(existing_config, "budget")

      attrs =
        if is_map(budget),
          do: put_in(attrs, ["config", "budget"], budget),
          else: attrs

      {:ok, attrs}
    end
  end

  defp validate_unchanged_binding_owner(agent, params) do
    case fetch_optional_param(params, "user_id") do
      :missing ->
        :ok

      value ->
        if normalize_optional_string(value) == agent.user_id,
          do: :ok,
          else: {:error, :binding_user_mismatch}
    end
  end

  defp resolve_upgrade_version(agent, :latest) do
    case Agents.get_agent(agent.id,
           include_removed: true,
           preload: [agent_package: [:latest_version]]
         ) do
      %{agent_package: %{latest_version: %AgentPackageVersion{} = version}} -> {:ok, version}
      _missing -> {:error, :package_not_found}
    end
  end

  defp resolve_upgrade_version(_agent, version_id) when is_binary(version_id) do
    case Agents.get_agent_package_version(version_id) do
      %AgentPackageVersion{} = version -> {:ok, version}
      nil -> {:error, :version_not_found}
    end
  end

  defp resolve_upgrade_version(_agent, _version_id), do: {:error, :version_not_found}

  defp wait_for_agent_response(
         id,
         correlation_id,
         message_id,
         _after_seq,
         timeout_ms,
         _poll_interval_ms
       )
       when timeout_ms <= 0 do
    {:ok,
     %{
       status: "queued",
       agent_id: id,
       correlation_id: correlation_id,
       message_id: message_id
     }}
  end

  defp wait_for_agent_response(
         id,
         correlation_id,
         message_id,
         after_seq,
         timeout_ms,
         poll_interval_ms
       ) do
    case matching_agent_response(id, correlation_id, message_id, after_seq) do
      {:ok, event} ->
        {:ok,
         %{
           status: response_status(event.event_type),
           agent_id: id,
           correlation_id: correlation_id,
           message_id: message_id,
           response: event.payload["response"] || event.payload[:response],
           error: event.payload["error"] || event.payload[:error],
           event_type: event.event_type
         }}

      :not_found ->
        wait_time = min(timeout_ms, poll_interval_ms)

        receive do
        after
          wait_time ->
            wait_for_agent_response(
              id,
              correlation_id,
              message_id,
              after_seq,
              timeout_ms - wait_time,
              poll_interval_ms
            )
        end
    end
  end

  defp matching_agent_response(id, correlation_id, message_id, after_seq) do
    id
    |> Events.list_events(
      after_seq: after_seq,
      limit: 50,
      types: ["agent_response", "agent_error"]
    )
    |> Enum.find(fn event ->
      payload = event.payload || %{}

      event_message_id = payload["message_id"] || payload[:message_id]
      event_correlation_id = payload["correlation_id"] || payload[:correlation_id]

      event_message_id == message_id or event_correlation_id == correlation_id
    end)
    |> case do
      nil -> :not_found
      event -> {:ok, event}
    end
  end

  defp response_status("agent_error"), do: "error"
  defp response_status(_event_type), do: "completed"

  defp durable_message_id(metadata) when is_map(metadata) do
    case metadata["message_id"] || metadata[:message_id] do
      nil ->
        {:ok, Ecto.UUID.generate()}

      value when is_binary(value) and byte_size(value) in 1..200 ->
        if String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
          do: {:ok, value},
          else: {:error, :invalid_message_id}

      _invalid ->
        {:error, :invalid_message_id}
    end
  end

  defp durable_message_id(_metadata), do: {:error, :invalid_message_metadata}

  defp durable_message_payload(message, metadata, message_id) when is_map(metadata) do
    %{"message" => message, "metadata" => metadata, "message_id" => message_id}
    |> Jason.encode()
    |> case do
      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          _invalid -> {:error, :invalid_message_payload}
        end

      {:error, _reason} ->
        {:error, :invalid_message_payload}
    end
  rescue
    _error -> {:error, :invalid_message_payload}
  end

  defp durable_message_payload(_message, _metadata, _message_id),
    do: {:error, :invalid_message_metadata}

  defp correlation_id(metadata) when is_map(metadata) do
    metadata["correlation_id"] || metadata[:correlation_id] || Ecto.UUID.generate()
  end

  defp correlation_id(_metadata), do: Ecto.UUID.generate()

  defp put_correlation_id(metadata, correlation_id) when is_map(metadata) do
    metadata
    |> Map.delete(:correlation_id)
    |> Map.put("correlation_id", correlation_id)
  end

  defp put_correlation_id(_metadata, correlation_id), do: %{"correlation_id" => correlation_id}

  defp fetch_optional_param(params, key) when is_map(params) do
    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      key == "user_id" and Map.has_key?(params, :user_id) -> Map.get(params, :user_id)
      key == "project_id" and Map.has_key?(params, :project_id) -> Map.get(params, :project_id)
      true -> :missing
    end
  end

  defp exact_runtime_enabled do
    cond do
      not RuntimeConfig.exact_agent_runtime_enabled?() -> {:error, :exact_runtime_disabled}
      not RuntimeConfig.runtime_process?() -> {:error, :runtime_process_required}
      not RuntimeConfig.exact_agent_runtime_ready?() -> {:error, :effect_protocol_not_exact}
      true -> :ok
    end
  end

  defp exact_runtime_request_ready do
    cond do
      not RuntimeConfig.exact_agent_runtime_enabled?() ->
        {:error, :exact_runtime_disabled}

      RuntimeConfig.maintenance_process?() ->
        {:error, :runtime_process_required}

      not RuntimeConfig.exact_agent_protocol_ready?() ->
        {:error, :effect_protocol_not_exact}

      RuntimeConfig.runtime_process?() and not RuntimeConfig.exact_agent_runtime_ready?() ->
        {:error, :effect_protocol_not_exact}

      true ->
        :ok
    end
  end

  defp local_start_preflight do
    if RuntimeConfig.runtime_process?(),
      do: AgentSupervisor.preflight(admission: :normal),
      else: :ok
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_string(value), do: value
end
