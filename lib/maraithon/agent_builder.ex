defmodule Maraithon.AgentBuilder do
  @moduledoc """
  Shared launch defaults, guidance, and validation for agent builder surfaces.
  """

  alias Maraithon.Agents.Agent

  @default_prompt "You are a helpful assistant that watches for events and responds thoughtfully."
  @default_tools "read_file,search_files,http_get"

  @launch_defaults %{
    "behavior" => "prompt_agent",
    "name" => "",
    "prompt" => @default_prompt,
    "subscriptions" => "",
    "tools" => @default_tools,
    "memory_limit" => "50",
    "budget_llm_calls" => "500",
    "budget_tool_calls" => "1000",
    "config_json" => "",
    "codebase_path" => File.cwd!(),
    "output_path" => "",
    "file_patterns" => "",
    "ignore_patterns" => "",
    "wakeup_interval_ms" => "",
    "check_url" => "",
    "repo_full_name" => "",
    "base_branch" => "main",
    "feature_limit" => "3",
    "email_scan_limit" => "",
    "event_scan_limit" => "",
    "prep_window_hours" => "",
    "max_insights_per_cycle" => "",
    "min_confidence" => "",
    "team_id" => "",
    "channel_scan_limit" => "",
    "dm_scan_limit" => "",
    "lookback_hours" => "",
    "write_plan_files" => "true"
  }

  @behavior_specs [
    %{
      id: "prompt_agent",
      label: "Prompt Agent",
      category: "Flexible",
      summary:
        "General-purpose agent that watches topics, reasons with the LLM, and uses only the tools you allow.",
      inputs: [
        "Direct operator messages from the dashboard",
        "Events published to the topics you subscribe to",
        "Tool results returned from the allowlist below"
      ],
      outputs: [
        "Agent response events",
        "Structured tool calls using the selected allowlist",
        "Long-running context shaped by the memory limit"
      ],
      fields: ~w(prompt subscriptions tools memory_limit),
      defaults: %{},
      requirements: [],
      suggestions: [
        "Start with a narrow prompt and only 2-3 subscriptions so the agent does not drown in noise.",
        "Keep the tool list short. Every extra tool expands the agent's action surface.",
        "Use the memory limit to control how much recent context the prompt agent can revisit."
      ]
    },
    %{
      id: "github_product_planner",
      label: "GitHub Product Planner",
      category: "Planning",
      summary:
        "Reviews one GitHub repository like a PM, proposes the next 2-3 features, and pushes the strongest roadmap ideas to Telegram each day.",
      inputs: [
        "GitHub repository metadata, README, root structure, recent commits, open issues, and open pull requests",
        "The base branch you want reviewed, usually `main`",
        "A daily wakeup cadence that controls when the planner re-evaluates the roadmap"
      ],
      outputs: [
        "Stored roadmap insights with titles, summaries, recommended first milestones, and evidence",
        "Telegram-ready feature suggestions scored for whether they are worth interrupting you about",
        "A daily planning loop grounded in the current state of the selected repository"
      ],
      fields: ~w(repo_full_name base_branch feature_limit wakeup_interval_ms),
      defaults: %{
        "prompt" => "",
        "tools" => "",
        "memory_limit" => "",
        "repo_full_name" => "",
        "base_branch" => "main",
        "feature_limit" => "3",
        "wakeup_interval_ms" => "86400000"
      },
      requirements: [
        %{
          kind: :provider,
          provider: "github",
          label: "GitHub",
          description:
            "Recommended for private repositories and higher GitHub API limits. Public repos can run without it.",
          required?: false
        },
        %{
          kind: :provider,
          provider: "telegram",
          label: "Telegram",
          description:
            "Needed so the planner can push the daily feature shortlist to your linked chat.",
          required?: true
        }
      ],
      suggestions: [
        "Point this at one product repository, not a monorepo grab bag, so the recommendations stay coherent.",
        "Keep `feature_limit` at 2 or 3. A daily shortlist should force prioritization instead of becoming a backlog dump.",
        "Use the default daily cadence first, then tighten it only if you truly want more operator interrupts."
      ]
    },
    %{
      id: "inbox_calendar_advisor",
      label: "Founder Followthrough Agent",
      category: "Workflow",
      summary:
        "Tracks commitments from Gmail and Calendar, verifies whether follow-through happened, and escalates only high-confidence unresolved items.",
      inputs: [
        "Gmail threads where you promised something, agreed on deadlines, or owe a reply",
        "Calendar meetings likely to create follow-up work, especially customer, investor, hiring, and planning meetings",
        "Recent sent email used as evidence to verify whether follow-through already happened"
      ],
      outputs: [
        "Telegram-ready nudges for unresolved commitments",
        "Post-meeting reminders when owners and next steps are still missing",
        "Structured commitment records with commitment, person, source, deadline, status, evidence, and next_action"
      ],
      fields:
        ~w(email_scan_limit event_scan_limit prep_window_hours max_insights_per_cycle min_confidence),
      defaults: %{
        "prompt" => "",
        "tools" => "",
        "memory_limit" => "",
        "wakeup_interval_ms" => "600000",
        "email_scan_limit" => "14",
        "event_scan_limit" => "12",
        "prep_window_hours" => "36",
        "max_insights_per_cycle" => "5",
        "min_confidence" => "0.72"
      },
      requirements: [
        %{
          kind: :provider_service,
          provider: "google",
          service: "gmail",
          label: "Google Gmail",
          description: "Needed to inspect recent inbox activity.",
          required?: true
        },
        %{
          kind: :provider_service,
          provider: "google",
          service: "calendar",
          label: "Google Calendar",
          description: "Needed to inspect important meetings and infer missing follow-ups.",
          required?: true
        }
      ],
      suggestions: [
        "Keep scan limits focused so the agent escalates only the strongest unresolved commitments.",
        "Use `prep_window_hours` as a meeting follow-up window for how far back to inspect unresolved actions.",
        "Raise `min_confidence` if you want even fewer Telegram interruptions."
      ]
    },
    %{
      id: "slack_followthrough_agent",
      label: "Slack Followthrough Agent",
      category: "Workflow",
      summary:
        "Tracks open loops from Slack channels and DMs, then escalates only high-confidence unresolved commitments.",
      inputs: [
        "Slack channel and thread messages where commitments or deadlines were explicitly stated",
        "Personal DM and group DM messages that indicate you owe a reply or promised a follow-up",
        "Recent follow-up evidence in the same channel/thread to verify whether the loop is already closed"
      ],
      outputs: [
        "Actionable unresolved commitment insights scored for urgency and confidence",
        "Structured records with commitment, person, source, deadline, status, evidence, and next_action",
        "Telegram-ready nudges for unresolved loops that should interrupt you now"
      ],
      fields:
        ~w(team_id channel_scan_limit dm_scan_limit lookback_hours max_insights_per_cycle min_confidence wakeup_interval_ms),
      defaults: %{
        "prompt" => "",
        "tools" => "",
        "memory_limit" => "",
        "team_id" => "",
        "channel_scan_limit" => "80",
        "dm_scan_limit" => "50",
        "lookback_hours" => "48",
        "max_insights_per_cycle" => "5",
        "min_confidence" => "0.75",
        "wakeup_interval_ms" => "600000"
      },
      requirements: [
        %{
          kind: :provider_service,
          provider: "slack",
          service: "channels",
          label: "Slack Channels",
          description: "Needed to inspect channel context and detect stated commitments.",
          required?: true
        },
        %{
          kind: :provider_service,
          provider: "slack",
          service: "dms",
          label: "Slack Personal DMs",
          description: "Needed to scan direct messages and private follow-through loops.",
          required?: true
        }
      ],
      suggestions: [
        "Keep channel and DM scan limits bounded so only the strongest unresolved commitments are escalated.",
        "Set `team_id` when multiple Slack workspaces are connected and you want one workspace per agent.",
        "Raise `min_confidence` if you want fewer interruptions and only the clearest open loops."
      ]
    },
    %{
      id: "codebase_advisor",
      label: "Codebase Advisor",
      category: "Code Review",
      summary:
        "Walks a repository file by file and writes concrete review recommendations to a markdown report.",
      inputs: [
        "Files discovered under the selected codebase path",
        "Include and ignore patterns that define the review surface",
        "A wakeup interval that controls batch review pacing"
      ],
      outputs: [
        "A `RECOMMENDATIONS.md` report that accumulates review findings",
        "Progress notes as each file review completes",
        "Structured architecture, reliability, and testing feedback"
      ],
      fields: ~w(codebase_path output_path file_patterns ignore_patterns wakeup_interval_ms),
      defaults: %{
        "prompt" => "",
        "tools" => "",
        "memory_limit" => "",
        "codebase_path" => File.cwd!(),
        "output_path" => Path.join(File.cwd!(), "RECOMMENDATIONS.md"),
        "file_patterns" => "**/*.ex,**/*.exs,**/*.js,**/*.ts,**/*.py,**/*.go",
        "ignore_patterns" => "deps/**,_build/**,node_modules/**,.git/**,*.min.js,vendor/**",
        "wakeup_interval_ms" => "3600000"
      },
      requirements: [
        %{
          kind: :directory,
          field: "codebase_path",
          label: "Codebase path",
          description: "The runtime host must be able to read this directory.",
          required?: true
        },
        %{
          kind: :parent_directory,
          field: "output_path",
          label: "Recommendations output path",
          description: "The parent directory must exist so Maraithon can write the report.",
          required?: true
        }
      ],
      suggestions: [
        "Start on one repository root and tighten the ignore patterns before widening the scan surface.",
        "Use a slower wakeup interval for large repositories so reviews do not pile up too quickly.",
        "Point the output path into a tracked workspace if you want to review the markdown report in git."
      ]
    },
    %{
      id: "repo_planner",
      label: "Repo Planner",
      category: "Planning",
      summary:
        "Indexes repository entry points, then turns operator tasks into implementation plans and optional plan files.",
      inputs: [
        "Repository entry points and source files under the chosen codebase path",
        "Direct planning requests sent to the running agent",
        "File patterns, ignore patterns, and plan-writing preferences"
      ],
      outputs: [
        "Implementation plans grounded in the indexed codebase",
        "Optional markdown plan files under the output path",
        "Indexing and planning progress notes"
      ],
      fields:
        ~w(codebase_path output_path file_patterns ignore_patterns wakeup_interval_ms write_plan_files),
      defaults: %{
        "prompt" => "",
        "tools" => "",
        "memory_limit" => "",
        "codebase_path" => File.cwd!(),
        "output_path" => Path.join(File.cwd!(), "PLANS"),
        "file_patterns" => "**/*.ex,**/*.exs,**/*.js,**/*.ts,**/*.py,**/*.go,**/*.rs",
        "ignore_patterns" =>
          "deps/**,_build/**,node_modules/**,.git/**,*.min.js,vendor/**,dist/**,build/**",
        "wakeup_interval_ms" => "30000",
        "write_plan_files" => "true"
      },
      requirements: [
        %{
          kind: :directory,
          field: "codebase_path",
          label: "Codebase path",
          description: "The runtime host must be able to index this directory.",
          required?: true
        },
        %{
          kind: :parent_directory,
          field: "output_path",
          label: "Plan output path",
          description: "The parent directory must exist when plan files are enabled.",
          required?: true
        }
      ],
      suggestions: [
        "Let the planner finish indexing before sending the first planning request.",
        "Keep plan-writing enabled if you want durable artifacts that can be reviewed outside the UI.",
        "Short wakeup intervals feel responsive, but they also cause the planner to re-check for work more often."
      ]
    },
    %{
      id: "watchdog_summarizer",
      label: "Watchdog Summarizer",
      category: "Monitoring",
      summary:
        "Performs lightweight heartbeat summaries and can optionally hit one URL on a fixed cadence.",
      inputs: [
        "Scheduled wakeups on the chosen interval",
        "Optional HTTP checks against a single URL",
        "Current budget state and runtime timing context"
      ],
      outputs: [
        "Short health and activity summaries",
        "Optional URL availability notes",
        "A low-touch monitoring loop with minimal setup"
      ],
      fields: ~w(check_url wakeup_interval_ms),
      defaults: %{
        "prompt" => "",
        "tools" => "",
        "memory_limit" => "",
        "check_url" => "",
        "wakeup_interval_ms" => "1800000"
      },
      requirements: [],
      suggestions: [
        "Leave the URL blank if you only want heartbeat summaries.",
        "A 30-minute wakeup interval is a good default for passive monitoring.",
        "Use this template when you want lightweight health notes, not deep analysis."
      ]
    }
  ]

  @behavior_spec_aliases %{
    "founder_followthrough_agent" => "inbox_calendar_advisor"
  }

  @behavior_spec_by_id Map.new(@behavior_specs, &{&1.id, &1})

  def behavior_specs, do: @behavior_specs

  def behavior_spec(id) when is_binary(id) do
    id
    |> resolve_behavior_id()
    |> then(&Map.get(@behavior_spec_by_id, &1, hd(@behavior_specs)))
  end

  def default_launch_params, do: launch_params_for_behavior("prompt_agent")

  def launch_params_for_behavior(id) when is_binary(id) do
    spec = behavior_spec(id)

    @launch_defaults
    |> Map.merge(spec.defaults)
    |> Map.put("behavior", id)
  end

  def normalize_launch_params(params) when is_map(params) do
    behavior =
      case Map.get(params, "behavior", @launch_defaults["behavior"]) do
        value when is_binary(value) and value != "" -> value
        _ -> @launch_defaults["behavior"]
      end

    defaults = launch_params_for_behavior(behavior)

    Enum.reduce(defaults, %{}, fn {key, default}, acc ->
      value =
        case Map.get(params, key, default) do
          nil -> default
          value -> to_string(value)
        end

      Map.put(acc, key, String.trim(value))
    end)
  end

  def normalize_launch_params(_params), do: default_launch_params()

  def launch_params_from_agent(%Agent{} = agent) do
    config = agent.config || %{}
    budget = config["budget"] || %{}
    behavior = agent.behavior

    launch_params_for_behavior(behavior)
    |> Map.merge(%{
      "behavior" => behavior,
      "name" => config["name"] || "",
      "prompt" => config["prompt"] || "",
      "subscriptions" => Enum.join(config["subscribe"] || [], ","),
      "tools" => Enum.join(config["tools"] || [], ","),
      "memory_limit" => stringify(config["memory_limit"]),
      "budget_llm_calls" => stringify(budget["llm_calls"] || 500),
      "budget_tool_calls" => stringify(budget["tool_calls"] || 1000),
      "config_json" => extra_config_json(config, behavior),
      "codebase_path" =>
        config["codebase_path"] || launch_params_for_behavior(behavior)["codebase_path"],
      "output_path" =>
        config["output_path"] || launch_params_for_behavior(behavior)["output_path"],
      "file_patterns" => Enum.join(config["file_patterns"] || [], ","),
      "ignore_patterns" => Enum.join(config["ignore_patterns"] || [], ","),
      "wakeup_interval_ms" => stringify(config["wakeup_interval_ms"]),
      "check_url" => config["check_url"] || "",
      "repo_full_name" => config["repo_full_name"] || "",
      "base_branch" =>
        config["base_branch"] || launch_params_for_behavior(behavior)["base_branch"],
      "feature_limit" =>
        stringify(
          config["feature_limit"] || launch_params_for_behavior(behavior)["feature_limit"]
        ),
      "email_scan_limit" => stringify(config["email_scan_limit"]),
      "event_scan_limit" => stringify(config["event_scan_limit"]),
      "prep_window_hours" => stringify(config["prep_window_hours"]),
      "max_insights_per_cycle" => stringify(config["max_insights_per_cycle"]),
      "min_confidence" => stringify(config["min_confidence"]),
      "team_id" => config["team_id"] || "",
      "channel_scan_limit" => stringify(config["channel_scan_limit"]),
      "dm_scan_limit" => stringify(config["dm_scan_limit"]),
      "lookback_hours" => stringify(config["lookback_hours"]),
      "write_plan_files" => stringify(Map.get(config, "write_plan_files", true))
    })
  end

  def build_start_params(launch, user_id) when is_binary(user_id) do
    launch = normalize_launch_params(launch)
    behavior = launch["behavior"]
    resolved_behavior = resolve_behavior_id(behavior)

    cond do
      behavior == "" ->
        {:error, "Choose a template before creating the agent."}

      is_nil(Map.get(@behavior_spec_by_id, resolved_behavior)) ->
        {:error, "Unknown behavior: #{behavior}"}

      true ->
        with {:ok, llm_calls} <-
               parse_positive_integer(launch["budget_llm_calls"], "LLM call budget"),
             {:ok, tool_calls} <-
               parse_positive_integer(launch["budget_tool_calls"], "Tool call budget"),
             {:ok, extra_config} <- parse_optional_config_json(launch["config_json"]),
             {:ok, config} <- build_behavior_config(resolved_behavior, launch, user_id) do
          {:ok,
           %{
             "user_id" => user_id,
             "behavior" => behavior,
             "config" => Map.merge(config, extra_config),
             "budget" => %{"llm_calls" => llm_calls, "tool_calls" => tool_calls}
           }}
        end
    end
  end

  def build_start_params(_launch, _user_id), do: {:error, "User is required"}

  defp build_behavior_config("prompt_agent", launch, _user_id) do
    with {:ok, prompt} <- require_present(launch["prompt"], "Prompt"),
         {:ok, memory_limit} <- parse_positive_integer(launch["memory_limit"], "Memory limit") do
      {:ok,
       %{
         "name" => launch_name(launch),
         "prompt" => prompt,
         "subscribe" => parse_csv(launch["subscriptions"]),
         "tools" => parse_csv(launch["tools"]),
         "memory_limit" => memory_limit
       }}
    end
  end

  defp build_behavior_config("codebase_advisor", launch, _user_id) do
    with {:ok, codebase_path} <- validate_directory(launch["codebase_path"], "Codebase path"),
         {:ok, output_path} <-
           validate_output_parent(launch["output_path"], "Recommendations output path"),
         {:ok, wakeup_interval_ms} <-
           parse_positive_integer(launch["wakeup_interval_ms"], "Wakeup interval") do
      {:ok,
       %{
         "name" => launch_name(launch),
         "codebase_path" => codebase_path,
         "output_path" => output_path,
         "file_patterns" => parse_csv(launch["file_patterns"]),
         "ignore_patterns" => parse_csv(launch["ignore_patterns"]),
         "wakeup_interval_ms" => wakeup_interval_ms
       }}
    end
  end

  defp build_behavior_config("repo_planner", launch, _user_id) do
    with {:ok, codebase_path} <- validate_directory(launch["codebase_path"], "Codebase path"),
         {:ok, output_path} <- validate_output_parent(launch["output_path"], "Plan output path"),
         {:ok, wakeup_interval_ms} <-
           parse_positive_integer(launch["wakeup_interval_ms"], "Wakeup interval"),
         {:ok, write_plan_files} <-
           parse_boolean(launch["write_plan_files"], "Write plan files") do
      {:ok,
       %{
         "name" => launch_name(launch),
         "codebase_path" => codebase_path,
         "output_path" => output_path,
         "file_patterns" => parse_csv(launch["file_patterns"]),
         "ignore_patterns" => parse_csv(launch["ignore_patterns"]),
         "wakeup_interval_ms" => wakeup_interval_ms,
         "write_plan_files" => write_plan_files
       }}
    end
  end

  defp build_behavior_config("watchdog_summarizer", launch, _user_id) do
    with {:ok, wakeup_interval_ms} <-
           parse_positive_integer(launch["wakeup_interval_ms"], "Wakeup interval") do
      {:ok,
       %{
         "name" => launch_name(launch),
         "check_url" => empty_to_nil(launch["check_url"]),
         "wakeup_interval_ms" => wakeup_interval_ms
       }}
      |> drop_nil_values()
    end
  end

  defp build_behavior_config("github_product_planner", launch, user_id) do
    with {:ok, repo_full_name} <- validate_repo_full_name(launch["repo_full_name"]),
         {:ok, feature_limit} <-
           parse_integer_in_range(launch["feature_limit"], "Feature limit", 2, 3),
         {:ok, wakeup_interval_ms} <-
           parse_positive_integer(launch["wakeup_interval_ms"], "Wakeup interval") do
      {:ok,
       %{
         "name" => launch_name(launch),
         "user_id" => user_id,
         "repo_full_name" => repo_full_name,
         "base_branch" => normalize_branch(launch["base_branch"]),
         "feature_limit" => feature_limit,
         "wakeup_interval_ms" => wakeup_interval_ms
       }}
    end
  end

  defp build_behavior_config("inbox_calendar_advisor", launch, user_id) do
    with {:ok, email_scan_limit} <-
           parse_positive_integer(launch["email_scan_limit"], "Email scan limit"),
         {:ok, event_scan_limit} <-
           parse_positive_integer(launch["event_scan_limit"], "Event scan limit"),
         {:ok, prep_window_hours} <-
           parse_positive_integer(launch["prep_window_hours"], "Prep window hours"),
         {:ok, max_insights_per_cycle} <-
           parse_positive_integer(launch["max_insights_per_cycle"], "Max insights per cycle"),
         {:ok, min_confidence} <-
           parse_float_in_range(launch["min_confidence"], "Minimum confidence", 0.0, 1.0) do
      {:ok,
       %{
         "name" => launch_name(launch),
         "user_id" => user_id,
         "email_scan_limit" => email_scan_limit,
         "event_scan_limit" => event_scan_limit,
         "prep_window_hours" => prep_window_hours,
         "max_insights_per_cycle" => max_insights_per_cycle,
         "min_confidence" => min_confidence
       }}
    end
  end

  defp build_behavior_config("slack_followthrough_agent", launch, user_id) do
    with {:ok, channel_scan_limit} <-
           parse_positive_integer(launch["channel_scan_limit"], "Channel scan limit"),
         {:ok, dm_scan_limit} <-
           parse_positive_integer(launch["dm_scan_limit"], "DM scan limit"),
         {:ok, lookback_hours} <-
           parse_positive_integer(launch["lookback_hours"], "Lookback window"),
         {:ok, max_insights_per_cycle} <-
           parse_positive_integer(launch["max_insights_per_cycle"], "Max insights per cycle"),
         {:ok, min_confidence} <-
           parse_float_in_range(launch["min_confidence"], "Minimum confidence", 0.0, 1.0),
         {:ok, wakeup_interval_ms} <-
           parse_positive_integer(launch["wakeup_interval_ms"], "Wakeup interval") do
      {:ok,
       %{
         "name" => launch_name(launch),
         "user_id" => user_id,
         "team_id" => empty_to_nil(launch["team_id"]),
         "channel_scan_limit" => channel_scan_limit,
         "dm_scan_limit" => dm_scan_limit,
         "lookback_hours" => lookback_hours,
         "max_insights_per_cycle" => max_insights_per_cycle,
         "min_confidence" => min_confidence,
         "wakeup_interval_ms" => wakeup_interval_ms
       }}
      |> drop_nil_values()
    end
  end

  defp build_behavior_config("founder_followthrough_agent", launch, user_id) do
    build_behavior_config("inbox_calendar_advisor", launch, user_id)
  end

  defp build_behavior_config(behavior, launch, _user_id) do
    {:ok, %{"name" => launch_name(launch), "prompt" => launch["prompt"], "behavior" => behavior}}
  end

  defp launch_name(%{"name" => "" = _blank, "behavior" => behavior}) do
    "#{behavior}-#{System.unique_integer([:positive])}"
  end

  defp launch_name(%{"name" => name}) when is_binary(name), do: name

  defp require_present("", field_name), do: {:error, "#{field_name} is required"}
  defp require_present(value, _field_name), do: {:ok, value}

  defp parse_positive_integer(value, field_name) do
    case Integer.parse(value || "") do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, "#{field_name} must be a positive integer"}
    end
  end

  defp parse_float_in_range(value, field_name, min, max) do
    case Float.parse(value || "") do
      {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
      _ -> {:error, "#{field_name} must be between #{min} and #{max}"}
    end
  end

  defp parse_integer_in_range(value, field_name, min, max) do
    case Integer.parse(value || "") do
      {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
      _ -> {:error, "#{field_name} must be between #{min} and #{max}"}
    end
  end

  defp parse_boolean(value, _field_name) when value in ["true", "TRUE", "1"], do: {:ok, true}
  defp parse_boolean(value, _field_name) when value in ["false", "FALSE", "0"], do: {:ok, false}
  defp parse_boolean(_value, field_name), do: {:error, "#{field_name} must be true or false"}

  defp parse_optional_config_json(""), do: {:ok, %{}}

  defp parse_optional_config_json(json) do
    case Jason.decode(json) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      {:ok, _} ->
        {:error, "Additional config JSON must decode to an object"}

      {:error, _} ->
        {:error, "Additional config JSON is invalid"}
    end
  end

  defp validate_directory(value, field_name) do
    path = value |> to_string() |> String.trim()

    cond do
      path == "" ->
        {:error, "#{field_name} is required"}

      File.dir?(path) ->
        {:ok, path}

      true ->
        {:error, "#{field_name} must point to an existing directory"}
    end
  end

  defp validate_output_parent(value, field_name) do
    path = value |> to_string() |> String.trim()

    cond do
      path == "" ->
        {:error, "#{field_name} is required"}

      File.dir?(Path.dirname(path)) ->
        {:ok, path}

      true ->
        {:error, "#{field_name} parent directory must exist"}
    end
  end

  defp validate_repo_full_name(value) do
    repo_full_name =
      value
      |> to_string()
      |> String.trim()

    case String.split(repo_full_name, "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, repo_full_name}
      _ -> {:error, "Repository must be in `owner/repo` format"}
    end
  end

  defp normalize_branch(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "main"
      branch -> branch
    end
  end

  defp normalize_branch(_value), do: "main"

  defp parse_csv(""), do: []

  defp parse_csv(values) when is_binary(values) do
    values
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_csv(_values), do: []

  defp extra_config_json(config, behavior) do
    extra =
      config
      |> Map.drop(known_config_keys(behavior) ++ ["budget", "_last_message"])

    if extra == %{} do
      ""
    else
      Jason.encode!(extra, pretty: true)
    end
  end

  defp known_config_keys("prompt_agent"),
    do: ["name", "prompt", "subscribe", "tools", "memory_limit"]

  defp known_config_keys("codebase_advisor"),
    do: [
      "name",
      "codebase_path",
      "output_path",
      "file_patterns",
      "ignore_patterns",
      "wakeup_interval_ms"
    ]

  defp known_config_keys("repo_planner"),
    do: [
      "name",
      "codebase_path",
      "output_path",
      "file_patterns",
      "ignore_patterns",
      "wakeup_interval_ms",
      "write_plan_files"
    ]

  defp known_config_keys("watchdog_summarizer"),
    do: ["name", "check_url", "wakeup_interval_ms"]

  defp known_config_keys("github_product_planner"),
    do: [
      "name",
      "user_id",
      "repo_full_name",
      "base_branch",
      "feature_limit",
      "wakeup_interval_ms"
    ]

  defp known_config_keys("inbox_calendar_advisor"),
    do: [
      "name",
      "user_id",
      "email_scan_limit",
      "event_scan_limit",
      "prep_window_hours",
      "max_insights_per_cycle",
      "min_confidence"
    ]

  defp known_config_keys("slack_followthrough_agent"),
    do: [
      "name",
      "user_id",
      "team_id",
      "channel_scan_limit",
      "dm_scan_limit",
      "lookback_hours",
      "max_insights_per_cycle",
      "min_confidence",
      "wakeup_interval_ms"
    ]

  defp known_config_keys("founder_followthrough_agent"),
    do: known_config_keys("inbox_calendar_advisor")

  defp known_config_keys(_behavior), do: ["name", "prompt"]

  defp stringify(nil), do: ""
  defp stringify(value) when is_boolean(value), do: to_string(value)
  defp stringify(value), do: to_string(value)

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp drop_nil_values({:ok, map}) when is_map(map),
    do: {:ok, Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()}

  defp drop_nil_values(other), do: other

  defp resolve_behavior_id(id) when is_binary(id) do
    Map.get(@behavior_spec_aliases, id, id)
  end
end
