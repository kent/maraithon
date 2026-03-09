defmodule Maraithon.Behaviors.CodebaseAdvisorTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors.CodebaseAdvisor

  @test_dir Path.join(System.tmp_dir!(), "maraithon_codebase_advisor_test")

  @context %{
    agent_id: "test-agent",
    timestamp: DateTime.utc_now(),
    budget: %{llm_calls: 100, tool_calls: 100}
  }

  setup do
    # Create test directory with files
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    File.write!(
      Path.join(@test_dir, "test.ex"),
      "defmodule Test do\n  def hello, do: :world\nend"
    )

    File.write!(Path.join(@test_dir, "other.txt"), "not elixir")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "init/1" do
    test "initializes with default values" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})

      assert state.codebase_path == @test_dir
      assert state.iteration == 0
      assert is_list(state.all_files)
      assert state.pending_files == state.all_files
      assert state.reviewed_files == []
      assert state.recommendations == []
    end

    test "discovers elixir files by default" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})

      # Should find .ex file but not .txt
      file_names = Enum.map(state.all_files, &Path.basename/1)
      assert "test.ex" in file_names
      refute "other.txt" in file_names
    end

    test "respects custom file patterns" do
      state =
        CodebaseAdvisor.init(%{
          "codebase_path" => @test_dir,
          "file_patterns" => ["**/*.txt"]
        })

      file_names = Enum.map(state.all_files, &Path.basename/1)
      assert "other.txt" in file_names
      refute "test.ex" in file_names
    end

    test "sets custom output path" do
      state =
        CodebaseAdvisor.init(%{
          "codebase_path" => @test_dir,
          "output_path" => "/tmp/custom_output.md"
        })

      assert state.output_path == "/tmp/custom_output.md"
    end
  end

  describe "handle_wakeup/2" do
    test "requests LLM review for pending file" do
      state =
        CodebaseAdvisor.init(%{"codebase_path" => @test_dir, "file_patterns" => ["**/*.ex"]})

      {:effect, {:llm_call, params}, new_state} = CodebaseAdvisor.handle_wakeup(state, @context)

      assert new_state.iteration == 1
      assert is_map(params)
      assert params["max_tokens"] == 2000
      # Should have current_file set
      assert new_state.current_file =~ "test.ex"
    end

    test "emits note when all files reviewed" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})
      state = %{state | pending_files: []}

      {:emit, {:note_appended, note}, _state} = CodebaseAdvisor.handle_wakeup(state, @context)

      assert note =~ "All files reviewed"
    end

    test "skips unreadable files" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})
      # Add a non-existent file to pending
      state = %{state | pending_files: ["/nonexistent/file.ex" | state.pending_files]}

      {:continue, new_state} = CodebaseAdvisor.handle_wakeup(state, @context)

      refute "/nonexistent/file.ex" in new_state.pending_files
    end
  end

  describe "handle_effect_result/3" do
    test "processes LLM review response" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})

      state =
        state
        |> Map.put(:current_file, "test.ex")
        |> Map.put(:current_content, "defmodule Test do end")

      response = %{content: "Code looks good, consider adding docs."}

      {:emit, {:note_appended, note}, new_state} =
        CodebaseAdvisor.handle_effect_result({:llm_call, response}, state, @context)

      assert note =~ "Reviewed"
      assert length(new_state.recommendations) == 1
      assert "test.ex" in new_state.reviewed_files
    end

    test "handles tool call results" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})

      {:idle, _state} =
        CodebaseAdvisor.handle_effect_result({:tool_call, %{}}, state, @context)
    end
  end

  describe "next_wakeup/1" do
    test "returns shorter interval when files pending" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})

      {:relative, interval} = CodebaseAdvisor.next_wakeup(state)

      assert interval == :timer.hours(1)
    end

    test "returns longer interval when all files reviewed" do
      state = CodebaseAdvisor.init(%{"codebase_path" => @test_dir})
      state = %{state | pending_files: []}

      {:relative, interval} = CodebaseAdvisor.next_wakeup(state)

      assert interval == :timer.hours(6)
    end
  end
end
