defmodule Maraithon.Runtime.Agent do
  @moduledoc """
  Agent process using gen_statem.
  Manages the lifecycle of a single long-running agent.
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  alias Maraithon.Events
  alias Maraithon.Behaviors
  alias Maraithon.Runtime.Scheduler

  require Logger

  defstruct [
    :agent_id,
    :behavior_module,
    :behavior_state,
    :config,
    :budget,
    :sequence_num,
    :pending_effects,
    :handled_jobs,
    :last_heartbeat_at,
    :last_checkpoint_at,
    :started_at
  ]

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(agent) do
    GenStateMachine.start_link(__MODULE__, agent,
      name: {:via, Registry, {Maraithon.Runtime.AgentRegistry, agent.id}}
    )
  end

  def child_spec(agent) do
    %{
      id: agent.id,
      start: {__MODULE__, :start_link, [agent]},
      restart: :temporary,
      type: :worker
    }
  end

  # ==========================================================================
  # Callbacks
  # ==========================================================================

  @impl true
  def init(agent) do
    Logger.metadata(agent_id: agent.id)
    Logger.info("Agent initializing", behavior: agent.behavior)

    data = %__MODULE__{
      agent_id: agent.id,
      config: agent.config,
      sequence_num: 0,
      pending_effects: %{},
      handled_jobs: MapSet.new(),
      started_at: DateTime.utc_now()
    }

    # Start in recovering state to load any existing state
    {:ok, :recovering, data, [{:next_event, :internal, {:init, agent}}]}
  end

  # ==========================================================================
  # RECOVERING state
  # ==========================================================================

  def recovering(:enter, _old_state, data) do
    Logger.info("Entering recovering state")
    {:keep_state, data}
  end

  def recovering(:internal, {:init, agent}, data) do
    # Load behavior module
    behavior_module = Behaviors.get!(agent.behavior)

    # Initialize budget from config
    budget = init_budget(agent.config["budget"])

    # TODO: Load snapshot and replay events for crash recovery
    # For now, just initialize fresh

    # Initialize behavior state
    behavior_state = behavior_module.init(agent.config)

    data = %{data |
      behavior_module: behavior_module,
      behavior_state: behavior_state,
      budget: budget,
      sequence_num: Events.latest_sequence_num(agent.id)
    }

    # Emit started event
    emit_event(data, "agent_started", %{
      behavior: agent.behavior,
      config: agent.config
    })

    # Schedule initial heartbeat and checkpoint
    schedule_heartbeat(data)
    schedule_checkpoint(data)

    # Schedule first wakeup based on behavior
    schedule_next_wakeup(data)

    Logger.info("Agent recovered, transitioning to idle")
    {:next_state, :idle, data}
  end

  # ==========================================================================
  # IDLE state
  # ==========================================================================

  def idle(:enter, _old_state, data) do
    Logger.debug("Entering idle state")
    {:keep_state, data}
  end

  def idle(:info, {:wakeup, job_type, job_id, _payload}, data) do
    if MapSet.member?(data.handled_jobs, job_id) do
      # Duplicate, ignore
      {:keep_state, data}
    else
      data = %{data | handled_jobs: add_bounded(data.handled_jobs, job_id, 100)}

      case job_type do
        "heartbeat" ->
          data = emit_heartbeat(data)
          schedule_heartbeat(data)
          {:keep_state, data}

        "checkpoint" ->
          data = emit_checkpoint(data)
          schedule_checkpoint(data)
          {:keep_state, data}

        "wakeup" ->
          emit_event(data, "wakeup_received", %{job_id: job_id})

          if has_budget?(data) do
            {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
          else
            Logger.warn("No budget, staying idle")
            {:keep_state, data}
          end
      end
    end
  end

  def idle(:info, {:message, message, metadata, message_id}, data) do
    emit_event(data, "message_received", %{
      message: message,
      metadata: metadata,
      message_id: message_id
    })

    if has_budget?(data) do
      data = %{data | config: Map.put(data.config, "_last_message", message)}
      {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
    else
      Logger.warn("No budget, cannot process message")
      {:keep_state, data}
    end
  end

  def idle(:info, msg, data) do
    Logger.debug("Idle received unknown message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ==========================================================================
  # WORKING state
  # ==========================================================================

  def working(:enter, _old_state, data) do
    Logger.debug("Entering working state")
    {:keep_state, data}
  end

  def working(:internal, :execute_behavior, data) do
    context = build_context(data)

    case data.behavior_module.handle_wakeup(data.behavior_state, context) do
      {:effect, effect, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        request_effect(data, effect)

      {:emit, {event_type, payload}, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        emit_event(data, to_string(event_type), payload)
        schedule_next_wakeup(data)
        {:next_state, :idle, data}

      {:continue, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        {:keep_state, data, [{:next_event, :internal, :execute_behavior}]}

      {:idle, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        schedule_next_wakeup(data)
        {:next_state, :idle, data}
    end
  end

  def working(:info, {:wakeup, _, _, _} = msg, data) do
    # Queue wakeup for later
    send(self(), msg)
    {:keep_state, data}
  end

  def working(:info, msg, data) do
    Logger.debug("Working received message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ==========================================================================
  # WAITING_EFFECT state
  # ==========================================================================

  def waiting_effect(:enter, _old_state, data) do
    Logger.debug("Entering waiting_effect state")
    {:keep_state, data, [{:state_timeout, 120_000, :effect_timeout}]}
  end

  def waiting_effect(:info, {:effect_result, effect_id, result}, data) do
    case Map.pop(data.pending_effects, effect_id) do
      {nil, _} ->
        Logger.warn("Received result for unknown effect: #{effect_id}")
        {:keep_state, data}

      {effect_info, pending_effects} ->
        data = %{data | pending_effects: pending_effects}
        data = decrement_budget(data, effect_info.type)

        case result do
          {:ok, result_data} ->
            emit_event(data, "effect_completed", %{
              effect_id: effect_id,
              effect_type: effect_info.type,
              result: result_data
            })

            # Pass result to behavior
            context = build_context(data)
            case data.behavior_module.handle_effect_result(
                   {effect_info.type, result_data},
                   data.behavior_state,
                   context
                 ) do
              {:emit, {event_type, payload}, new_behavior_state} ->
                data = %{data | behavior_state: new_behavior_state}
                emit_event(data, to_string(event_type), payload)
                schedule_next_wakeup(data)
                {:next_state, :idle, data}

              {:idle, new_behavior_state} ->
                data = %{data | behavior_state: new_behavior_state}
                schedule_next_wakeup(data)
                {:next_state, :idle, data}

              {:effect, effect, new_behavior_state} ->
                data = %{data | behavior_state: new_behavior_state}
                request_effect(data, effect)
            end

          {:error, reason} ->
            emit_event(data, "effect_failed", %{
              effect_id: effect_id,
              error: inspect(reason)
            })

            schedule_next_wakeup(data)
            {:next_state, :idle, data}
        end
    end
  end

  def waiting_effect(:state_timeout, :effect_timeout, data) do
    Logger.warn("Effect timeout")
    schedule_next_wakeup(data)
    {:next_state, :idle, data}
  end

  def waiting_effect(:info, {:wakeup, _, _, _} = msg, data) do
    send(self(), msg)
    {:keep_state, data}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp emit_event(data, event_type, payload) do
    sequence_num = data.sequence_num + 1
    Events.append(data.agent_id, event_type, payload, sequence_num: sequence_num)
    Logger.info("Event: #{event_type}", event_type: event_type)
    %{data | sequence_num: sequence_num}
  end

  defp emit_heartbeat(data) do
    now = DateTime.utc_now()
    emit_event(data, "heartbeat_emitted", %{timestamp: DateTime.to_iso8601(now)})
    %{data | last_heartbeat_at: now}
  end

  defp emit_checkpoint(data) do
    # TODO: Write actual snapshot to snapshots table
    now = DateTime.utc_now()
    emit_event(data, "checkpoint_created", %{timestamp: DateTime.to_iso8601(now)})
    %{data | last_checkpoint_at: now}
  end

  defp schedule_heartbeat(data) do
    interval = get_config(:heartbeat_interval_ms, 900_000)
    Scheduler.schedule_in(data.agent_id, "heartbeat", interval)
  end

  defp schedule_checkpoint(data) do
    interval = get_config(:checkpoint_interval_ms, 600_000)
    Scheduler.schedule_in(data.agent_id, "checkpoint", interval)
  end

  defp schedule_next_wakeup(data) do
    case data.behavior_module.next_wakeup(data.behavior_state) do
      {:relative, ms} ->
        Scheduler.schedule_in(data.agent_id, "wakeup", ms)

      {:absolute, datetime} ->
        Scheduler.schedule_at(data.agent_id, "wakeup", datetime)

      :none ->
        :ok
    end
  end

  defp request_effect(data, {effect_type, params}) do
    request_effect(data, {effect_type, nil, params})
  end

  defp request_effect(data, {effect_type, tool_name, params}) do
    effect_id = Ecto.UUID.generate()
    idempotency_key = Ecto.UUID.generate()

    effect_info = %{
      type: effect_type,
      tool_name: tool_name,
      params: params,
      requested_at: DateTime.utc_now()
    }

    # Write to effect outbox
    Maraithon.Effects.request(data.agent_id, effect_type, tool_name, params, %{
      effect_id: effect_id,
      idempotency_key: idempotency_key
    })

    emit_event(data, "effect_requested", %{
      effect_id: effect_id,
      effect_type: effect_type,
      idempotency_key: idempotency_key
    })

    data = %{data | pending_effects: Map.put(data.pending_effects, effect_id, effect_info)}
    {:next_state, :waiting_effect, data}
  end

  defp build_context(data) do
    %{
      agent_id: data.agent_id,
      timestamp: DateTime.utc_now(),
      budget: data.budget,
      recent_events: [] # TODO: Load recent events
    }
  end

  defp init_budget(nil), do: %{llm_calls: 500, tool_calls: 1000}
  defp init_budget(budget) do
    %{
      llm_calls: budget["llm_calls"] || 500,
      tool_calls: budget["tool_calls"] || 1000
    }
  end

  defp has_budget?(data) do
    data.budget.llm_calls > 0 || data.budget.tool_calls > 0
  end

  defp decrement_budget(data, :llm_call) do
    %{data | budget: %{data.budget | llm_calls: max(0, data.budget.llm_calls - 1)}}
  end

  defp decrement_budget(data, :tool_call) do
    %{data | budget: %{data.budget | tool_calls: max(0, data.budget.tool_calls - 1)}}
  end

  defp decrement_budget(data, _), do: data

  defp add_bounded(set, item, max_size) do
    set = MapSet.put(set, item)
    if MapSet.size(set) > max_size do
      # Remove oldest (arbitrary since MapSet is unordered, but good enough)
      set |> MapSet.to_list() |> Enum.drop(1) |> MapSet.new()
    else
      set
    end
  end

  defp get_config(key, default) do
    Application.get_env(:maraithon, Maraithon.Runtime, [])
    |> Keyword.get(key, default)
  end
end
