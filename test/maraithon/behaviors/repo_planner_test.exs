defmodule Maraithon.Behaviors.RepoPlannerTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors.RepoPlanner

  @test_dir Path.join(System.tmp_dir!(), "maraithon_repo_planner_test")

  @context %{
    agent_id: "test-agent",
    timestamp: DateTime.utc_now(),
    budget: %{llm_calls: 100, tool_calls: 100},
    last_message: nil
  }

  setup do
    # Create test directory with files
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    File.mkdir_p!(Path.join(@test_dir, "lib"))
    File.mkdir_p!(Path.join(@test_dir, "config"))

    # Create some test files
    File.write!(Path.join(@test_dir, "mix.exs"), """
    defmodule Test.MixProject do
      use Mix.Project
      def project, do: [app: :test, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(@test_dir, "lib/test.ex"), """
    defmodule Test do
      def hello, do: :world
    end
    """)

    File.write!(Path.join(@test_dir, "config/config.exs"), """
    import Config
    config :test, key: :value
    """)

    File.write!(Path.join(@test_dir, "README.md"), "# Test Project")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "init/1" do
    test "initializes with default values" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})

      assert state.codebase_path == @test_dir
      assert state.output_path == Path.join(@test_dir, "PLANS")
      assert state.phase == :indexing
      assert state.iteration == 0
      assert is_list(state.index.files)
      assert is_binary(state.index.file_tree)
      assert state.index.file_summaries == %{}
      assert is_list(state.files_to_summarize)
      assert state.current_task == nil
      assert state.planning_queue == []
      assert state.write_plan_files == true
    end

    test "identifies entry points" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})

      # Should find entry points like mix.exs, README.md, config files
      assert length(state.files_to_summarize) > 0
    end

    test "respects custom output path" do
      state = RepoPlanner.init(%{
        "codebase_path" => @test_dir,
        "output_path" => "/tmp/custom_plans"
      })

      assert state.output_path == "/tmp/custom_plans"
    end

    test "respects write_plan_files setting" do
      state = RepoPlanner.init(%{
        "codebase_path" => @test_dir,
        "write_plan_files" => false
      })

      assert state.write_plan_files == false
    end

    test "respects custom file patterns" do
      state = RepoPlanner.init(%{
        "codebase_path" => @test_dir,
        "file_patterns" => ["**/*.md"]
      })

      # Should only find markdown files
      file_names = Enum.map(state.index.files, &Path.basename/1)
      assert "README.md" in file_names
      refute "test.ex" in file_names
    end
  end

  describe "handle_wakeup/2 - indexing phase" do
    test "summarizes entry point files" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})

      {:effect, {:llm_call, params}, new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert new_state.iteration == 1
      assert new_state.current_file != nil
      assert is_map(params)
      assert params["max_tokens"] == 400
    end

    test "transitions to ready when indexing complete" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | files_to_summarize: []}

      {:emit, {:index_complete, payload}, new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert new_state.phase == :ready
      assert payload.files_indexed == 0
      assert new_state.index.last_indexed_at != nil
    end

    test "skips unreadable files during indexing" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | files_to_summarize: ["/nonexistent/file.ex"]}

      {:continue, new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert new_state.files_to_summarize == []
    end
  end

  describe "handle_wakeup/2 - ready phase" do
    test "starts planning when message received" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :ready, files_to_summarize: []}
      context = Map.put(@context, :last_message, "Add user authentication")

      {:emit, {:planning_started, payload}, new_state} = RepoPlanner.handle_wakeup(state, context)

      assert new_state.phase == :planning
      assert new_state.current_task != nil
      assert new_state.current_task.task == "Add user authentication"
      assert payload.task == "Add user authentication"
    end

    test "does not reprocess same message" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :ready, files_to_summarize: [], last_processed_message: "Add auth"}
      context = Map.put(@context, :last_message, "Add auth")

      {:idle, _state} = RepoPlanner.handle_wakeup(state, context)
    end

    test "processes tasks from queue" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :ready, files_to_summarize: [], planning_queue: [%{task: "Queued task"}]}

      {:emit, {:planning_started, payload}, new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert new_state.current_task.task == "Queued task"
      assert payload.task == "Queued task"
      assert new_state.planning_queue == []
    end

    test "returns idle when nothing to do" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :ready, files_to_summarize: []}

      {:idle, _state} = RepoPlanner.handle_wakeup(state, @context)
    end
  end

  describe "handle_wakeup/2 - planning phase" do
    test "analyzing phase requests LLM analysis" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :analyzing,
        analysis: nil,
        files_to_read: [],
        gathered_files: %{},
        started_at: DateTime.utc_now()
      }}

      {:effect, {:llm_call, params}, _new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert params["max_tokens"] == 1500
    end

    test "gathering phase reads files" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :gathering,
        analysis: %{},
        files_to_read: ["/path/to/file.ex"],
        gathered_files: %{},
        started_at: DateTime.utc_now()
      }}

      {:effect, {:tool_call, tool, args}, new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert tool == "read_file"
      assert args == %{"path" => "/path/to/file.ex"}
      assert new_state.current_task.files_to_read == []
    end

    test "gathering phase transitions to generating when done" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :gathering,
        analysis: %{},
        files_to_read: [],
        gathered_files: %{},
        started_at: DateTime.utc_now()
      }}

      {:continue, new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert new_state.current_task.phase == :generating
    end

    test "generating phase requests plan generation" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :generating,
        analysis: %{},
        files_to_read: [],
        gathered_files: %{"/path/file.ex" => "content"},
        started_at: DateTime.utc_now()
      }}

      {:effect, {:llm_call, params}, _new_state} = RepoPlanner.handle_wakeup(state, @context)

      assert params["max_tokens"] == 4000
    end
  end

  describe "handle_effect_result/3 - indexing" do
    test "stores file summary" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | current_file: "test.ex"}
      response = %{content: "This is a test module."}

      {:emit, {:note_appended, note}, new_state} =
        RepoPlanner.handle_effect_result({:llm_call, response}, state, @context)

      assert new_state.index.file_summaries["test.ex"] == "This is a test module."
      assert new_state.current_file == nil
      assert note =~ "Indexed"
    end
  end

  describe "handle_effect_result/3 - planning LLM results" do
    test "handles analysis response with valid JSON" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      file_path = Path.join(@test_dir, "lib/test.ex")
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :analyzing,
        analysis: nil,
        files_to_read: [],
        gathered_files: %{},
        started_at: DateTime.utc_now()
      }}

      response = %{content: ~s({"understanding": "Add auth", "files_to_examine": ["#{file_path}"], "patterns_observed": [], "considerations": []})}

      {:continue, new_state} =
        RepoPlanner.handle_effect_result({:llm_call, response}, state, @context)

      assert new_state.current_task.phase == :gathering
      assert new_state.current_task.analysis["understanding"] == "Add auth"
      assert length(new_state.current_task.files_to_read) == 1
    end

    test "handles analysis response with invalid JSON" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :analyzing,
        analysis: nil,
        files_to_read: [],
        gathered_files: %{},
        started_at: DateTime.utc_now()
      }}

      response = %{content: "Not valid JSON at all"}

      {:continue, new_state} =
        RepoPlanner.handle_effect_result({:llm_call, response}, state, @context)

      assert new_state.current_task.phase == :gathering
      assert new_state.current_task.analysis["understanding"] =~ "Not valid JSON"
      assert new_state.current_task.files_to_read == []
    end

    test "handles generating phase result" do
      state = RepoPlanner.init(%{
        "codebase_path" => @test_dir,
        "write_plan_files" => false
      })
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :generating,
        analysis: %{},
        files_to_read: [],
        gathered_files: %{"/file.ex" => "content"},
        started_at: DateTime.utc_now()
      }}

      response = %{content: "# Implementation Plan\n\n## Overview\nThis plan..."}

      {:emit, {:plan_generated, payload}, new_state} =
        RepoPlanner.handle_effect_result({:llm_call, response}, state, @context)

      assert new_state.phase == :ready
      assert new_state.current_task == nil
      assert payload.task_id == "test-id"
      assert payload.plan =~ "Implementation Plan"
      assert "/file.ex" in payload.files_referenced
    end
  end

  describe "handle_effect_result/3 - tool results" do
    test "stores file content from tool result" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :gathering,
        analysis: %{},
        files_to_read: [],
        gathered_files: %{},
        started_at: DateTime.utc_now()
      }}

      result = {:ok, %{content: "file content", path: "/path/to/file.ex"}}

      {:continue, new_state} =
        RepoPlanner.handle_effect_result({:tool_call, result}, state, @context)

      assert new_state.current_task.gathered_files["/path/to/file.ex"] == "file content"
    end

    test "handles error in tool result" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning, current_task: %{
        id: "test-id",
        task: "Add feature",
        phase: :gathering,
        analysis: %{},
        files_to_read: [],
        gathered_files: %{},
        started_at: DateTime.utc_now()
      }}

      result = {:error, :enoent}

      {:continue, _new_state} =
        RepoPlanner.handle_effect_result({:tool_call, result}, state, @context)
    end

    test "returns idle for tool results in wrong phase" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :ready}

      {:idle, _state} =
        RepoPlanner.handle_effect_result({:tool_call, {:ok, %{}}}, state, @context)
    end
  end

  describe "next_wakeup/1" do
    test "returns fast interval during indexing" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :indexing}

      {:relative, interval} = RepoPlanner.next_wakeup(state)

      assert interval == 1_000
    end

    test "returns fast interval during planning" do
      state = RepoPlanner.init(%{"codebase_path" => @test_dir})
      state = %{state | phase: :planning}

      {:relative, interval} = RepoPlanner.next_wakeup(state)

      assert interval == 1_000
    end

    test "returns configured interval when ready" do
      state = RepoPlanner.init(%{
        "codebase_path" => @test_dir,
        "wakeup_interval_ms" => 60_000
      })
      state = %{state | phase: :ready}

      {:relative, interval} = RepoPlanner.next_wakeup(state)

      assert interval == 60_000
    end
  end
end
