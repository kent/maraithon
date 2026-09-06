defmodule Maraithon.Todos.DeferredIngestion do
  @moduledoc "Durable todo deduplication outside the Chief of Staff's lease-renewal process."

  import Ecto.Query

  alias Maraithon.{Briefs, OpenLoops, Repo}
  alias Maraithon.AssistantHarness.PromptStability
  alias Maraithon.Briefs.Brief
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs}

  @job_type "runtime_partition:todo_ingestion"

  def enqueue(user_id, candidates, opts) when is_binary(user_id) and is_list(candidates) do
    payload = %{
      "candidates" => candidates,
      "source" => Keyword.fetch!(opts, :source),
      "brief_dedupe_key" => Keyword.get(opts, :brief_dedupe_key)
    }

    digest =
      :crypto.hash(:sha256, PromptStability.encode!(payload)) |> Base.encode16(case: :lower)

    with {:ok, job} <-
           BackgroundJobs.enqueue(@job_type, %{
             user_id: user_id,
             queue: "runtime_model_user",
             partition_key: "user:#{user_id}",
             rate_limit_key: "model",
             dedupe_key: "todo-ingestion:#{user_id}:#{digest}",
             max_attempts: 8,
             payload: payload
           }) do
      {:ok, %{todos: [], queued_count: length(candidates), job_id: job.id, pending: true}}
    end
  end

  def execute(%BackgroundJob{user_id: user_id, payload: %{"candidates" => candidates} = payload})
      when is_binary(user_id) and is_list(candidates) do
    with {:ok, brief} <- target_brief(user_id, payload["brief_dedupe_key"]),
         {:ok, result} <-
           OpenLoops.ingest_todos(user_id, candidates,
             source: payload["source"],
             llm_busy_retry_delays_ms: []
           ),
         :ok <- attach_result(brief, result) do
      {:ok,
       %{todo_count: length(result.todos), skipped_count: Map.get(result, :skipped_count, 0)}}
    end
  end

  def execute(_job), do: {:error, :invalid_todo_ingestion}

  defp target_brief(_user_id, nil), do: {:ok, nil}

  defp target_brief(user_id, dedupe_key) do
    case Repo.get_by(Brief, user_id: user_id, dedupe_key: dedupe_key) do
      nil -> {:error, :todo_ingestion_brief_not_ready}
      brief -> {:ok, brief}
    end
  end

  defp attach_result(nil, _result), do: :ok

  defp attach_result(brief, result) do
    Repo.transaction(fn ->
      current = Repo.one!(from(b in Brief, where: b.id == ^brief.id, lock: "FOR UPDATE"))

      ids =
        Enum.map(result.todos, & &1.id) ++ Map.get(current.metadata || %{}, "linked_todo_ids", [])

      with {:ok, linked} <- Briefs.attach_linked_todos(current, ids),
           {:ok, _updated} <-
             linked
             |> Ecto.Changeset.change(
               metadata:
                 Map.put(linked.metadata, "todo_write", %{
                   "status" => "completed",
                   "todo_count" => length(result.todos),
                   "skipped_count" => Map.get(result, :skipped_count, 0)
                 })
             )
             |> Repo.update() do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
