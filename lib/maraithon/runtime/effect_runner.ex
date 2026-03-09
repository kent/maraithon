defmodule Maraithon.Runtime.EffectRunner do
  @moduledoc """
  Polls and executes effects from the outbox.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Effects.Effect
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.Effects.CommandFactory

  require Logger

  @default_poll_interval_ms 1_000
  # 5 minutes
  @default_claim_timeout_ms 300_000
  @default_batch_size 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    poll_interval_ms =
      RuntimeConfig.positive_integer(:effect_poll_interval_ms, @default_poll_interval_ms)

    claim_timeout_ms =
      RuntimeConfig.positive_integer(:effect_claim_timeout_ms, @default_claim_timeout_ms)

    batch_size = RuntimeConfig.positive_integer(:effect_batch_size, @default_batch_size)

    schedule_poll(poll_interval_ms)

    {:ok,
     %{
       running: %{},
       poll_interval_ms: poll_interval_ms,
       claim_timeout_ms: claim_timeout_ms,
       batch_size: batch_size,
       poll_retry_attempts: 0
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    case DbResilience.with_database("effect runner poll", fn ->
           reclaim_stale_effects(state.claim_timeout_ms)
           fetch_pending_effects(state.batch_size)
         end) do
      {:ok, effects} ->
        running =
          Enum.reduce(effects, state.running, fn effect, acc ->
            case claim_effect(effect) do
              {:ok, claimed} ->
                execute_effect_async(claimed)
                Map.put(acc, effect.id, effect)

              :already_claimed ->
                acc

              {:error, _reason} ->
                acc
            end
          end)

        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | running: running, poll_retry_attempts: 0}}

      {:error, _reason} ->
        retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
        schedule_poll(retry_in_ms)
        {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
    end
  end

  @impl true
  def handle_info({:effect_done, effect_id, _result}, state) do
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

    case DbResilience.with_database("effect runner claim effect", fn ->
           Repo.update_all(
             from(e in Effect,
               where: e.id == ^effect.id,
               where: e.status == "pending"
             ),
             set: [
               status: "claimed",
               claimed_by: node_id,
               claimed_at: DateTime.utc_now()
             ]
           )
         end) do
      {:ok, {1, _}} ->
        DbResilience.with_database("effect runner load claimed effect", fn ->
          Repo.get!(Effect, effect.id)
        end)

      {:ok, {0, _}} ->
        :already_claimed

      {:error, reason} ->
        {:error, reason}
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

    result = execute_with_command(effect)

    case result do
      {:ok, data} ->
        case mark_completed(effect, data) do
          :ok -> notify_agent(effect.agent_id, effect.id, {:ok, data})
          {:error, _reason} -> :ok
        end

      {:error, reason} ->
        attempts = effect.attempts + 1

        if attempts < effect.max_attempts do
          mark_pending_retry(effect, reason, attempts)
        else
          case mark_failed(effect, reason) do
            :ok -> notify_agent(effect.agent_id, effect.id, {:error, reason})
            {:error, _reason} -> :ok
          end
        end
    end

    result
  end

  defp execute_with_command(effect) do
    with {:ok, command_module} <- CommandFactory.fetch(effect.effect_type) do
      command_module.execute(effect)
    else
      {:error, :unknown_effect_type} ->
        {:error, "unknown_effect_type"}
    end
  end

  defp mark_completed(effect, result) do
    case DbResilience.with_database("effect runner mark completed", fn ->
           Repo.update_all(
             from(e in Effect, where: e.id == ^effect.id),
             set: [
               status: "completed",
               result: result,
               claimed_by: nil,
               claimed_at: nil,
               updated_at: DateTime.utc_now()
             ]
           )
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_pending_retry(effect, reason, attempts) do
    backoff_ms = calculate_backoff(attempts)
    retry_after = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

    case DbResilience.with_database("effect runner mark retry", fn ->
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
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_failed(effect, reason) do
    case DbResilience.with_database("effect runner mark failed", fn ->
           Repo.update_all(
             from(e in Effect, where: e.id == ^effect.id),
             set: [
               status: "failed",
               error: inspect(reason),
               claimed_by: nil,
               claimed_at: nil,
               updated_at: DateTime.utc_now()
             ]
           )
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify_agent(agent_id, effect_id, result) do
    :ok = Dispatch.dispatch(agent_id, {:effect_result, effect_id, result})
  end

  defp reclaim_stale_effects(claim_timeout_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -claim_timeout_ms, :millisecond)

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

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
