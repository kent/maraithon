defmodule Maraithon.Behaviors.RepoPlanner do
  @moduledoc """
  Behavior that analyzes a repository and generates implementation plans.

  Config:
    - codebase_path: Path to the codebase root (required)
    - output_path: Where to write plan files (default: ./PLANS)
    - file_patterns: Glob patterns to include (default: common source patterns)
    - ignore_patterns: Patterns to skip (default: deps, build dirs, etc.)
    - wakeup_interval_ms: How often to check for tasks (default: 30 seconds)
    - write_plan_files: Whether to write markdown files (default: true)
  """

  @behaviour Maraithon.Behaviors.Behavior

  @default_patterns ["**/*.ex", "**/*.exs", "**/*.js", "**/*.ts", "**/*.py", "**/*.go", "**/*.rs"]
  @default_ignore ["deps/**", "_build/**", "node_modules/**", ".git/**", "*.min.js", "vendor/**", "dist/**", "build/**"]
  @wakeup_interval_ms 30_000
  @max_entry_points 12

  require Logger

  # Entry point file patterns (priority order)
  @entry_point_patterns [
    "mix.exs",
    "package.json",
    "Cargo.toml",
    "go.mod",
    "pyproject.toml",
    "README.md",
    "README",
    "**/application.ex",
    "config/config.exs",
    "**/router.ex",
    "src/main.*",
    "src/index.*",
    "lib/*.ex"
  ]

  @impl true
  def init(config) do
    codebase_path = config["codebase_path"] || "."
    file_patterns = config["file_patterns"] || @default_patterns
    ignore_patterns = config["ignore_patterns"] || @default_ignore

    # Discover all files
    files = discover_files(codebase_path, file_patterns, ignore_patterns)

    # Build file tree representation
    file_tree = build_file_tree(codebase_path, files)

    # Identify entry points for indexing
    entry_points = identify_entry_points(files, codebase_path)

    Logger.info("RepoPlanner initialized",
      codebase_path: codebase_path,
      file_count: length(files),
      entry_points: length(entry_points)
    )

    %{
      codebase_path: codebase_path,
      output_path: config["output_path"] || Path.join(codebase_path, "PLANS"),
      file_patterns: file_patterns,
      ignore_patterns: ignore_patterns,
      wakeup_interval_ms: config["wakeup_interval_ms"] || @wakeup_interval_ms,
      write_plan_files: config["write_plan_files"] != false,

      # Codebase index
      index: %{
        files: files,
        file_tree: file_tree,
        file_summaries: %{},
        last_indexed_at: nil
      },

      # Planning state
      planning_queue: [],
      current_task: nil,
      phase: :indexing,

      # Working state
      files_to_summarize: entry_points,
      current_file: nil,
      iteration: 0,
      last_processed_message: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state = %{state | iteration: state.iteration + 1}

    case state.phase do
      :indexing -> handle_indexing(state, context)
      :ready -> handle_ready(state, context)
      :planning -> handle_planning(state, context)
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    case state.phase do
      :indexing -> handle_indexing_result(response, state)
      :planning -> handle_planning_llm_result(response, state, context)
      _ -> {:idle, state}
    end
  end

  def handle_effect_result({:tool_call, result}, state, _context) do
    case state.phase do
      :planning -> handle_planning_tool_result(result, state)
      _ -> {:idle, state}
    end
  end

  @impl true
  def next_wakeup(state) do
    case state.phase do
      :indexing -> {:relative, 1_000}  # Fast during indexing
      :planning -> {:relative, 1_000}  # Fast during planning
      :ready -> {:relative, state.wakeup_interval_ms}
    end
  end

  # ==========================================================================
  # Indexing Phase
  # ==========================================================================

  defp handle_indexing(state, _context) do
    case state.files_to_summarize do
      [] ->
        # Done indexing, transition to ready
        state = put_in(state.index.last_indexed_at, DateTime.utc_now())
        state = %{state | phase: :ready}
        Logger.info("Indexing complete", files_indexed: map_size(state.index.file_summaries))
        {:emit, {:index_complete, %{files_indexed: map_size(state.index.file_summaries)}}, state}

      [file | rest] ->
        case File.read(file) do
          {:ok, content} ->
            Logger.info("Summarizing entry point", file: file)
            prompt = build_summary_prompt(file, content)
            params = %{
              "messages" => [%{"role" => "user", "content" => prompt}],
              "max_tokens" => 400,
              "temperature" => 0.2
            }
            state = %{state | current_file: file, files_to_summarize: rest}
            {:effect, {:llm_call, params}, state}

          {:error, reason} ->
            Logger.warning("Skipping unreadable entry point", file: file, reason: reason)
            state = %{state | files_to_summarize: rest}
            {:continue, state}
        end
    end
  end

  defp handle_indexing_result(response, state) do
    file = state.current_file
    summary = response.content

    state = put_in(state.index.file_summaries[file], summary)
    state = %{state | current_file: nil}

    remaining = length(state.files_to_summarize)
    indexed = map_size(state.index.file_summaries)
    progress = "Indexed #{indexed} files, #{remaining} remaining"

    {:emit, {:note_appended, progress}, state}
  end

  # ==========================================================================
  # Ready Phase
  # ==========================================================================

  defp handle_ready(state, context) do
    last_message = context.last_message

    cond do
      # New planning task received
      last_message && last_message != state.last_processed_message ->
        Logger.info("New planning task received", task: String.slice(last_message, 0, 50))
        state = %{state | last_processed_message: last_message}
        start_planning_task(last_message, state)

      # Tasks in queue
      length(state.planning_queue) > 0 ->
        [task | rest] = state.planning_queue
        state = %{state | planning_queue: rest}
        start_planning_task(task.task, state)

      # Nothing to do
      true ->
        {:idle, state}
    end
  end

  defp start_planning_task(task_description, state) do
    task_id = generate_id()

    task = %{
      id: task_id,
      task: task_description,
      phase: :analyzing,
      analysis: nil,
      files_to_read: [],
      gathered_files: %{},
      started_at: DateTime.utc_now()
    }

    state = %{state | current_task: task, phase: :planning}
    {:emit, {:planning_started, %{task_id: task_id, task: task_description}}, state}
  end

  # ==========================================================================
  # Planning Phase
  # ==========================================================================

  defp handle_planning(state, _context) do
    task = state.current_task

    case task.phase do
      :analyzing ->
        # Build prompt with file tree + summaries, ask LLM what files to examine
        prompt = build_analysis_prompt(task.task, state.index)
        params = %{
          "messages" => [%{"role" => "user", "content" => prompt}],
          "max_tokens" => 1500,
          "temperature" => 0.3
        }
        {:effect, {:llm_call, params}, state}

      :gathering ->
        # Read files identified in analysis
        case task.files_to_read do
          [] ->
            # Done gathering, move to generating
            task = %{task | phase: :generating}
            state = %{state | current_task: task}
            {:continue, state}

          [file | rest] ->
            task = %{task | files_to_read: rest}
            state = %{state | current_task: task}
            {:effect, {:tool_call, "read_file", %{"path" => file}}, state}
        end

      :generating ->
        # Generate the final plan
        prompt = build_plan_prompt(task, state.index)
        params = %{
          "messages" => [%{"role" => "user", "content" => prompt}],
          "max_tokens" => 4000,
          "temperature" => 0.4
        }
        {:effect, {:llm_call, params}, state}
    end
  end

  defp handle_planning_llm_result(response, state, _context) do
    task = state.current_task

    case task.phase do
      :analyzing ->
        # Parse analysis response
        analysis = parse_analysis(response.content)
        files_to_read = analysis["files_to_examine"] || []

        # Filter to existing files and limit
        files_to_read =
          files_to_read
          |> Enum.filter(&File.exists?/1)
          |> Enum.take(10)

        task = %{task |
          phase: :gathering,
          analysis: analysis,
          files_to_read: files_to_read
        }
        state = %{state | current_task: task}

        Logger.info("Analysis complete", files_to_examine: length(files_to_read))
        {:continue, state}

      :generating ->
        # Plan is complete!
        plan_content = response.content
        task_id = task.id

        # Write plan file if enabled
        plan_file_path =
          if state.write_plan_files do
            write_plan_file(state, task, plan_content)
          else
            nil
          end

        # Reset state
        state = %{state | current_task: nil, phase: :ready}

        files_referenced = Map.keys(task.gathered_files)

        Logger.info("Plan generated", task_id: task_id, files_referenced: length(files_referenced))

        {:emit, {:plan_generated, %{
          task_id: task_id,
          task: task.task,
          plan: plan_content,
          files_referenced: files_referenced,
          plan_file_path: plan_file_path
        }}, state}

      _ ->
        {:idle, state}
    end
  end

  defp handle_planning_tool_result(result, state) do
    task = state.current_task

    case result do
      {:ok, %{content: content, path: path}} ->
        task = put_in(task.gathered_files[path], content)
        state = %{state | current_task: task}
        {:continue, state}

      {:ok, %{content: _content}} ->
        # Some tools might return content without explicit path
        {:continue, state}

      {:error, _reason} ->
        # Skip files that can't be read
        {:continue, state}

      _ ->
        {:continue, state}
    end
  end

  # ==========================================================================
  # Prompt Builders
  # ==========================================================================

  defp build_summary_prompt(file_path, content) do
    truncated =
      if String.length(content) > 8000 do
        String.slice(content, 0, 8000) <> "\n... (truncated)"
      else
        content
      end

    """
    Summarize this file in 2-3 sentences. Focus on:
    - What this file does / its main purpose
    - Key exports, functions, or configurations
    - Important patterns or dependencies

    File: #{file_path}

    ```
    #{truncated}
    ```
    """
  end

  defp build_analysis_prompt(task, index) do
    summaries_str =
      index.file_summaries
      |> Enum.map(fn {path, summary} -> "**#{path}**\n#{summary}" end)
      |> Enum.join("\n\n")

    """
    You are a software architect analyzing a codebase to plan an implementation.

    ## Task
    #{task}

    ## Codebase Structure
    ```
    #{index.file_tree}
    ```

    ## Key File Summaries
    #{summaries_str}

    ## All Files in Codebase
    #{Enum.take(index.files, 100) |> Enum.join("\n")}

    ## Instructions
    Analyze what changes this task requires and identify which files need to be examined in detail.

    Respond with JSON (no markdown code blocks):
    {
      "understanding": "Brief description of what the task requires",
      "files_to_examine": ["path/to/file1", "path/to/file2"],
      "patterns_observed": ["pattern1", "pattern2"],
      "considerations": ["thing to consider 1", "thing to consider 2"]
    }
    """
  end

  defp build_plan_prompt(task, index) do
    file_contents =
      task.gathered_files
      |> Enum.map(fn {path, content} ->
        truncated =
          if String.length(content) > 5000 do
            String.slice(content, 0, 5000) <> "\n... (truncated)"
          else
            content
          end

        """
        ### #{path}
        ```
        #{truncated}
        ```
        """
      end)
      |> Enum.join("\n\n")

    analysis_str = if task.analysis, do: Jason.encode!(task.analysis, pretty: true), else: "{}"

    """
    You are a software architect creating a detailed implementation plan.

    ## Task
    #{task.task}

    ## Analysis
    #{analysis_str}

    ## Codebase Structure
    ```
    #{index.file_tree}
    ```

    ## Relevant File Contents
    #{file_contents}

    ## Instructions
    Create a detailed, actionable implementation plan. Include:

    1. **Overview** - What this implementation accomplishes
    2. **Files to Create** - New files with their paths and purpose
    3. **Files to Modify** - Existing files with specific changes needed
    4. **Implementation Steps** - Ordered, specific steps with code examples
    5. **Testing Strategy** - How to verify the implementation works
    6. **Potential Challenges** - Risks or tricky aspects to watch for

    Format as Markdown. Be specific and include code snippets where helpful.
    """
  end

  # ==========================================================================
  # Helper Functions
  # ==========================================================================

  defp discover_files(base_path, patterns, ignore_patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      Path.join(base_path, pattern)
      |> Path.wildcard()
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(fn file ->
      Enum.any?(ignore_patterns, fn ignore ->
        String.contains?(file, String.replace(ignore, "**", ""))
      end)
    end)
    |> Enum.sort()
  end

  defp identify_entry_points(_files, base_path) do
    @entry_point_patterns
    |> Enum.flat_map(fn pattern ->
      full_pattern = Path.join(base_path, pattern)
      Path.wildcard(full_pattern)
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.take(@max_entry_points)
  end

  defp build_file_tree(base_path, files) do
    # Build a simple indented tree representation
    base_path = Path.expand(base_path)

    relative_files =
      files
      |> Enum.map(fn file ->
        Path.relative_to(file, base_path)
      end)
      |> Enum.sort()
      |> Enum.take(150)

    # Group by directory
    tree =
      relative_files
      |> Enum.reduce(%{}, fn file, acc ->
        parts = Path.split(file)
        put_in_nested(acc, parts)
      end)

    # Render tree
    render_tree(tree, 0)
  end

  defp put_in_nested(map, [single]), do: Map.put(map, single, :file)
  defp put_in_nested(map, [head | tail]) do
    current = Map.get(map, head, %{})
    Map.put(map, head, put_in_nested(current, tail))
  end

  defp render_tree(tree, depth) when is_map(tree) do
    tree
    |> Enum.sort_by(fn {k, v} -> {if(is_atom(v), do: 1, else: 0), k} end)
    |> Enum.map(fn {key, value} ->
      indent = String.duplicate("  ", depth)
      case value do
        :file -> "#{indent}#{key}"
        nested -> "#{indent}#{key}/\n#{render_tree(nested, depth + 1)}"
      end
    end)
    |> Enum.join("\n")
  end

  defp parse_analysis(content) do
    # Try to extract JSON from the response
    content = String.trim(content)

    # Remove markdown code blocks if present
    content =
      content
      |> String.replace(~r/```json\n?/, "")
      |> String.replace(~r/```\n?/, "")
      |> String.trim()

    case Jason.decode(content) do
      {:ok, json} -> json
      {:error, _} ->
        # Return a default structure if parsing fails
        %{
          "understanding" => content,
          "files_to_examine" => [],
          "patterns_observed" => [],
          "considerations" => []
        }
    end
  end

  defp write_plan_file(state, task, content) do
    # Ensure output directory exists
    File.mkdir_p!(state.output_path)

    # Generate filename
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.slice(0, 15)
    slug = task.task |> String.slice(0, 30) |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    filename = "PLAN_#{timestamp}_#{slug}.md"
    path = Path.join(state.output_path, filename)

    # Build full content
    full_content = """
    # Implementation Plan

    **Task:** #{task.task}
    **Generated:** #{DateTime.utc_now() |> DateTime.to_iso8601()}
    **Task ID:** #{task.id}

    ---

    #{content}
    """

    case File.write(path, full_content) do
      :ok ->
        Logger.info("Wrote plan file", path: path)
        path
      {:error, reason} ->
        Logger.error("Failed to write plan file", path: path, reason: reason)
        nil
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
