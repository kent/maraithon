defmodule Maraithon.TelegramAssistant.LivenessSession do
  @moduledoc """
  Owns transient typing, progress, and timeout feedback for one assistant run.
  """

  use GenServer

  alias Maraithon.TelegramResponder

  require Logger

  @registry Maraithon.TelegramAssistant.LivenessRegistry
  @default_timeout_text "Something went wrong on my side. I didn't finish that in time. Try again, or ask for one narrower step."

  def start_link(attrs) when is_map(attrs) do
    GenServer.start_link(__MODULE__, attrs, name: via(Map.fetch!(attrs, :run_id)))
  end

  def child_spec(attrs) when is_map(attrs) do
    %{
      id: {__MODULE__, Map.fetch!(attrs, :run_id)},
      start: {__MODULE__, :start_link, [attrs]},
      restart: :temporary
    }
  end

  def note_context_loaded(run_id) when is_binary(run_id) do
    cast(run_id, :context_loaded)
  end

  def note_tool(run_id, tool_name, args \\ %{})
      when is_binary(run_id) and is_binary(tool_name) and is_map(args) do
    cast(run_id, {:tool, tool_name, args})
  end

  def prepare_final_delivery(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      nil ->
        {:ok,
         %{
           delivery: %{mode: :send},
           summary: default_summary("send")
         }}

      _pid ->
        {:ok, GenServer.call(via(run_id), :prepare_final_delivery, 5_000)}
    end
  catch
    :exit, _reason ->
      {:ok,
       %{
         delivery: %{mode: :send},
         summary: default_summary("send")
       }}
  end

  def cancel(run_id) when is_binary(run_id) do
    cast(run_id, :cancel)
  end

  def timed_out?(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      nil -> false
      _pid -> GenServer.call(via(run_id), :timed_out?, 5_000)
    end
  catch
    :exit, _reason -> false
  end

  @impl true
  def init(attrs) do
    state =
      %{
        run_id: Map.fetch!(attrs, :run_id),
        user_id: Map.fetch!(attrs, :user_id),
        conversation_id: Map.get(attrs, :conversation_id),
        chat_id: Map.fetch!(attrs, :chat_id),
        reply_to_message_id: Map.get(attrs, :reply_to_message_id),
        phase: "pending",
        hint_category: "thinking",
        hint_labels: [],
        progress_message_id: nil,
        typing_started: false,
        progress_note_sent: false,
        timeout_notice_sent: false,
        final_delivery_mode: nil,
        timed_out: false,
        started_monotonic_ms: System.monotonic_time(:millisecond),
        typing_timer_ref: nil,
        progress_timer_ref: nil,
        timeout_timer_ref: nil
      }
      |> schedule_initial_timers()

    emit(:started, %{count: 1}, base_metadata(state))

    {:ok, state}
  end

  @impl true
  def handle_cast(:context_loaded, state), do: {:noreply, state}

  def handle_cast({:tool, tool_name, args}, state) do
    {hint_category, hint_labels} = classify_tool(tool_name, args)

    next_state =
      if hint_specific?(hint_category, hint_labels) do
        %{state | hint_category: hint_category, hint_labels: hint_labels}
      else
        state
      end

    {:noreply, next_state}
  end

  def handle_cast(:cancel, state) do
    {:stop, :normal, cancel_timers(state)}
  end

  @impl true
  def handle_call(:prepare_final_delivery, _from, state) do
    next_state =
      state
      |> cancel_timers()
      |> finalize_delivery_mode()

    emit_completed(next_state)

    reply = %{
      delivery: delivery_for(next_state),
      summary: summary(next_state)
    }

    {:stop, :normal, reply, next_state}
  end

  def handle_call(:timed_out?, _from, state) do
    {:reply, state.timed_out, state}
  end

  @impl true
  def handle_info(:start_typing, state) do
    if terminal?(state) do
      {:noreply, state}
    else
      case TelegramResponder.send_chat_action(state.chat_id, :typing) do
        {:ok, _result} ->
          emit(:chat_action, %{count: 1}, Map.merge(base_metadata(state), %{action: "typing"}))

          {:noreply,
           %{state | typing_started: true, phase: "typing"}
           |> schedule_typing_refresh()}

        {:error, reason} ->
          Logger.warning("Telegram assistant typing indicator failed", reason: inspect(reason))

          {:noreply,
           %{state | typing_started: true, phase: "typing"} |> schedule_typing_refresh()}
      end
    end
  end

  def handle_info(:typing_refresh, state) do
    if terminal?(state) do
      {:noreply, %{state | typing_timer_ref: nil}}
    else
      case TelegramResponder.send_chat_action(state.chat_id, :typing) do
        {:ok, _result} ->
          emit(:chat_action, %{count: 1}, Map.merge(base_metadata(state), %{action: "typing"}))
          {:noreply, schedule_typing_refresh(%{state | typing_started: true, phase: "typing"})}

        {:error, reason} ->
          Logger.warning("Telegram assistant typing refresh failed", reason: inspect(reason))
          {:noreply, schedule_typing_refresh(%{state | typing_started: true, phase: "typing"})}
      end
    end
  end

  def handle_info(:show_progress, state) do
    cond do
      terminal?(state) or is_binary(state.progress_message_id) ->
        {:noreply, %{state | progress_timer_ref: nil}}

      true ->
        text = progress_text(state)

        result =
          if is_binary(state.reply_to_message_id) do
            TelegramResponder.reply(state.chat_id, state.reply_to_message_id, text)
          else
            TelegramResponder.send(state.chat_id, text)
          end

        case result do
          {:ok, response} ->
            message_id = normalize_id(Map.get(response, "message_id"))

            next_state = %{
              state
              | progress_timer_ref: nil,
                progress_message_id: message_id,
                progress_note_sent: true,
                phase: "progress_visible"
            }

            emit(
              :progress_note,
              %{count: 1},
              Map.merge(base_metadata(next_state), %{
                hint_category: next_state.hint_category,
                delivery_mode: "send"
              })
            )

            {:noreply, next_state}

          {:error, reason} ->
            Logger.warning("Telegram assistant progress note failed", reason: inspect(reason))
            {:noreply, %{state | progress_timer_ref: nil}}
        end
    end
  end

  def handle_info(:timeout, state) do
    if terminal?(state) do
      {:noreply, %{state | timeout_timer_ref: nil}}
    else
      next_state =
        state
        |> cancel_timers()
        |> deliver_timeout_notice()

      emit(
        :timeout,
        %{count: 1},
        Map.merge(base_metadata(next_state), %{
          hint_category: next_state.hint_category,
          llm_turns: 0,
          tool_steps: 0
        })
      )

      {:noreply, next_state}
    end
  end

  defp schedule_initial_timers(state) do
    %{
      state
      | typing_timer_ref:
          Process.send_after(
            self(),
            :start_typing,
            Maraithon.TelegramAssistant.typing_initial_delay_ms()
          ),
        progress_timer_ref:
          Process.send_after(
            self(),
            :show_progress,
            Maraithon.TelegramAssistant.contextual_progress_delay_ms()
          ),
        timeout_timer_ref:
          Process.send_after(self(), :timeout, Maraithon.TelegramAssistant.timeout_notice_ms())
    }
  end

  defp schedule_typing_refresh(state) do
    %{
      state
      | typing_timer_ref:
          Process.send_after(
            self(),
            :typing_refresh,
            Maraithon.TelegramAssistant.typing_refresh_ms()
          )
    }
  end

  defp cancel_timers(state) do
    state
    |> cancel_timer(:typing_timer_ref)
    |> cancel_timer(:progress_timer_ref)
    |> cancel_timer(:timeout_timer_ref)
  end

  defp cancel_timer(state, key) do
    if ref = Map.get(state, key) do
      Process.cancel_timer(ref)
    end

    Map.put(state, key, nil)
  end

  defp deliver_timeout_notice(state) do
    text = timeout_text(state)

    result =
      if is_binary(state.progress_message_id) do
        case TelegramResponder.edit(state.chat_id, state.progress_message_id, text) do
          {:ok, response} ->
            {:ok, response}

          {:error, reason} ->
            Logger.warning("Telegram assistant timeout edit failed, falling back to send",
              reason: inspect(reason)
            )

            send_timeout_reply(state, text)
        end
      else
        send_timeout_reply(state, text)
      end

    case result do
      {:ok, response} ->
        %{
          state
          | timeout_timer_ref: nil,
            timeout_notice_sent: true,
            timed_out: true,
            phase: "timed_out",
            progress_message_id:
              state.progress_message_id || normalize_id(Map.get(response, "message_id")),
            final_delivery_mode: "timeout_only"
        }

      {:error, reason} ->
        Logger.warning("Telegram assistant timeout notice failed", reason: inspect(reason))

        %{
          state
          | timeout_timer_ref: nil,
            timeout_notice_sent: true,
            timed_out: true,
            phase: "timed_out",
            final_delivery_mode: "timeout_only"
        }
    end
  end

  defp finalize_delivery_mode(%{timed_out: true} = state) do
    %{state | final_delivery_mode: "suppressed_after_timeout", phase: "completed"}
  end

  defp finalize_delivery_mode(
         %{progress_note_sent: true, progress_message_id: message_id} = state
       )
       when is_binary(message_id) do
    %{state | final_delivery_mode: "edit_progress", phase: "completed"}
  end

  defp finalize_delivery_mode(state) do
    %{state | final_delivery_mode: "send", phase: "completed"}
  end

  defp delivery_for(%{timed_out: true}) do
    %{mode: :suppress_after_timeout}
  end

  defp delivery_for(%{progress_note_sent: true, progress_message_id: message_id})
       when is_binary(message_id) do
    %{mode: :edit, message_id: message_id}
  end

  defp delivery_for(_state) do
    %{mode: :send}
  end

  defp summary(state) do
    %{
      "typing_started" => state.typing_started,
      "progress_note_sent" => state.progress_note_sent,
      "timeout_notice_sent" => state.timeout_notice_sent,
      "final_delivery_mode" => state.final_delivery_mode || "send"
    }
  end

  defp default_summary(final_delivery_mode) do
    %{
      "typing_started" => false,
      "progress_note_sent" => false,
      "timeout_notice_sent" => false,
      "final_delivery_mode" => final_delivery_mode
    }
  end

  defp emit_completed(state) do
    emit(
      :completed,
      %{duration_ms: System.monotonic_time(:millisecond) - state.started_monotonic_ms},
      Map.merge(base_metadata(state), %{
        final_delivery_mode: state.final_delivery_mode,
        typing_started: state.typing_started,
        progress_note_sent: state.progress_note_sent,
        timed_out: state.timed_out
      })
    )
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute(
      [:maraithon, :telegram_assistant, :liveness, event],
      measurements,
      metadata
    )
  end

  defp base_metadata(state) do
    %{
      run_id: state.run_id,
      user_id: state.user_id,
      chat_id: state.chat_id,
      phase: state.phase
    }
  end

  defp classify_tool(tool_name, _args) do
    cond do
      tool_name in ["get_open_work_summary", "inspect_open_insight"] ->
        {"open_work", []}

      String.starts_with?(tool_name, "gmail_") ->
        {"connected_accounts", ["Gmail"]}

      tool_name == "calendar_list_events" ->
        {"connected_accounts", ["Calendar"]}

      String.starts_with?(tool_name, "slack_") ->
        {"connected_accounts", ["Slack"]}

      String.starts_with?(tool_name, "linear_") ->
        {"connected_accounts", ["Linear"]}

      String.starts_with?(tool_name, "notaui_") ->
        {"connected_accounts", ["Notaui"]}

      tool_name in ["list_agents", "inspect_agent", "query_agent"] ->
        {"agents", ["agents"]}

      tool_name in ["prepare_agent_action", "prepare_external_action"] ->
        {"actions", []}

      true ->
        {"thinking", []}
    end
  end

  defp hint_specific?("thinking", []), do: false
  defp hint_specific?(_category, _labels), do: true

  defp progress_text(%{hint_category: "open_work"}) do
    "Still reviewing your open work."
  end

  defp progress_text(%{hint_category: "agents"}) do
    "Still asking your agents."
  end

  defp progress_text(%{hint_category: "actions"}) do
    "Still preparing that action."
  end

  defp progress_text(%{hint_category: "connected_accounts", hint_labels: labels}) do
    case Enum.uniq(labels) do
      ["Gmail", "Calendar"] -> "Still checking Gmail and Calendar."
      ["Calendar", "Gmail"] -> "Still checking Gmail and Calendar."
      ["Gmail"] -> "Still checking Gmail."
      ["Calendar"] -> "Still checking your calendar."
      [_single] -> "Still checking your connected accounts."
      _ -> "Still checking your connected accounts."
    end
  end

  defp progress_text(_state), do: "Still working on that."

  defp timeout_text(_state), do: @default_timeout_text

  defp terminal?(state) do
    state.final_delivery_mode in [
      "timeout_only",
      "suppressed_after_timeout",
      "send",
      "edit_progress"
    ] or state.timed_out
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp via(run_id) do
    {:via, Registry, {@registry, run_id}}
  end

  defp lookup(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] -> pid
      _ -> nil
    end
  end

  defp cast(run_id, message) do
    if lookup(run_id) do
      GenServer.cast(via(run_id), message)
    else
      :ok
    end
  end

  defp send_timeout_reply(state, text) do
    if is_binary(state.reply_to_message_id) do
      TelegramResponder.reply(state.chat_id, state.reply_to_message_id, text)
    else
      TelegramResponder.send(state.chat_id, text)
    end
  end
end
