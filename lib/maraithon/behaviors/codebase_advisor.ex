defmodule Maraithon.Behaviors.CodebaseAdvisor do
  @moduledoc """
  Behavior that systematically reviews a codebase and suggests improvements.

  Config:
    - codebase_path: Path to the codebase root (required)
    - output_path: Where to write recommendations (default: ./RECOMMENDATIONS.md)
    - file_patterns: Glob patterns to include (default: ["**/*.ex", "**/*.exs"])
    - ignore_patterns: Patterns to skip (default: ["deps/**", "_build/**"])
    - wakeup_interval_ms: How often to wake up (default: 1 hour)
  """

  @behaviour Maraithon.Behaviors.Behavior

  @default_patterns ["**/*.ex", "**/*.exs", "**/*.js", "**/*.ts", "**/*.py", "**/*.go"]
  @default_ignore ["deps/**", "_build/**", "node_modules/**", ".git/**", "*.min.js", "vendor/**"]
  @wakeup_interval_ms :timer.hours(1)

  require Logger

  @impl true
  def init(config) do
    codebase_path = config["codebase_path"] || "."
    file_patterns = config["file_patterns"] || @default_patterns
    ignore_patterns = config["ignore_patterns"] || @default_ignore

    # Discover all files
    files = discover_files(codebase_path, file_patterns, ignore_patterns)

    Logger.info("CodebaseAdvisor initialized",
      codebase_path: codebase_path,
      file_count: length(files)
    )

    %{
      codebase_path: codebase_path,
      output_path: config["output_path"] || Path.join(codebase_path, "RECOMMENDATIONS.md"),
      file_patterns: file_patterns,
      ignore_patterns: ignore_patterns,
      all_files: files,
      pending_files: files,
      reviewed_files: [],
      recommendations: [],
      iteration: 0,
      wakeup_interval_ms: config["wakeup_interval_ms"] || @wakeup_interval_ms
    }
  end

  @impl true
  def handle_wakeup(state, _context) do
    state = %{state | iteration: state.iteration + 1}

    case pick_next_file(state) do
      nil ->
        # All files reviewed
        Logger.info("All files reviewed!")
        {:emit, {:note_appended, "All files reviewed! Final report written."}, state}

      file_path ->
        case File.read(file_path) do
          {:ok, content} ->
            Logger.info("Reviewing file", file: file_path, iteration: state.iteration)

            prompt = build_review_prompt(file_path, content, state)

            params = %{
              "messages" => [
                %{"role" => "user", "content" => prompt}
              ],
              "max_tokens" => 2000,
              "temperature" => 0.3
            }

            state = %{state | current_file: file_path, current_content: content}
            {:effect, {:llm_call, params}, state}

          {:error, reason} ->
            Logger.warning("Skipping unreadable file", file: file_path, reason: reason)
            state = mark_file_skipped(state, file_path)
            {:continue, state}
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, _context) do
    file_path = state.current_file
    review_content = response.content

    # Add to recommendations
    recommendation = %{
      file: file_path,
      review: review_content,
      reviewed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      iteration: state.iteration
    }

    state =
      state
      |> Map.put(:recommendations, [recommendation | state.recommendations])
      |> mark_file_reviewed(file_path)
      |> Map.delete(:current_file)
      |> Map.delete(:current_content)

    # Write updated recommendations file
    write_recommendations_file(state)

    progress = "Reviewed #{length(state.reviewed_files)}/#{length(state.all_files)}: #{file_path}"
    {:emit, {:note_appended, progress}, state}
  end

  def handle_effect_result({:tool_call, _result}, state, _context) do
    {:idle, state}
  end

  @impl true
  def next_wakeup(state) do
    if Enum.empty?(state.pending_files) do
      # Done - wake up less frequently just to heartbeat
      {:relative, :timer.hours(6)}
    else
      # Still working
      {:relative, state.wakeup_interval_ms}
    end
  end

  # Private functions

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

  defp pick_next_file(state) do
    List.first(state.pending_files)
  end

  defp mark_file_reviewed(state, file_path) do
    %{
      state
      | pending_files: List.delete(state.pending_files, file_path),
        reviewed_files: [file_path | state.reviewed_files]
    }
  end

  defp mark_file_skipped(state, file_path) do
    %{state | pending_files: List.delete(state.pending_files, file_path)}
  end

  defp build_review_prompt(file_path, content, state) do
    context =
      if length(state.reviewed_files) > 0 do
        recent = state.reviewed_files |> Enum.take(5) |> Enum.join(", ")
        "Recently reviewed: #{recent}"
      else
        "This is the first file being reviewed."
      end

    truncated_content =
      if String.length(content) > 15_000 do
        String.slice(content, 0, 15_000) <>
          "\n\n... (file truncated, #{String.length(content)} bytes total)"
      else
        content
      end

    """
    You are an expert code reviewer analyzing a codebase file by file.

    Focus areas: architecture, reliability, performance, testing, security, readability

    For each issue found, provide:
    1. Category (architecture/reliability/performance/testing/security/readability)
    2. Severity (high/medium/low)
    3. Clear explanation of the issue
    4. Concrete code suggestion for improvement

    Be specific and actionable. Don't nitpick style - focus on substantive improvements.
    If the code is solid, say so briefly and note any minor suggestions.

    #{context}

    Please review this file: `#{file_path}`

    ```
    #{truncated_content}
    ```
    """
  end

  defp write_recommendations_file(state) do
    content = render_markdown(state)

    case File.write(state.output_path, content) do
      :ok ->
        Logger.info("Wrote recommendations", path: state.output_path)

      {:error, reason} ->
        Logger.error("Failed to write recommendations", reason: reason)
    end
  end

  defp render_markdown(state) do
    reviewed_count = length(state.reviewed_files)
    total_count = length(state.all_files)
    progress_pct = if total_count > 0, do: round(reviewed_count / total_count * 100), else: 0

    recommendations_content =
      state.recommendations
      |> Enum.reverse()
      |> Enum.map(fn rec ->
        """

        ---

        ## #{rec.file}
        *Reviewed at: #{rec.reviewed_at}*

        #{rec.review}
        """
      end)
      |> Enum.join("\n")

    pending_list =
      state.pending_files
      |> Enum.take(20)
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    more_pending =
      if length(state.pending_files) > 20 do
        "\n... and #{length(state.pending_files) - 20} more"
      else
        ""
      end

    """
    # Codebase Recommendations

    Generated by Maraithon CodebaseAdvisor
    Progress: #{reviewed_count}/#{total_count} files reviewed (#{progress_pct}%)
    Last updated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    #{recommendations_content}

    ---

    ## Files Pending Review

    #{pending_list}#{more_pending}
    """
  end
end
