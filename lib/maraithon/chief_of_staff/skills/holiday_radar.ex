defmodule Maraithon.ChiefOfStaff.Skills.HolidayRadar do
  @moduledoc """
  Daily AI-driven holiday planning radar for the Chief of Staff.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ChiefOfStaff.HolidayCalendar
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Projects
  alias Maraithon.Projects.Project
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @default_timezone_offset_hours -5
  @default_lookahead_days 120
  @default_max_holidays 18
  @default_max_projects 10
  @default_max_todos 24
  @default_review_hour_local 11

  @impl true
  def id, do: "holiday_radar"

  @impl true
  def label, do: "Holiday radar"

  @impl true
  def description,
    do: "Surfaces upcoming family, holiday, and gift reminders before they become urgent."

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "lookahead_days" => @default_lookahead_days,
      "max_holidays" => @default_max_holidays,
      "max_projects" => @default_max_projects,
      "max_todos" => @default_max_todos,
      "review_hour_local" => @default_review_hour_local
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Needed to deliver proactive holiday planning nudges.",
        required?: true
      }
    ]
  end

  @impl true
  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    case get_in(context, [:trigger, :type]) do
      :message -> false
      :pubsub_event -> false
      _ -> true
    end
  end

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      lookahead_days:
        integer_in_range(config["lookahead_days"], @default_lookahead_days, 14, 365),
      max_holidays: integer_in_range(config["max_holidays"], @default_max_holidays, 1, 24),
      max_projects: integer_in_range(config["max_projects"], @default_max_projects, 1, 20),
      max_todos: integer_in_range(config["max_todos"], @default_max_todos, 1, 50),
      review_hour_local:
        integer_in_range(config["review_hour_local"], @default_review_hour_local, 0, 23),
      pending_review_key: nil,
      pending_holidays: %{},
      last_review_key: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    timestamp = context[:timestamp] || DateTime.utc_now()

    cond do
      is_nil(user_id) ->
        {:idle, %{state | user_id: user_id}}

      not scheduled_trigger?(context) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        local_now = shift_local(timestamp, state.timezone_offset_hours)
        review_key = Date.to_iso8601(DateTime.to_date(local_now))

        if state.last_review_key == review_key do
          {:idle, %{state | user_id: user_id}}
        else
          holidays =
            HolidayCalendar.upcoming(DateTime.to_date(local_now),
              lookahead_days: state.lookahead_days
            )
            |> Enum.take(state.max_holidays)

          if holidays == [] do
            {:idle, %{state | user_id: user_id, last_review_key: review_key}}
          else
            projects =
              Projects.list_projects(user_id: user_id, status: "active")
              |> Enum.take(state.max_projects)

            open_todos =
              Todos.list_open_for_user(user_id, limit: state.max_todos)
              |> Enum.take(state.max_todos)

            holiday_todos =
              Todos.list_recent_for_user(user_id, limit: state.max_todos)
              |> Enum.filter(&(&1.source == "chief_of_staff_holiday"))
              |> Enum.take(12)

            recent_briefs =
              Briefs.list_recent_for_user(user_id, limit: 16)
              |> Enum.filter(&holiday_brief?/1)
              |> Enum.take(8)

            calendar_events =
              context
              |> Map.get(:source_bundle, %{})
              |> SourceBundle.calendar_events()
              |> upcoming_calendar_events(timestamp, state.lookahead_days)
              |> Enum.take(16)

            {:effect,
             {:llm_call,
              llm_params(
                holidays,
                projects,
                open_todos,
                holiday_todos,
                recent_briefs,
                calendar_events,
                local_now,
                context
              )},
             %{
               state
               | user_id: user_id,
                 pending_review_key: review_key,
                 pending_holidays: Map.new(holidays, &{&1["id"], compact_holiday(&1)})
             }}
          end
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    review_key =
      state.pending_review_key ||
        (context[:timestamp] || DateTime.utc_now())
        |> shift_local(state.timezone_offset_hours)
        |> DateTime.to_date()
        |> Date.to_iso8601()

    with {:ok, content} <- response_content(response),
         {:ok, decoded} <- decode_json_payload(content),
         {:ok, persisted} <- persist_notifications(decoded, state, context) do
      next_state = clear_pending(%{state | last_review_key: review_key})

      case persisted.briefs do
        [] ->
          {:idle, next_state}

        briefs ->
          {:emit,
           {:briefs_recorded,
            %{
              count: length(briefs),
              user_id: state.user_id,
              cadences: Enum.map(briefs, & &1.cadence),
              todo_count: length(persisted.todos)
            }}, next_state}
      end
    else
      _ ->
        {:emit, {:brief_error, %{reason: "holiday_radar_invalid_json", attempted_count: 1}},
         clear_pending(state)}
    end
  end

  def handle_effect_result({:tool_call, _result}, state, _context),
    do: {:idle, clear_pending(state)}

  # Without this callback the behavior's generic effect-error path skips the
  # skill without clearing pending state, leaving pending_holidays to be
  # ETF-serialized into every snapshot.
  @impl true
  def handle_effect_error(:llm_call, reason, state, context) do
    handle_effect_result(
      {:llm_call,
       %{
         content: "",
         error: Maraithon.Redaction.error_summary(reason),
         finish_reason: "error"
       }},
      state,
      context
    )
  end

  def handle_effect_error(_effect_type, _reason, state, _context),
    do: {:idle, clear_pending(state)}

  defp response_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp response_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp response_content(content) when is_binary(content), do: {:ok, content}
  defp response_content(_response), do: {:error, :holiday_radar_missing_llm_content}

  @impl true
  def next_wakeup(state) do
    now = DateTime.utc_now()
    local_now = shift_local(now, state.timezone_offset_hours)
    local_date = DateTime.to_date(local_now)

    target_local =
      local_date
      |> holiday_review_local_datetime(state)
      |> case do
        %DateTime{} = candidate ->
          if DateTime.compare(local_now, candidate) == :lt do
            candidate
          else
            holiday_review_local_datetime(Date.add(local_date, 1), state)
          end

        _ ->
          holiday_review_local_datetime(Date.add(local_date, 1), state)
      end

    {:absolute, shift_utc(target_local, state.timezone_offset_hours)}
  end

  defp persist_notifications(decoded, state, context) when is_map(decoded) do
    reviewed_at = context[:timestamp] || DateTime.utc_now()

    notifications =
      decoded
      |> Map.get("notifications", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    {brief_attrs, todo_attrs} =
      Enum.reduce(notifications, {[], []}, fn attrs, {brief_acc, todo_acc} ->
        case notification_attrs(attrs, state.pending_holidays, reviewed_at) do
          {:ok, brief, nil} ->
            {[brief | brief_acc], todo_acc}

          {:ok, brief, todo} ->
            {[brief | brief_acc], [todo | todo_acc]}

          :skip ->
            {brief_acc, todo_acc}
        end
      end)

    with {:ok, todos} <- persist_holiday_todos(state.user_id, todo_attrs) do
      Repo.transaction(fn ->
        briefs =
          case brief_attrs do
            [] ->
              []

            attrs_list ->
              Enum.reverse(attrs_list)
              |> Enum.reduce([], fn attrs, acc ->
                case Briefs.record(state.user_id, context.agent_id, attrs) do
                  {:ok, brief} -> [brief | acc]
                  {:error, reason} -> Repo.rollback(reason)
                end
              end)
              |> Enum.reverse()
          end

        %{todos: todos, briefs: briefs}
      end)
      |> case do
        {:ok, persisted} -> {:ok, persisted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist_notifications(_decoded, _state, _context), do: {:error, :invalid_payload}

  defp persist_holiday_todos(_user_id, []), do: {:ok, []}

  defp persist_holiday_todos(user_id, attrs_list) do
    case Maraithon.Todos.DeferredIngestion.enqueue(user_id, Enum.reverse(attrs_list),
           source: "chief_of_staff_holiday"
         ) do
      {:ok, result} -> {:ok, result.todos}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notification_attrs(attrs, pending_holidays, reviewed_at) do
    with holiday_id when is_binary(holiday_id) <- normalize_string(Map.get(attrs, "holiday_id")),
         holiday when is_map(holiday) <- Map.get(pending_holidays, holiday_id),
         true <- notify?(attrs),
         title when is_binary(title) <- normalize_string(Map.get(attrs, "title")),
         summary when is_binary(summary) <- normalize_string(Map.get(attrs, "summary")),
         body when is_binary(body) <- normalize_string(Map.get(attrs, "body")) do
      phase_key = normalize_phase_key(Map.get(attrs, "phase_key")) || "current"
      holiday_name = holiday["name"]
      holiday_date = holiday["date"]
      priority = normalize_priority(Map.get(attrs, "priority"), 72)
      confidence = normalize_confidence(Map.get(attrs, "confidence"))
      reasoning = normalize_string(Map.get(attrs, "reasoning"))
      attention_mode = normalize_attention_mode(Map.get(attrs, "attention_mode")) || "act_now"
      next_action = holiday_next_action(attrs, body)
      title = holiday_user_title(title, holiday_name, next_action)
      summary = holiday_user_summary(summary, body, next_action)

      metadata =
        %{
          "brief_type" => "holiday_radar",
          "holiday_id" => holiday_id,
          "holiday_name" => holiday_name,
          "holiday_date" => holiday_date,
          "holiday_phase_key" => phase_key,
          "holiday_confidence" => confidence,
          "holiday_reasoning" => reasoning,
          "holiday_region" => holiday["region"]
        }
        |> compact_map()

      brief = %{
        "cadence" => "holiday_radar",
        "scheduled_for" => reviewed_at,
        "dedupe_key" => "brief:holiday_radar:#{holiday_id}:#{phase_key}",
        "title" => title,
        "summary" => summary,
        "body" => holiday_brief_body(holiday_name, summary, body, next_action),
        "metadata" => metadata
      }

      todo =
        if Map.get(attrs, "create_todo") == true or is_map(Map.get(attrs, "todo")) do
          todo_attrs(
            Map.get(attrs, "todo"),
            holiday,
            phase_key,
            title,
            summary,
            priority,
            attention_mode,
            confidence,
            reasoning,
            next_action,
            reviewed_at
          )
        end

      {:ok, brief, todo}
    else
      _ -> :skip
    end
  end

  defp todo_attrs(
         todo_attrs,
         holiday,
         phase_key,
         fallback_title,
         fallback_summary,
         fallback_priority,
         fallback_attention_mode,
         confidence,
         reasoning,
         fallback_next_action,
         reviewed_at
       ) do
    todo_map = if is_map(todo_attrs), do: todo_attrs, else: %{}

    %{
      "source" => "chief_of_staff_holiday",
      "kind" => "general",
      "attention_mode" =>
        normalize_attention_mode(Map.get(todo_map, "attention_mode")) || fallback_attention_mode,
      "title" => safe_user_sentence(Map.get(todo_map, "title")) || fallback_title,
      "summary" => safe_user_sentence(Map.get(todo_map, "summary")) || fallback_summary,
      "next_action" =>
        safe_user_sentence(Map.get(todo_map, "next_action")) || fallback_next_action,
      "priority" => normalize_priority(Map.get(todo_map, "priority"), fallback_priority),
      "source_item_id" => "holiday:#{holiday["id"]}:#{phase_key}",
      "source_occurred_at" => reviewed_at,
      "dedupe_key" => "holiday:#{holiday["id"]}:#{phase_key}",
      "metadata" =>
        %{
          "holiday_id" => holiday["id"],
          "holiday_name" => holiday["name"],
          "holiday_date" => holiday["date"],
          "holiday_phase_key" => phase_key,
          "holiday_confidence" => confidence,
          "holiday_reasoning" => reasoning,
          "holiday_region" => holiday["region"]
        }
        |> compact_map()
    }
  end

  defp compact_holiday(holiday) when is_map(holiday) do
    region =
      normalize_string(holiday["region"]) ||
        holiday["markets"] |> List.wrap() |> Enum.find(&is_binary/1)

    %{
      "id" => normalize_string(holiday["id"]),
      "name" => normalize_string(holiday["name"]),
      "date" => normalize_string(holiday["date"]),
      "region" => region
    }
    |> compact_map()
  end

  defp llm_params(
         holidays,
         projects,
         open_todos,
         holiday_todos,
         recent_briefs,
         calendar_events,
         local_now,
         context
       ) do
    %{
      "messages" => [
        %{
          "role" => "user",
          "content" =>
            build_prompt(
              holidays,
              projects,
              open_todos,
              holiday_todos,
              recent_briefs,
              calendar_events,
              local_now,
              context
            )
        }
      ],
      "max_tokens" => 2_000,
      "temperature" => 0.2
    }
  end

  defp build_prompt(
         holidays,
         projects,
         open_todos,
         holiday_todos,
         recent_briefs,
         calendar_events,
         local_now,
         context
       ) do
    holidays_json = Jason.encode!(holidays)
    projects_json = Jason.encode!(Enum.map(projects, &serialize_project_for_prompt/1))
    open_todos_json = Jason.encode!(Enum.map(open_todos, &serialize_todo_for_prompt/1))
    holiday_todos_json = Jason.encode!(Enum.map(holiday_todos, &serialize_todo_for_prompt/1))
    recent_briefs_json = Jason.encode!(Enum.map(recent_briefs, &serialize_brief_for_prompt/1))
    calendar_events_json = Jason.encode!(calendar_events)
    user_memory_json = Jason.encode!(Map.get(context, :user_memory, %{}))

    """
    You are Maraithon's Chief of Staff running a holiday planning radar pass.
    Local time: #{DateTime.to_iso8601(local_now)}

    Durable user memory JSON:
    #{user_memory_json}

    Upcoming holiday candidates JSON:
    #{holidays_json}

    Active projects JSON:
    #{projects_json}

    Open todos JSON:
    #{open_todos_json}

    Existing holiday todos JSON:
    #{holiday_todos_json}

    Recent holiday briefs JSON:
    #{recent_briefs_json}

    Nearby calendar events JSON:
    #{calendar_events_json}

    Task:
    - Decide whether the user needs a proactive holiday nudge right now.
    - Use the actual evidence in memory, projects, todos, recent holiday actions, and calendar context.
    - If a holiday probably does not matter for this user this year, skip it.
    - If something already appears handled, do not duplicate it.
    - When you do notify, make it concrete and useful. Dinner reservations, travel coordination, gifts, hosting, and family planning are all fair suggestions when they fit the holiday.
    - User-visible title, summary, body, and todo copy must lead with the concrete next action. Do not mention confidence, scores, thresholds, model reasoning, JSON, or this radar pass in user-visible fields.
    - Use intelligence rather than rigid rules. Make a judgment from the evidence and timing.
    - Prefer a small number of high-signal nudges instead of a long list.
    - Never invent holidays, projects, calendar events, briefs, or todos.

    Return ONLY valid JSON shaped like:
    {
      "summary": "short operator summary",
      "notifications": [
        {
          "holiday_id": "existing holiday id",
          "phase_key": "short stable phase key",
          "should_notify": true,
          "title": "brief title",
          "summary": "short summary",
          "body": "concrete body with why now and what to do",
          "priority": 0,
          "confidence": 0.0,
          "reasoning": "short explanation",
          "attention_mode": "act_now" | "monitor",
          "create_todo": true,
          "todo": {
            "title": "todo title",
            "summary": "todo summary",
            "next_action": "next action",
            "priority": 0,
            "attention_mode": "act_now" | "monitor"
          }
        }
      ]
    }
    """
  end

  defp serialize_project_for_prompt(%Project{} = project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "summary" => project.summary,
      "description" => project.description,
      "metadata" =>
        (project.metadata || %{})
        |> Map.take([
          "life_domain",
          "life_domain_confidence",
          "life_domain_reasoning",
          "life_domain_needs_confirmation"
        ])
    }
  end

  defp serialize_todo_for_prompt(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "source" => todo.source,
      "status" => todo.status,
      "attention_mode" => todo.attention_mode,
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "priority" => todo.priority,
      "metadata" =>
        (todo.metadata || %{})
        |> Map.take([
          "holiday_id",
          "holiday_name",
          "holiday_date",
          "holiday_phase_key",
          "suggested_project_id",
          "suggested_project_name",
          "suggested_life_domain"
        ])
    }
  end

  defp serialize_brief_for_prompt(%Brief{} = brief) do
    %{
      "id" => brief.id,
      "cadence" => brief.cadence,
      "title" => brief.title,
      "summary" => brief.summary,
      "scheduled_for" => brief.scheduled_for && DateTime.to_iso8601(brief.scheduled_for),
      "metadata" =>
        (brief.metadata || %{})
        |> Map.take([
          "brief_type",
          "holiday_id",
          "holiday_name",
          "holiday_date",
          "holiday_phase_key"
        ])
    }
  end

  defp holiday_brief?(%Brief{metadata: %{"brief_type" => "holiday_radar"}}), do: true
  defp holiday_brief?(%Brief{cadence: "holiday_radar"}), do: true
  defp holiday_brief?(_brief), do: false

  defp holiday_next_action(attrs, body) do
    todo_map = Map.get(attrs, "todo")
    todo_map = if is_map(todo_map), do: todo_map, else: %{}

    safe_user_sentence(Map.get(todo_map, "next_action")) ||
      extracted_action_line(body) ||
      "Review the holiday plan and lock the next concrete step."
  end

  defp holiday_user_title(title, holiday_name, next_action) do
    safe_user_sentence(title) ||
      holiday_fallback_title(holiday_name, next_action)
  end

  defp holiday_fallback_title(holiday_name, next_action) do
    holiday_name = normalize_string(holiday_name)
    action = safe_user_sentence(next_action)

    cond do
      holiday_name && action ->
        truncate_user_text("#{holiday_name}: #{String.trim_trailing(action, ".")}", 90)

      holiday_name ->
        "#{holiday_name} planning"

      action ->
        truncate_user_text(action, 90)

      true ->
        "Holiday planning"
    end
  end

  defp holiday_user_summary(summary, body, next_action) do
    safe_user_sentence(summary) ||
      first_context_line(body) ||
      safe_user_sentence(next_action) ||
      "Review the holiday plan and lock the next concrete step"
  end

  defp holiday_brief_body(holiday_name, summary, body, next_action) do
    why_now = safe_user_sentence(summary) || first_context_line(body)

    context_line =
      body
      |> context_body_lines()
      |> Enum.find(fn line ->
        not same_sentence?(line, why_now) and not same_sentence?(line, next_action)
      end)

    [
      "Action needed#{holiday_label(holiday_name)}: #{sentence(next_action)}",
      why_now && "Why now: #{sentence(why_now)}",
      context_line && "Context: #{sentence(context_line)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp holiday_label(name) when is_binary(name), do: " for #{name}"
  defp holiday_label(_name), do: ""

  defp extracted_action_line(body) do
    body
    |> raw_body_lines()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*(?:do|action|next|suggested next step)\s*:\s*(.+)$/iu, line) do
        [_, action] -> safe_user_sentence(action)
        _ -> nil
      end
    end)
  end

  defp first_context_line(body) do
    body
    |> user_body_lines()
    |> List.first()
  end

  defp context_body_lines(body) do
    body
    |> raw_body_lines()
    |> Enum.reject(&action_line?/1)
    |> Enum.map(&strip_user_label/1)
    |> Enum.map(&safe_user_sentence/1)
    |> Enum.reject(&is_nil/1)
  end

  defp user_body_lines(body) do
    body
    |> raw_body_lines()
    |> Enum.map(&strip_user_label/1)
    |> Enum.map(&safe_user_sentence/1)
    |> Enum.reject(&is_nil/1)
  end

  defp raw_body_lines(body) do
    body
    |> normalize_string()
    |> case do
      nil -> []
      text -> String.split(text, ~r/\n+/u, trim: true)
    end
  end

  defp action_line?(line) when is_binary(line) do
    Regex.match?(~r/^\s*(?:do|action|next|suggested next step)\s*:/iu, line)
  end

  defp action_line?(_line), do: false

  defp strip_user_label(line) do
    String.replace(
      line,
      ~r/^\s*(?:why now|do|action|next|context|suggested next step)\s*:\s*/iu,
      ""
    )
  end

  defp safe_user_sentence(value) do
    value
    |> normalize_string()
    |> case do
      nil ->
        nil

      text ->
        text = String.trim_trailing(text, ".")

        if internal_process_line?(text) do
          nil
        else
          text
        end
    end
  end

  defp internal_process_line?(line) do
    normalized = String.downcase(line)

    Regex.match?(~r/\b\d{1,3}%/u, normalized) or
      Enum.any?(
        [
          "confidence",
          "score",
          "threshold",
          "model",
          "json",
          "heuristic",
          "classified",
          "reasoning",
          "llm",
          "radar pass"
        ],
        &String.contains?(normalized, &1)
      )
  end

  defp same_sentence?(_left, nil), do: false
  defp same_sentence?(nil, _right), do: false

  defp same_sentence?(left, right) when is_binary(left) and is_binary(right) do
    comparable_sentence(left) == comparable_sentence(right)
  end

  defp comparable_sentence(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp sentence(value) do
    value
    |> normalize_string()
    |> case do
      nil -> ""
      text -> String.trim_trailing(text, ".") <> "."
    end
  end

  defp truncate_user_text(nil, _max), do: nil

  defp truncate_user_text(text, max) when is_binary(text) and is_integer(max) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      text
      |> String.slice(0, max - 3)
      |> String.trim()
      |> Kernel.<>("...")
    end
  end

  defp upcoming_calendar_events(events, reference_at, lookahead_days) when is_list(events) do
    latest_at = DateTime.add(reference_at, lookahead_days, :day)

    events
    |> Enum.map(&stringify_keys/1)
    |> Enum.filter(fn event ->
      case event_start_datetime(event) do
        %DateTime{} = start_at ->
          DateTime.compare(start_at, reference_at) != :lt and
            DateTime.compare(start_at, latest_at) != :gt

        _ ->
          false
      end
    end)
    |> Enum.sort_by(fn event ->
      event
      |> event_start_datetime()
      |> DateTime.to_unix(:second)
    end)
    |> Enum.map(fn event ->
      %{
        "id" => event["id"],
        "summary" => event["summary"],
        "start" => normalize_event_time(event["start"]),
        "end" => normalize_event_time(event["end"]),
        "html_link" => event["htmlLink"] || event["html_link"],
        "attendees" => event["attendees"] || []
      }
    end)
  end

  defp upcoming_calendar_events(_events, _reference_at, _lookahead_days), do: []

  defp event_start_datetime(%{"start" => %DateTime{} = datetime}), do: datetime

  defp event_start_datetime(%{"start" => %{"dateTime" => datetime}}) when is_binary(datetime) do
    parse_datetime(datetime)
  end

  defp event_start_datetime(%{"start" => %{"date" => date}}) when is_binary(date) do
    with {:ok, parsed_date} <- Date.from_iso8601(date),
         {:ok, datetime} <- DateTime.new(parsed_date, ~T[12:00:00], "Etc/UTC") do
      datetime
    else
      _ -> nil
    end
  end

  defp event_start_datetime(%{"start" => value}) when is_binary(value), do: parse_datetime(value)
  defp event_start_datetime(_event), do: nil

  defp normalize_event_time(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_event_time(%{"dateTime" => datetime}) when is_binary(datetime), do: datetime
  defp normalize_event_time(%{"date" => date}) when is_binary(date), do: date
  defp normalize_event_time(value) when is_binary(value), do: value
  defp normalize_event_time(_value), do: nil

  defp holiday_review_local_datetime(date, state) do
    minute_offset =
      {state.user_id || "holiday_radar", "holiday_radar"}
      |> :erlang.phash2(37)
      |> Kernel.-(18)

    hour = clamp_hour(state.review_hour_local + div(minute_offset, 60))
    minute = Integer.mod(minute_offset, 60)

    {:ok, datetime} = DateTime.new(date, Time.new!(hour, minute, 0), "Etc/UTC")
    datetime
  end

  defp scheduled_trigger?(context) do
    get_in(context, [:trigger, :type]) in [nil, :wakeup]
  end

  defp clear_pending(state) do
    %{state | pending_review_key: nil, pending_holidays: %{}}
  end

  defp notify?(attrs) do
    case Map.get(attrs, "should_notify") do
      false -> false
      _ -> true
    end
  end

  defp shift_local(%DateTime{} = datetime, offset_hours) do
    DateTime.add(datetime, offset_hours * 3600, :second)
  end

  defp shift_utc(%DateTime{} = datetime, offset_hours) do
    DateTime.add(datetime, offset_hours * -3600, :second)
  end

  defp normalize_phase_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_phase_key(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_phase_key()

  defp normalize_phase_key(_value), do: nil

  defp normalize_attention_mode("monitor"), do: "monitor"
  defp normalize_attention_mode("act_now"), do: "act_now"
  defp normalize_attention_mode(_value), do: nil

  defp normalize_priority(value, default)

  defp normalize_priority(value, _default) when is_integer(value),
    do: clamp_integer(value, 0, 100)

  defp normalize_priority(value, default) when is_float(value) do
    value |> round() |> normalize_priority(default)
  end

  defp normalize_priority(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_priority(parsed, default)
      _ -> default
    end
  end

  defp normalize_priority(_value, default), do: default

  defp normalize_confidence(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> normalize_confidence(parsed)
      _ -> nil
    end
  end

  defp normalize_confidence(_value), do: nil

  defp integer_in_range(value, default, min, max) do
    case value do
      int when is_integer(int) and int >= min and int <= max ->
        int

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {int, ""} when int >= min and int <= max -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, ""} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_keys/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp clamp_integer(value, min, max), do: value |> max(min) |> min(max)
  defp clamp_hour(value), do: clamp_integer(value, 0, 23)

  defp decode_json_payload(content) when is_binary(content) do
    content
    |> json_decode_candidates()
    |> Enum.reduce_while({:error, :invalid_json}, fn candidate, _error ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp decode_json_payload(_content), do: {:error, :invalid_json}

  defp json_decode_candidates(content) do
    trimmed = String.trim(content)

    ([trimmed, strip_markdown_json_fence(trimmed)] ++
       fenced_json_candidates(trimmed) ++ [first_balanced_json_object(trimmed)])
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp strip_markdown_json_fence(content) when is_binary(content) do
    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, content, capture: :all_but_first) do
      [json] -> String.trim(json)
      _ -> content
    end
  end

  defp fenced_json_candidates(content) when is_binary(content) do
    ~r/```(?:json)?\s*(.*?)\s*```/s
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp first_balanced_json_object(content) when is_binary(content) do
    content
    |> String.graphemes()
    |> Enum.reduce_while({:searching, []}, &collect_first_json_object/2)
    |> case do
      {:done, chars} -> chars |> Enum.reverse() |> Enum.join() |> String.trim()
      _ -> nil
    end
  end

  defp collect_first_json_object("{", {:searching, _chars}),
    do: {:cont, {:collecting, 1, false, false, ["{"]}}

  defp collect_first_json_object(_char, {:searching, _chars}), do: {:cont, {:searching, []}}

  defp collect_first_json_object(char, {:collecting, depth, in_string?, escaped?, chars}) do
    chars = [char | chars]

    cond do
      in_string? and escaped? ->
        {:cont, {:collecting, depth, true, false, chars}}

      in_string? and char == "\\" ->
        {:cont, {:collecting, depth, true, true, chars}}

      in_string? and char == "\"" ->
        {:cont, {:collecting, depth, false, false, chars}}

      in_string? ->
        {:cont, {:collecting, depth, true, false, chars}}

      char == "\"" ->
        {:cont, {:collecting, depth, true, false, chars}}

      char == "{" ->
        {:cont, {:collecting, depth + 1, false, false, chars}}

      char == "}" ->
        depth = depth - 1

        if depth == 0 do
          {:halt, {:done, chars}}
        else
          {:cont, {:collecting, depth, false, false, chars}}
        end

      true ->
        {:cont, {:collecting, depth, false, false, chars}}
    end
  end
end
