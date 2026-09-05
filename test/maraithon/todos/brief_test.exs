defmodule Maraithon.Todos.BriefTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Runtime.BackgroundJobHandler
  alias Maraithon.Todos
  alias Maraithon.Todos.{ActionDrafts, Brief}
  alias Maraithon.Todos.Brief.Context

  defp create_todo(user_id, attrs \\ %{}) do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        Map.merge(
          %{
            "source" => "gmail",
            "kind" => "gmail_triage",
            "title" => "Reply to Mock Person about the deck",
            "summary" => "Mock Person asked for the revised deck by Friday.",
            "next_action" => "Send the revised deck and confirm timing.",
            "priority" => 88,
            "dedupe_key" => "brief-test:#{System.unique_integer([:positive])}",
            "metadata" => %{
              "account" => user_id,
              "person" => "Mock Person",
              "source_quote" => "Can you send the revised deck by Friday?"
            }
          },
          attrs
        )
      ])

    todo
  end

  defp new_user(prefix) do
    user_id = "#{prefix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    user_id
  end

  test "generates a brief on the mock provider and stores the reply as a ready draft" do
    user_id = new_user("brief-generate")
    todo = create_todo(user_id)

    assert Brief.current(todo) == nil

    assert {:ok, updated} = Brief.generate_and_store(user_id, todo.id)

    brief = Brief.current(updated)
    assert brief["version"] == Brief.version()
    assert brief["why_it_matters"] =~ "blocked"
    assert brief["recommendation"] =~ "Send the reply"
    assert brief["steps"] == ["Open the source thread and confirm nothing changed."]
    assert brief["effort"] == "under_2_min"
    assert is_binary(brief["generated_at"])
    assert brief["fingerprint"] == Brief.fingerprint(updated)

    reply = Brief.reply(updated)
    assert reply["channel"] == "gmail"
    assert reply["subject"] == "Re: Mock thread"
    assert reply["body"] =~ "Thanks for the nudge"
    assert reply["resolves_todo"] == true

    assert updated.action_draft["style"] == "ready_to_send"
    assert updated.action_draft["source"] == "todo_brief"
    assert updated.action_draft["channel"] == "gmail"
    assert updated.action_draft["subject"] == "Re: Mock thread"
    assert ActionDrafts.preview(updated.action_draft) =~ "Thanks for the nudge"
    assert ActionDrafts.real_draft?(updated.action_draft)

    refute Map.has_key?(updated.metadata, "brief_generation")
    assert Brief.public(updated)["why_it_matters"] == brief["why_it_matters"]
    refute Map.has_key?(Brief.public(updated), "fingerprint")
  end

  test "open todos precompute their brief on the durable model lane" do
    user_id = new_user("brief-precompute")

    assert {:ok, [todo]} =
             Todos.upsert_many(
               user_id,
               [
                 %{
                   "source" => "gmail",
                   "kind" => "gmail_triage",
                   "title" => "Reply before opening this todo",
                   "summary" => "The source needs a response.",
                   "next_action" => "Send the prepared reply.",
                   "dedupe_key" => "brief-precompute:#{System.unique_integer([:positive])}",
                   "metadata" => %{"source_quote" => "Can you confirm today?"}
                 }
               ]
             )

    assert Brief.current(todo) == nil

    assert {:ok, job} = Brief.enqueue_generation(todo)
    assert job.job_type == "todo_brief_generation"
    assert job.queue == "runtime_model_user"
    assert String.starts_with?(job.partition_key, "tenant:")
    assert job.rate_limit_key == "model"
    assert job.payload["todo_id"] == todo.id

    assert {:ok, %{status: "ready", todo_id: todo_id}} = BackgroundJobHandler.execute(job)
    assert todo_id == todo.id
    assert Brief.current(Todos.get_for_user(user_id, todo.id))
  end

  test "background brief capacity errors use durable retry-after without spending an attempt" do
    busy = {:llm_busy, 1_000}
    rate_limited = {:rate_limited, 12, :redacted}

    assert {:error, {:retry_after, 10, ^busy}} =
             BackgroundJobHandler.defer_model_capacity(busy)

    assert {:error, {:retry_after, 12, ^rate_limited}} =
             BackgroundJobHandler.defer_model_capacity(rate_limited)

    assert {:error, :invalid_brief_json} =
             BackgroundJobHandler.defer_model_capacity(:invalid_brief_json)
  end

  test "projects fetched email messages into bounded display history" do
    history =
      Context.source_history(%{
        source: %{
          "message" => %{"subject" => "Great Catching Up"},
          "thread" => [
            %{
              "from" => "Michael Lippi <michael@example.com>",
              "to" => "Kent <kent@example.com>",
              "date" => "Fri, 28 Aug 2026 12:56:00 -0400",
              "body" => "Let me know when you and Christina are available."
            },
            %{
              "from" => "Kent <kent@example.com>",
              "to" => "Michael Lippi <michael@example.com>",
              "date" => "Fri, 28 Aug 2026 13:10:00 -0400",
              "body" => "I will sync with Christina tonight.",
              "is_from_user" => true
            }
          ]
        }
      })

    assert [michael, kent] = history
    assert michael["speaker"] == "Michael Lippi"
    assert michael["text"] =~ "Christina"
    assert kent["speaker"] == "Kent"
    assert kent["from_user"] == true
  end

  test "a current brief is reused instead of regenerated" do
    user_id = new_user("brief-reuse")
    todo = create_todo(user_id)

    assert {:ok, first} = Brief.generate_and_store(user_id, todo.id)

    test_pid = self()

    complete = fn _params ->
      send(test_pid, :llm_called)
      {:ok, %{content: "{}"}}
    end

    assert {:ok, second} = Brief.generate_and_store(user_id, todo.id, llm_complete: complete)
    refute_received :llm_called
    assert Brief.current(second)["generated_at"] == Brief.current(first)["generated_at"]
  end

  test "editing the todo makes the brief stale, but a partial update keeps the draft" do
    user_id = new_user("brief-stale")
    todo = create_todo(user_id)

    assert {:ok, briefed} = Brief.generate_and_store(user_id, todo.id)
    assert Brief.current(briefed)

    # Partial updates (notes, project) must not clobber the ready draft with a
    # placeholder next step.
    assert {:ok, noted} =
             Todos.update_for_user(user_id, todo.id, %{"notes" => "Keep it short."})

    assert noted.action_draft["source"] == "todo_brief"
    assert noted.action_draft["style"] == "ready_to_send"

    # Changing the substance of the todo invalidates the brief.
    assert {:ok, retitled} =
             Todos.update_for_user(user_id, todo.id, %{
               "title" => "Send the final deck to Mock Person"
             })

    assert Brief.current(retitled) == nil
    assert Brief.stored(retitled)["why_it_matters"] =~ "blocked"
  end

  test "an active generation lease blocks a second generation" do
    user_id = new_user("brief-lease")
    todo = create_todo(user_id)

    lease_until =
      DateTime.utc_now()
      |> DateTime.add(120, :second)
      |> DateTime.to_iso8601()

    assert {:ok, leased} =
             Todos.merge_metadata(user_id, todo.id, %{
               "brief_generation" => %{"lease_until" => lease_until}
             })

    assert Brief.generating?(leased)
    assert {:error, :in_progress} = Brief.generate_and_store(user_id, todo.id)
    assert {:ok, _todo} = Brief.generate_and_store(user_id, todo.id, force: true)
  end

  test "sanitizes fenced JSON and dashes, and drops empty replies" do
    user_id = new_user("brief-parse")
    todo = create_todo(user_id, %{"source" => "slack", "kind" => "general"})

    complete = fn params ->
      assert [%{"role" => "system"}, %{"role" => "user", "content" => prompt}] =
               params["messages"]

      assert prompt =~ "REPLY CHANNEL:\nslack"
      assert prompt =~ Brief.sentinel()

      {:ok,
       %{
         model: "mock-brief",
         content: """
         ```json
         {"why_it_matters": "Mock Person is waiting — the deck is due Friday.",
          "situation": "They asked twice.",
          "recommendation": "Send it today.",
          "steps": ["Export the deck", "", 42],
          "reply": {"channel": "slack", "body": "   ", "resolves_todo": true},
          "open_questions": [],
          "effort": "weird"}
         ```
         """
       }}
    end

    assert {:ok, brief, "mock-brief"} = Brief.generate(user_id, todo, llm_complete: complete)

    assert brief["why_it_matters"] == "Mock Person is waiting - the deck is due Friday."
    refute brief["why_it_matters"] =~ "—"
    assert brief["steps"] == ["Export the deck"]
    assert brief["reply"] == nil
    assert brief["effort"] == nil
  end

  test "rejects a response with no usable content" do
    user_id = new_user("brief-invalid")
    todo = create_todo(user_id)

    complete = fn _params -> {:ok, %{content: "not json at all"}} end

    assert {:error, :invalid_brief_json} = Brief.generate(user_id, todo, llm_complete: complete)

    assert {:error, :invalid_brief_json} =
             Brief.generate_and_store(user_id, todo.id, llm_complete: complete)

    refute Brief.generating?(Todos.get_for_user(user_id, todo.id))
  end

  test "brief failures log a closed class without provider-controlled detail" do
    user_id = new_user("brief-safe-log")
    todo = create_todo(user_id)
    unsafe_detail = "provider-private-#{System.unique_integer([:positive])}"
    complete = fn _params -> {:error, {:provider_error, unsafe_detail}} end

    Maraithon.LogBuffer.clear()

    assert {:error, {:provider_error, ^unsafe_detail}} =
             Brief.generate_and_store(user_id, todo.id, llm_complete: complete)

    Logger.flush()
    _ = :sys.get_state(Maraithon.LogBuffer)

    [entry] =
      Maraithon.LogBuffer.recent_matching(1, fn entry ->
        entry.message =~ "todo brief generation failed"
      end)

    assert entry.metadata["failure_code"] == "provider_error"
    assert entry.metadata["target_reference"] == Maraithon.Redaction.fingerprint(todo.id)
    refute Map.has_key?(entry.metadata, "reason")
    refute inspect(entry, printable_limit: :infinity) =~ unsafe_detail
  end
end
