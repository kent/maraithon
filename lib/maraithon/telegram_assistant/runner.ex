defmodule Maraithon.TelegramAssistant.Runner do
  @moduledoc """
  Bounded multi-step runner for Telegram assistant chat and prepared actions.
  """

  alias Maraithon.Runtime
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{Context, Run, Toolbox}
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Tools

  require Logger

  @max_llm_turns 6
  @max_tool_steps 10

  def run_inbound(attrs) when is_map(attrs) do
    context = Context.build(attrs)
    conversation = Map.get(attrs, :conversation)

    case start_run(attrs, context) do
      {:ok, run} ->
        runtime_context = build_runtime_context(run, attrs, context)
        _ = maybe_start_liveness_session(run, attrs)

        with {:ok, _step_state} <- record_context_fetch(run, context),
             :ok <- note_context_loaded(run),
             {:ok, response, state} <-
               run_loop(
                 run,
                 runtime_context,
                 %{iteration: 1, llm_turns: 0, tool_steps: 0, tool_history: [], sequence: 1},
                 System.monotonic_time(:millisecond)
               ),
             {:ok, status, summary} <-
               deliver_final_response(conversation, run, response, state, attrs) do
          {:ok, _run} =
            TelegramAssistant.complete_run(run, %{status: status, result_summary: summary})

          :ok
        else
          {:fallback, reason} ->
            _ = TelegramAssistant.cancel_liveness_session(run.id)
            {:ok, _run} = TelegramAssistant.fail_run(run, reason, "degraded")

            Logger.warning("Telegram assistant falling back to legacy interpreter",
              reason: inspect(reason)
            )

            {:fallback, reason}

          {:error, %Run{} = run, reason, state} ->
            handle_run_failure(run, reason, state, attrs)

          {:error, reason} ->
            _ = TelegramAssistant.cancel_liveness_session(run.id)
            {:ok, _run} = TelegramAssistant.fail_run(run, reason, "degraded")
            {:fallback, reason}
        end

      {:error, reason} ->
        {:fallback, reason}
    end
  end

  def execute_prepared_action(prepared_action) do
    action_type = prepared_action.action_type
    payload = prepared_action.payload || %{}

    case action_type do
      "agent_create" ->
        Runtime.start_agent(Map.fetch!(payload, "start_params"))
        |> map_agent_result("Created agent.")

      "agent_update" ->
        Runtime.update_agent(
          Map.fetch!(payload, "agent_id"),
          Map.fetch!(payload, "update_params")
        )
        |> map_agent_result("Updated agent.")

      "agent_delete" ->
        case Runtime.delete_agent(Map.fetch!(payload, "agent_id")) do
          :ok -> {:ok, %{message: "Deleted the agent."}}
          {:error, reason} -> {:error, reason}
        end

      action_type ->
        execute_external_action(action_type, payload)
    end
  end

  defp start_run(attrs, context) do
    TelegramAssistant.start_run(%{
      user_id: Map.fetch!(attrs, :user_id),
      chat_id: Map.fetch!(attrs, :chat_id),
      conversation_id: conversation_id(Map.get(attrs, :conversation)),
      trigger_type: trigger_type(attrs),
      status: "running",
      model_provider: TelegramAssistant.model_provider_name(),
      model_name: TelegramAssistant.model_name(),
      prompt_snapshot: Context.prompt_snapshot(context),
      result_summary: %{},
      started_at: DateTime.utc_now()
    })
  end

  defp record_context_fetch(run, context) do
    now = DateTime.utc_now()

    with {:ok, step} <- build_step(run, "context_fetch", 1, %{context: context}, now),
         {:ok, _completed_step} <-
           TelegramAssistant.complete_step(step, %{
             response_payload: %{context_loaded: true},
             finished_at: now
           }) do
      {:ok, :recorded}
    end
  end

  defp run_loop(run, runtime_context, state, started_monotonic_ms) do
    cond do
      timed_out?(started_monotonic_ms) ->
        {:error, run, :timeout, state}

      state.llm_turns >= max_llm_turns() ->
        {:error, run, :llm_turn_limit, state}

      true ->
        request_payload = %{
          context: runtime_context.context,
          tools: Toolbox.tool_definitions(runtime_context.context),
          tool_history: state.tool_history,
          iteration: state.iteration,
          llm_turns: state.llm_turns,
          tool_steps: state.tool_steps
        }

        now = DateTime.utc_now()

        with {:ok, llm_request_step} <-
               build_step(run, "llm_request", state.sequence + 1, request_payload, now),
             {:ok, response} <- TelegramAssistant.client_module().next_step(request_payload),
             {:ok, _completed_request_step} <-
               TelegramAssistant.complete_step(llm_request_step, %{
                 response_payload: %{ok: true},
                 finished_at: DateTime.utc_now()
               }),
             {:ok, _llm_response_step} <-
               record_llm_response(run, state.sequence + 2, response) do
          next_state = %{state | llm_turns: state.llm_turns + 1, sequence: state.sequence + 2}
          handle_llm_response(run, runtime_context, response, next_state, started_monotonic_ms)
        else
          {:error, reason} when state.tool_history == [] ->
            {:fallback, reason}

          {:error, reason} ->
            {:error, run, reason, state}
        end
    end
  end

  defp handle_llm_response(run, runtime_context, response, state, started_monotonic_ms) do
    case Map.get(response, "status") do
      "tool_calls" ->
        execute_tool_calls(
          run,
          runtime_context,
          Map.get(response, "tool_calls", []),
          state,
          started_monotonic_ms
        )

      _ ->
        {:ok, response, state}
    end
  end

  defp execute_tool_calls(run, runtime_context, tool_calls, state, started_monotonic_ms) do
    if state.tool_steps + length(tool_calls) > max_tool_steps() do
      {:error, run, :tool_step_limit, state}
    else
      Enum.reduce_while(tool_calls, {:ok, state}, fn tool_call, {:ok, acc_state} ->
        tool_name = Map.get(tool_call, "tool")
        arguments = Map.get(tool_call, "arguments", %{})
        now = DateTime.utc_now()

        with {:ok, tool_step} <-
               build_step(
                 run,
                 "tool_call",
                 acc_state.sequence + 1,
                 %{"tool" => tool_name, "arguments" => arguments},
                 now
               ) do
          _ = TelegramAssistant.note_liveness_tool(run.id, tool_name, arguments)

          case Toolbox.execute(tool_name, arguments, runtime_context) do
            {:ok, result} ->
              {:ok, _completed_tool_step} =
                TelegramAssistant.complete_step(tool_step, %{
                  response_payload: stringify_map(result),
                  finished_at: DateTime.utc_now()
                })

              next_state =
                acc_state
                |> Map.update!(:tool_steps, &(&1 + 1))
                |> Map.update!(:sequence, &(&1 + 1))
                |> Map.update!(:tool_history, fn history ->
                  history ++
                    [
                      %{
                        "tool" => tool_name,
                        "arguments" => arguments,
                        "result" => stringify_map(result)
                      }
                    ]
                end)

              {:cont, {:ok, next_state}}

            {:error, reason} ->
              {:ok, _completed_tool_step} =
                TelegramAssistant.complete_step(tool_step, %{
                  status: "failed",
                  response_payload: %{"error" => normalize_error(reason)},
                  error: normalize_error(reason),
                  finished_at: DateTime.utc_now()
                })

              next_state =
                acc_state
                |> Map.update!(:tool_steps, &(&1 + 1))
                |> Map.update!(:sequence, &(&1 + 1))
                |> Map.update!(:tool_history, fn history ->
                  history ++
                    [
                      %{
                        "tool" => tool_name,
                        "arguments" => arguments,
                        "error" => normalize_error(reason)
                      }
                    ]
                end)

              {:cont, {:ok, next_state}}
          end
        else
          {:error, reason} ->
            {:halt, {:error, run, reason, acc_state}}
        end
      end)
      |> case do
        {:ok, next_state} ->
          run_loop(
            run,
            runtime_context,
            %{next_state | iteration: next_state.iteration + 1},
            started_monotonic_ms
          )

        other ->
          other
      end
    end
  end

  defp deliver_final_response(
         %Conversation{} = conversation,
         run,
         response,
         state,
         attrs
       ) do
    message_class = Map.get(response, "message_class", "assistant_reply")
    prepared_action_id = latest_prepared_action_id(state.tool_history)
    text = final_text(response, prepared_action_id)

    {:ok, %{delivery: delivery, summary: liveness_summary}} =
      TelegramAssistant.prepare_final_delivery(run.id)

    turn_opts =
      [
        reply_to_message_id: Map.get(attrs, :source_message_id),
        turn_kind: turn_kind_for_message_class(message_class),
        origin_type: if(prepared_action_id, do: "prepared_action", else: "chat"),
        origin_id: prepared_action_id,
        structured_data: %{
          "run_id" => run.id,
          "tool_history" => state.tool_history,
          "summary" => Map.get(response, "summary"),
          "message_class" => message_class
        }
      ]
      |> apply_delivery_mode(delivery)
      |> maybe_put_approval_markup(prepared_action_id, message_class)

    case delivery.mode do
      :suppress_after_timeout ->
        {:ok, "degraded",
         build_result_summary(message_class, prepared_action_id, state, liveness_summary)}

      _ ->
        case TelegramAssistant.send_turn(
               conversation,
               Map.fetch!(attrs, :chat_id),
               text,
               turn_opts
             ) do
          {:ok, updated_conversation, _turn, _telegram_result} ->
            status =
              if message_class == "approval_prompt" and is_binary(prepared_action_id) do
                prepared_action = TelegramAssistant.get_prepared_action(prepared_action_id)

                {:ok, _conversation} =
                  TelegramAssistant.mark_conversation_awaiting_action(
                    updated_conversation,
                    prepared_action
                  )

                "waiting_confirmation"
              else
                "completed"
              end

            summary =
              build_result_summary(message_class, prepared_action_id, state, liveness_summary)

            {:ok, status, summary}

          {:error, reason} ->
            {:error, run, reason, state}
        end
    end
  end

  defp deliver_final_response(_conversation, run, _response, state, _attrs) do
    {:error, run, :missing_conversation, state}
  end

  defp handle_run_failure(run, reason, state, attrs) do
    {:ok, %{delivery: delivery, summary: liveness_summary}} =
      TelegramAssistant.prepare_final_delivery(run.id)

    summary =
      build_result_summary(
        "system_notice",
        latest_prepared_action_id(state.tool_history),
        state,
        liveness_summary
      )

    {:ok, _run} =
      TelegramAssistant.complete_run(run, %{
        status: "degraded",
        error: normalize_error(reason),
        result_summary: summary
      })

    case {state.tool_history, Map.get(attrs, :conversation), delivery.mode} do
      {[], _conversation, _mode} ->
        {:fallback, reason}

      {_history, %Conversation{} = _conversation, :suppress_after_timeout} ->
        :ok

      {_history, %Conversation{} = conversation, _mode} ->
        _ =
          TelegramAssistant.send_turn(
            conversation,
            Map.fetch!(attrs, :chat_id),
            "I hit an internal issue while working on that. Try again or ask me for a narrower step.",
            reply_to_message_id: Map.get(attrs, :source_message_id),
            send_mode: send_mode_for_delivery(delivery),
            message_id: delivery[:message_id],
            turn_kind: "system_notice",
            origin_type: "system",
            structured_data: %{"run_id" => run.id, "error" => normalize_error(reason)}
          )

        :ok

      _ ->
        :ok
    end
  end

  defp record_llm_response(run, sequence, response) do
    now = DateTime.utc_now()

    with {:ok, step} <- build_step(run, "llm_response", sequence, %{}, now) do
      TelegramAssistant.complete_step(step, %{response_payload: response, finished_at: now})
    end
  end

  defp build_step(run, step_type, sequence, request_payload, started_at) do
    TelegramAssistant.create_step(%{
      run_id: run.id,
      sequence: sequence,
      step_type: step_type,
      status: "running",
      request_payload: stringify_map(request_payload),
      response_payload: %{},
      started_at: started_at
    })
  end

  defp build_runtime_context(run, attrs, context) do
    defaults = Map.get(context, :defaults) || Map.get(context, "defaults") || %{}

    %{
      run_id: run.id,
      user_id: Map.fetch!(attrs, :user_id),
      chat_id: Map.fetch!(attrs, :chat_id),
      conversation_id: conversation_id(Map.get(attrs, :conversation)),
      context: context,
      default_slack_team_id:
        Map.get(defaults, :default_slack_team_id) || defaults["default_slack_team_id"]
    }
  end

  defp maybe_start_liveness_session(run, attrs) do
    case TelegramAssistant.start_liveness_session(run, attrs) do
      {:ok, _pid} ->
        :ok

      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram assistant liveness session failed to start",
          run_id: run.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp note_context_loaded(run) do
    _ = TelegramAssistant.note_liveness_context_loaded(run.id)
    :ok
  end

  defp apply_delivery_mode(turn_opts, %{mode: :edit, message_id: message_id})
       when is_binary(message_id) do
    turn_opts
    |> Keyword.put(:send_mode, :edit)
    |> Keyword.put(:message_id, message_id)
  end

  defp apply_delivery_mode(turn_opts, _delivery), do: turn_opts

  defp send_mode_for_delivery(%{mode: :edit}), do: :edit
  defp send_mode_for_delivery(_delivery), do: :reply

  defp build_result_summary(message_class, prepared_action_id, state, liveness_summary) do
    %{
      message_class: message_class,
      prepared_action_id: prepared_action_id,
      tool_steps: state.tool_steps,
      llm_turns: state.llm_turns,
      liveness: liveness_summary
    }
  end

  defp maybe_put_approval_markup(turn_opts, prepared_action_id, "approval_prompt")
       when is_binary(prepared_action_id) do
    Keyword.put(
      turn_opts,
      :telegram_opts,
      reply_markup: Maraithon.TelegramResponder.action_markup(prepared_action_id)
    )
  end

  defp maybe_put_approval_markup(turn_opts, _prepared_action_id, _message_class), do: turn_opts

  defp latest_prepared_action_id(tool_history) when is_list(tool_history) do
    tool_history
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      case Map.get(entry, "result") do
        %{"prepared_action_id" => id} when is_binary(id) -> id
        _ -> nil
      end
    end)
  end

  defp latest_prepared_action_id(_tool_history), do: nil

  defp final_text(response, prepared_action_id) do
    assistant_message = Map.get(response, "assistant_message", "")

    cond do
      assistant_message != "" ->
        assistant_message

      is_binary(prepared_action_id) ->
        case TelegramAssistant.get_prepared_action(prepared_action_id) do
          %{preview_text: preview_text} -> preview_text
          _ -> "I prepared the requested action."
        end

      true ->
        "I finished that step."
    end
  end

  defp turn_kind_for_message_class("approval_prompt"), do: "approval_prompt"
  defp turn_kind_for_message_class("action_result"), do: "action_result"
  defp turn_kind_for_message_class("system_notice"), do: "system_notice"
  defp turn_kind_for_message_class(_message_class), do: "assistant_reply"

  defp trigger_type(attrs) do
    cond do
      is_binary(Map.get(attrs, :reply_to_message_id)) -> "reply"
      Map.get(attrs, :linked_delivery) -> "reply"
      true -> "inbound_message"
    end
  end

  defp timed_out?(started_monotonic_ms) do
    System.monotonic_time(:millisecond) - started_monotonic_ms >= max_wall_clock_ms()
  end

  defp max_llm_turns do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:max_llm_turns, @max_llm_turns)
  end

  defp max_tool_steps do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:max_tool_steps, @max_tool_steps)
  end

  defp max_wall_clock_ms do
    TelegramAssistant.hard_timeout_ms()
  end

  defp conversation_id(%Conversation{id: id}), do: id
  defp conversation_id(_conversation), do: nil

  defp execute_external_action(action_type, payload) do
    case action_type do
      "gmail_send" ->
        execute_tool_action("gmail_send_message", payload, "Sent via Gmail.")

      "slack_post" ->
        execute_tool_action("slack_post_message", payload, "Posted the Slack message.")

      "linear_create_issue" ->
        execute_tool_action("linear_create_issue", payload, "Created the Linear issue.")

      "linear_create_comment" ->
        execute_tool_action("linear_create_comment", payload, "Added the Linear comment.")

      "linear_update_issue_state" ->
        execute_tool_action(
          "linear_update_issue_state",
          payload,
          "Updated the Linear issue state."
        )

      "notaui_complete_task" ->
        execute_tool_action("notaui_complete_task", payload, "Completed the task in Notaui.")

      "notaui_update_task" ->
        execute_tool_action("notaui_update_task", payload, "Updated the task in Notaui.")

      _ ->
        {:error, "unsupported_prepared_action"}
    end
  end

  defp execute_tool_action(tool_name, payload, success_message) do
    case Tools.execute(tool_name, payload) do
      {:ok, result} ->
        {:ok,
         result |> normalize_payload() |> ensure_map() |> Map.put("message", success_message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp map_agent_result({:ok, result}, success_message) do
    {:ok, result |> normalize_payload() |> ensure_map() |> Map.put("message", success_message)}
  end

  defp map_agent_result({:error, reason}, _success_message), do: {:error, reason}

  defp stringify_map(value), do: value |> normalize_payload() |> ensure_map()

  defp normalize_payload(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_payload(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_payload(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_payload(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_payload(value) when is_struct(value),
    do: value |> Map.from_struct() |> normalize_payload()

  defp normalize_payload(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), normalize_payload(nested_value)}
    end)
  end

  defp normalize_payload(value) when is_list(value), do: Enum.map(value, &normalize_payload/1)

  defp normalize_payload(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&normalize_payload/1)

  defp normalize_payload(value) when is_pid(value), do: inspect(value)
  defp normalize_payload(value) when is_reference(value), do: inspect(value)
  defp normalize_payload(value) when is_function(value), do: inspect(value)
  defp normalize_payload(value), do: value

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(value), do: %{"value" => value}

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)
end
