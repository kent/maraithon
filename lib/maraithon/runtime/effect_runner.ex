defmodule Maraithon.Runtime.EffectRunner do
  @moduledoc """
  Polls and executes effects from the outbox.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Effects.Effect
  alias Maraithon.LLM
  alias Maraithon.Tools

  require Logger

  @poll_interval_ms 1_000
  @claim_timeout_ms 300_000  # 5 minutes
  @batch_size 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{running: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    # Reclaim stale effects
    reclaim_stale_effects()

    # Fetch pending effects
    effects = fetch_pending_effects(@batch_size)

    # Claim and execute each
    running =
      Enum.reduce(effects, state.running, fn effect, acc ->
        case claim_effect(effect) do
          {:ok, claimed} ->
            execute_effect_async(claimed)
            Map.put(acc, effect.id, effect)

          :already_claimed ->
            acc
        end
      end)

    schedule_poll()
    {:noreply, %{state | running: running}}
  end

  @impl true
  def handle_info({:effect_done, effect_id, result}, state) do
    running = Map.delete(state.running, effect_id)
    {:noreply, %{state | running: running}}
  end

  @impl true
  def handle_call(:clear_running, _from, state) do
    {:reply, :ok, %{state | running: %{}}}
  end

  # Private functions

  defp fetch_pending_effects(limit) do
    now = DateTime.utc_now()

    from(e in Effect,
      where: e.status == "pending",
      where: is_nil(e.retry_after) or e.retry_after <= ^now,
      order_by: [asc: e.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp claim_effect(effect) do
    node_id = node() |> to_string()

    case Repo.update_all(
           from(e in Effect,
             where: e.id == ^effect.id,
             where: e.status == "pending"
           ),
           set: [
             status: "claimed",
             claimed_by: node_id,
             claimed_at: DateTime.utc_now()
           ]
         ) do
      {1, _} -> {:ok, Repo.get!(Effect, effect.id)}
      {0, _} -> :already_claimed
    end
  end

  defp execute_effect_async(effect) do
    parent = self()

    Task.Supervisor.start_child(Maraithon.Runtime.EffectSupervisor, fn ->
      result = execute_effect(effect)
      send(parent, {:effect_done, effect.id, result})
    end)
  end

  defp execute_effect(effect) do
    Logger.info("Executing effect #{effect.id}", effect_id: effect.id, type: effect.effect_type)

    result =
      case effect.effect_type do
        "llm_call" -> execute_llm_call(effect)
        "tool_call" -> execute_tool_call(effect)
        _ -> {:error, "unknown_effect_type"}
      end

    case result do
      {:ok, data} ->
        mark_completed(effect, data)
        notify_agent(effect.agent_id, effect.id, {:ok, data})

      {:error, reason} ->
        attempts = effect.attempts + 1

        if attempts < effect.max_attempts do
          mark_pending_retry(effect, reason, attempts)
        else
          mark_failed(effect, reason)
          notify_agent(effect.agent_id, effect.id, {:error, reason})
        end
    end

    result
  end

  defp execute_llm_call(effect) do
    params = effect.params
    timeout = params["timeout_ms"] || 120_000

    Logger.info("Starting LLM call for effect #{effect.id}",
      agent_id: effect.agent_id,
      effect_id: effect.id
    )

    try do
      provider = LLM.provider()
      result = provider.complete(params)

      case result do
        {:ok, data} ->
          Logger.info("LLM call succeeded",
            effect_id: effect.id,
            model: data.model,
            tokens: data.usage.total_tokens,
            cost: data.usage.total_cost
          )
          result

        {:error, reason} ->
          Logger.warn("LLM call failed", effect_id: effect.id, reason: inspect(reason))
          result
      end
    catch
      :exit, {:timeout, _} ->
        Logger.warn("LLM call timed out", effect_id: effect.id)
        {:error, "timeout"}
    end
  end

  defp execute_tool_call(effect) do
    tool_name = effect.params["tool"]
    args = effect.params["args"] || %{}

    case Tools.execute(tool_name, args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_completed(effect, result) do
    Repo.update_all(
      from(e in Effect, where: e.id == ^effect.id),
      set: [
        status: "completed",
        result: result,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp mark_pending_retry(effect, reason, attempts) do
    backoff_ms = calculate_backoff(attempts)
    retry_after = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

    Repo.update_all(
      from(e in Effect, where: e.id == ^effect.id),
      set: [
        status: "pending",
        claimed_by: nil,
        claimed_at: nil,
        attempts: attempts,
        retry_after: retry_after,
        error: inspect(reason),
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp mark_failed(effect, reason) do
    Repo.update_all(
      from(e in Effect, where: e.id == ^effect.id),
      set: [
        status: "failed",
        error: inspect(reason),
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp notify_agent(agent_id, effect_id, result) do
    case Registry.lookup(Maraithon.Runtime.AgentRegistry, agent_id) do
      [{pid, _}] ->
        send(pid, {:effect_result, effect_id, result})

      [] ->
        Logger.warn("Agent #{agent_id} not running, cannot deliver effect result")
    end
  end

  defp reclaim_stale_effects do
    cutoff = DateTime.add(DateTime.utc_now(), -@claim_timeout_ms, :millisecond)

    {count, _} =
      Repo.update_all(
        from(e in Effect,
          where: e.status == "claimed",
          where: e.claimed_at < ^cutoff
        ),
        set: [status: "pending", claimed_by: nil, claimed_at: nil]
      )

    if count > 0 do
      Logger.info("Reclaimed #{count} stale effects")
    end
  end

  defp calculate_backoff(attempt) do
    base = 1_000
    max = 60_000
    delay = base * :math.pow(2, attempt)
    jitter = :rand.uniform() * delay * 0.3
    round(min(delay + jitter, max))
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
