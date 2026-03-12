defmodule Maraithon.TelegramAssistant do
  @moduledoc """
  System-owned Telegram assistant runtime, persistence, and broker entrypoints.
  """

  import Ecto.Query

  alias Maraithon.LLM
  alias Maraithon.Repo

  alias Maraithon.TelegramAssistant.{
    LivenessSession,
    LivenessSupervisor,
    PreparedAction,
    PushBroker,
    PushReceipt,
    Run,
    Runner,
    Step
  }

  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.TelegramResponder

  require Logger

  @default_confirmation_window_seconds 15 * 60
  @default_typing_initial_delay_ms 1_200
  @default_typing_refresh_ms 4_000
  @default_contextual_progress_delay_ms 7_000
  @default_timeout_notice_ms 35_000
  @default_hard_timeout_ms 40_000

  def enabled? do
    config = config()

    case Keyword.get(config, :telegram_full_chat_enabled) do
      true -> true
      false -> false
      nil -> default_enabled?(config)
    end
  end

  def unified_push_enabled? do
    config = config()

    case Keyword.get(config, :telegram_unified_push_enabled) do
      true -> true
      false -> false
      nil -> enabled?()
    end
  end

  def write_tools_enabled? do
    case Keyword.get(config(), :telegram_assistant_write_tools_enabled) do
      true -> true
      false -> false
      nil -> enabled?()
    end
  end

  def agent_control_enabled? do
    case Keyword.get(config(), :telegram_agent_control_enabled) do
      true -> true
      false -> false
      nil -> enabled?()
    end
  end

  def client_module do
    Keyword.get(config(), :client_module, Maraithon.TelegramAssistant.Client.LLMJson)
  end

  def handle_inbound(attrs) when is_map(attrs) do
    if enabled?() do
      Runner.run_inbound(attrs)
    else
      {:fallback, :disabled}
    end
  end

  def handle_callback_query(data) when is_map(data) do
    with true <- enabled?(),
         callback_data when is_binary(callback_data) <- read_string(data, "data"),
         {:ok, prepared_action_id, decision} <-
           TelegramResponder.parse_action_callback(callback_data),
         chat_id when is_binary(chat_id) <- read_id_string(data, "chat_id"),
         message_id when is_binary(message_id) <- read_id_string(data, "message_id") do
      callback_id = read_string(data, "callback_id")

      handle_prepared_action_decision(
        prepared_action_id,
        decision,
        chat_id,
        message_id,
        callback_id
      )

      :ok
    else
      false -> :ignored
      _ -> :ignored
    end
  end

  def handle_text_confirmation(
        %Conversation{} = conversation,
        user_turn,
        chat_id,
        reply_to_message_id,
        decision
      )
      when decision in [:confirm, :reject] do
    case latest_prepared_action(conversation) do
      %PreparedAction{} = prepared_action ->
        respond_to_prepared_action(
          prepared_action,
          decision,
          conversation,
          user_turn,
          chat_id,
          reply_to_message_id
        )

      nil ->
        {:fallback, :no_prepared_action}
    end
  end

  def handle_text_confirmation(
        _conversation,
        _user_turn,
        _chat_id,
        _reply_to_message_id,
        _decision
      ),
      do: {:fallback, :invalid_confirmation}

  def start_run(attrs) when is_map(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def complete_run(%Run{} = run, attrs \\ %{}) do
    finish_at =
      Map.get(attrs, :finished_at) || Map.get(attrs, "finished_at") || DateTime.utc_now()

    run
    |> Ecto.Changeset.change(%{
      status: Map.get(attrs, :status) || Map.get(attrs, "status") || "completed",
      result_summary: Map.get(attrs, :result_summary) || Map.get(attrs, "result_summary") || %{},
      finished_at: finish_at,
      error: Map.get(attrs, :error) || Map.get(attrs, "error")
    })
    |> Repo.update()
  end

  def fail_run(%Run{} = run, error, status \\ "failed") do
    complete_run(run, %{status: status, error: normalize_error(error)})
  end

  def create_step(attrs) when is_map(attrs) do
    %Step{}
    |> Step.changeset(attrs)
    |> Repo.insert()
  end

  def complete_step(%Step{} = step, attrs \\ %{}) do
    step
    |> Ecto.Changeset.change(%{
      status: Map.get(attrs, :status) || Map.get(attrs, "status") || "completed",
      response_payload:
        Map.get(attrs, :response_payload) || Map.get(attrs, "response_payload") || %{},
      finished_at:
        Map.get(attrs, :finished_at) || Map.get(attrs, "finished_at") || DateTime.utc_now(),
      error: Map.get(attrs, :error) || Map.get(attrs, "error")
    })
    |> Repo.update()
  end

  def create_prepared_action(attrs) when is_map(attrs) do
    %PreparedAction{}
    |> PreparedAction.changeset(attrs)
    |> Repo.insert()
  end

  def update_prepared_action(%PreparedAction{} = prepared_action, attrs) when is_map(attrs) do
    prepared_action
    |> PreparedAction.changeset(attrs)
    |> Repo.update()
  end

  def get_prepared_action(id) when is_binary(id), do: Repo.get(PreparedAction, id)
  def get_prepared_action(_id), do: nil

  def latest_prepared_action(%Conversation{} = conversation) do
    prepared_action_id = get_in(conversation.metadata || %{}, ["latest_prepared_action_id"])

    cond do
      is_binary(prepared_action_id) ->
        case Repo.get(PreparedAction, prepared_action_id) do
          %PreparedAction{status: "awaiting_confirmation"} = prepared_action ->
            if prepared_action_expired?(prepared_action) do
              expire_prepared_action(prepared_action)
              nil
            else
              prepared_action
            end

          _ ->
            nil
        end

      true ->
        PreparedAction
        |> where(
          [prepared_action],
          prepared_action.conversation_id == ^conversation.id and
            prepared_action.status == "awaiting_confirmation"
        )
        |> order_by([prepared_action], desc: prepared_action.inserted_at)
        |> limit(1)
        |> Repo.one()
    end
  end

  def latest_prepared_action(_conversation), do: nil

  def record_push_receipt(attrs) when is_map(attrs) do
    %PushReceipt{}
    |> PushReceipt.changeset(attrs)
    |> Repo.insert()
  end

  def push_receipt_for(user_id, dedupe_key)
      when is_binary(user_id) and is_binary(dedupe_key) do
    Repo.get_by(PushReceipt, user_id: user_id, dedupe_key: dedupe_key)
  end

  def push_receipt_for(_user_id, _dedupe_key), do: nil

  def send_turn(%Conversation{} = conversation, chat_id, text, opts \\ [])
      when is_binary(chat_id) and is_binary(text) do
    reply_to_message_id = Keyword.get(opts, :reply_to_message_id)
    send_mode = resolve_send_mode(reply_to_message_id, Keyword.get(opts, :send_mode, :reply))
    telegram_opts = Keyword.get(opts, :telegram_opts, [])

    case dispatch_turn(chat_id, text, reply_to_message_id, send_mode, telegram_opts, opts) do
      {:ok, result, telegram_message_id} ->
        turn_attrs = %{
          "role" => Keyword.get(opts, :role, "assistant"),
          "telegram_message_id" => telegram_message_id,
          "reply_to_message_id" => reply_to_message_id,
          "text" => text,
          "intent" => Keyword.get(opts, :intent),
          "confidence" => Keyword.get(opts, :confidence),
          "turn_kind" => Keyword.get(opts, :turn_kind, "assistant_reply"),
          "origin_type" => Keyword.get(opts, :origin_type, "chat"),
          "origin_id" => Keyword.get(opts, :origin_id),
          "structured_data" => Keyword.get(opts, :structured_data, %{})
        }

        case TelegramConversations.append_turn(conversation, turn_attrs) do
          {:ok, {updated_conversation, turn}} -> {:ok, updated_conversation, turn, result}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed Telegram assistant send", reason: inspect(reason))
        {:error, reason}
    end
  end

  def mark_conversation_awaiting_action(
        %Conversation{} = conversation,
        %PreparedAction{} = prepared_action
      ) do
    TelegramConversations.mark_awaiting_confirmation(conversation, %{
      "metadata" => %{
        "mode" => "assistant",
        "active_run_id" => prepared_action.run_id,
        "latest_prepared_action_id" => prepared_action.id
      }
    })
  end

  def clear_prepared_action_pointer(%Conversation{} = conversation) do
    TelegramConversations.update_metadata(conversation, %{"latest_prepared_action_id" => nil})
  end

  def deliver_insight(delivery), do: PushBroker.deliver_insight(delivery)
  def deliver_brief(brief), do: PushBroker.deliver_brief(brief)
  def deliver_push_candidate(candidate), do: PushBroker.deliver(candidate)

  def confirmation_window_seconds do
    Keyword.get(config(), :confirmation_window_seconds, @default_confirmation_window_seconds)
  end

  def liveness_enabled? do
    case Keyword.get(config(), :telegram_liveness_enabled) do
      true -> true
      false -> false
      nil -> enabled?()
    end
  end

  def typing_initial_delay_ms do
    Keyword.get(config(), :typing_initial_delay_ms, @default_typing_initial_delay_ms)
  end

  def typing_refresh_ms do
    Keyword.get(config(), :typing_refresh_ms, @default_typing_refresh_ms)
  end

  def contextual_progress_delay_ms do
    Keyword.get(
      config(),
      :contextual_progress_delay_ms,
      @default_contextual_progress_delay_ms
    )
  end

  def timeout_notice_ms do
    Keyword.get(config(), :timeout_notice_ms, @default_timeout_notice_ms)
  end

  def hard_timeout_ms do
    Keyword.get(config(), :hard_timeout_ms) ||
      Keyword.get(config(), :max_wall_clock_ms, @default_hard_timeout_ms)
  end

  def start_liveness_session(%Run{} = run, attrs) when is_map(attrs) do
    if liveness_enabled?() do
      LivenessSupervisor.start_session(%{
        run_id: run.id,
        user_id: run.user_id,
        conversation_id: run.conversation_id,
        chat_id: run.chat_id,
        reply_to_message_id: Map.get(attrs, :source_message_id)
      })
    else
      {:error, :disabled}
    end
  end

  def note_liveness_context_loaded(run_id) when is_binary(run_id) do
    maybe_liveness_call(fn -> LivenessSession.note_context_loaded(run_id) end)
  end

  def note_liveness_tool(run_id, tool_name, args \\ %{})
      when is_binary(run_id) and is_binary(tool_name) and is_map(args) do
    maybe_liveness_call(fn -> LivenessSession.note_tool(run_id, tool_name, args) end)
  end

  def cancel_liveness_session(run_id) when is_binary(run_id) do
    maybe_liveness_call(fn -> LivenessSession.cancel(run_id) end)
  end

  def prepare_final_delivery(run_id) when is_binary(run_id) do
    if liveness_enabled?() do
      normalize_liveness_delivery(LivenessSession.prepare_final_delivery(run_id))
    else
      {:ok, default_liveness_delivery()}
    end
  end

  def liveness_timed_out?(run_id) when is_binary(run_id) do
    if liveness_enabled?() do
      LivenessSession.timed_out?(run_id)
    else
      false
    end
  end

  def model_provider_name do
    config()
    |> Keyword.get(:model_provider_name, LLM.provider_name())
    |> to_string()
  end

  def model_name do
    config()
    |> Keyword.get(:model_name, LLM.model())
    |> to_string()
  end

  defp handle_prepared_action_decision(
         prepared_action_id,
         decision,
         chat_id,
         reply_to_message_id,
         callback_id
       ) do
    case Repo.get(PreparedAction, prepared_action_id) do
      %PreparedAction{} = prepared_action ->
        conversation =
          prepared_action.conversation_id &&
            Repo.get(Conversation, prepared_action.conversation_id)

        if callback_id do
          _ =
            TelegramResponder.answer_callback(
              callback_id,
              if(decision == "confirm", do: "Confirmed", else: "Cancelled")
            )
        end

        respond_to_prepared_action(
          prepared_action,
          normalize_decision(decision),
          conversation,
          nil,
          chat_id,
          reply_to_message_id
        )

      nil ->
        if callback_id, do: TelegramResponder.answer_callback(callback_id, "Action not found")
        :ok
    end
  end

  defp respond_to_prepared_action(
         %PreparedAction{} = prepared_action,
         decision,
         %Conversation{} = conversation,
         user_turn,
         chat_id,
         reply_to_message_id
       )
       when decision in [:confirm, :reject] do
    case decision do
      :confirm ->
        case confirm_and_execute(prepared_action) do
          {:ok, updated_action, result} ->
            _ = maybe_close_confirmation(conversation)

            {:ok, _conversation, _turn, _telegram_result} =
              send_turn(
                conversation,
                chat_id,
                prepared_action_result_text(updated_action, result),
                reply_to_message_id: reply_to_message_id,
                turn_kind: "action_result",
                origin_type: "prepared_action",
                origin_id: updated_action.id,
                structured_data: %{
                  "prepared_action_id" => updated_action.id,
                  "decision" => "confirm",
                  "result" => serialize_result(result),
                  "source_turn_id" => user_turn && user_turn.id
                }
              )

            :ok

          {:error, updated_action, reason} ->
            _ = maybe_close_confirmation(conversation)

            {:ok, _conversation, _turn, _telegram_result} =
              send_turn(
                conversation,
                chat_id,
                "I couldn't complete that yet: #{normalize_error(reason)}",
                reply_to_message_id: reply_to_message_id,
                turn_kind: "action_result",
                origin_type: "prepared_action",
                origin_id: updated_action.id,
                structured_data: %{
                  "prepared_action_id" => updated_action.id,
                  "decision" => "confirm",
                  "error" => normalize_error(reason),
                  "source_turn_id" => user_turn && user_turn.id
                }
              )

            :ok
        end

      :reject ->
        {:ok, updated_action} =
          update_prepared_action(prepared_action, %{
            status: "rejected",
            error: nil
          })

        _ = maybe_close_confirmation(conversation)

        {:ok, _conversation, _turn, _telegram_result} =
          send_turn(
            conversation,
            chat_id,
            "Understood. I cancelled that action.",
            reply_to_message_id: reply_to_message_id,
            turn_kind: "system_notice",
            origin_type: "prepared_action",
            origin_id: updated_action.id,
            structured_data: %{
              "prepared_action_id" => updated_action.id,
              "decision" => "reject",
              "source_turn_id" => user_turn && user_turn.id
            }
          )

        :ok
    end
  end

  defp respond_to_prepared_action(
         _prepared_action,
         _decision,
         _conversation,
         _user_turn,
         _chat_id,
         _reply_to_message_id
       ),
       do: :ok

  def confirm_and_execute(%PreparedAction{} = prepared_action) do
    if prepared_action_expired?(prepared_action) do
      {:ok, expired_action} =
        update_prepared_action(prepared_action, %{
          status: "expired",
          error: "confirmation_expired"
        })

      {:error, expired_action, :confirmation_expired}
    else
      {:ok, confirmed_action} =
        update_prepared_action(prepared_action, %{
          status: "confirmed",
          confirmed_at: DateTime.utc_now(),
          error: nil
        })

      case Runner.execute_prepared_action(confirmed_action) do
        {:ok, result} ->
          {:ok, executed_action} =
            update_prepared_action(confirmed_action, %{
              status: "executed",
              executed_at: DateTime.utc_now(),
              error: nil
            })

          {:ok, executed_action, result}

        {:error, reason} ->
          {:ok, failed_action} =
            update_prepared_action(confirmed_action, %{
              status: "failed",
              error: normalize_error(reason)
            })

          {:error, failed_action, reason}
      end
    end
  end

  def expire_prepared_action(%PreparedAction{} = prepared_action) do
    update_prepared_action(prepared_action, %{status: "expired", error: "confirmation_expired"})
  end

  def prepared_action_expired?(%PreparedAction{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  def prepared_action_expired?(_prepared_action), do: false

  defp maybe_close_confirmation(%Conversation{} = conversation) do
    TelegramConversations.reopen(conversation)
    _ = clear_prepared_action_pointer(conversation)
    :ok
  end

  defp maybe_close_confirmation(_conversation), do: :ok

  defp prepared_action_result_text(prepared_action, result) do
    case Map.get(serialize_result(result), "message") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        "Completed #{prepared_action.action_type}."
    end
  end

  defp serialize_result(%{} = result), do: stringify_map(result)
  defp serialize_result(result), do: %{"value" => inspect(result)}

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp default_enabled?(config) do
    Keyword.has_key?(config, :client_module) or LLM.provider() == Maraithon.LLM.OpenAIProvider
  end

  defp resolve_send_mode(_reply_to_message_id, :edit), do: :edit
  defp resolve_send_mode(nil, _mode), do: :send
  defp resolve_send_mode(_reply_to_message_id, mode) when mode in [:send, :reply], do: mode
  defp resolve_send_mode(_reply_to_message_id, _mode), do: :reply

  defp dispatch_turn(chat_id, text, _reply_to_message_id, :send, telegram_opts, _opts) do
    case TelegramResponder.send(chat_id, text, telegram_opts) do
      {:ok, result} -> {:ok, result, normalize_id(Map.get(result, "message_id"))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_turn(chat_id, text, reply_to_message_id, :reply, telegram_opts, _opts) do
    case TelegramResponder.reply(chat_id, reply_to_message_id, text, telegram_opts) do
      {:ok, result} -> {:ok, result, normalize_id(Map.get(result, "message_id"))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_turn(chat_id, text, reply_to_message_id, :edit, telegram_opts, opts) do
    message_id = Keyword.get(opts, :message_id)

    if is_binary(message_id) do
      case TelegramResponder.edit(chat_id, message_id, text, telegram_opts) do
        {:ok, result} ->
          {:ok, result, message_id}

        {:error, reason} ->
          Logger.warning("Failed Telegram assistant edit, falling back to send",
            chat_id: chat_id,
            message_id: message_id,
            reason: inspect(reason)
          )

          fallback_mode = resolve_send_mode(reply_to_message_id, :reply)
          dispatch_turn(chat_id, text, reply_to_message_id, fallback_mode, telegram_opts, [])
      end
    else
      dispatch_turn(chat_id, text, reply_to_message_id, :reply, telegram_opts, [])
    end
  end

  defp normalize_decision("confirm"), do: :confirm
  defp normalize_decision("reject"), do: :reject
  defp normalize_decision(:confirm), do: :confirm
  defp normalize_decision(:reject), do: :reject
  defp normalize_decision(_decision), do: :reject

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp read_string(map, key, default \\ nil) when is_map(map) do
    case fetch(map, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp read_id_string(map, key) when is_map(map) do
    map
    |> fetch(key)
    |> normalize_id()
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp config do
    Application.get_env(:maraithon, :telegram_assistant, [])
  end

  defp maybe_liveness_call(fun) when is_function(fun, 0) do
    if liveness_enabled?() do
      fun.()
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Telegram assistant liveness operation failed",
        reason: Exception.message(error)
      )

      :ok
  end

  defp normalize_liveness_delivery({:ok, %{delivery: _delivery, summary: _summary} = result}) do
    {:ok, result}
  end

  defp normalize_liveness_delivery(%{delivery: _delivery, summary: _summary} = result) do
    {:ok, result}
  end

  defp normalize_liveness_delivery(_result) do
    {:ok, default_liveness_delivery()}
  end

  defp default_liveness_delivery do
    %{
      delivery: %{mode: :send},
      summary: %{
        "typing_started" => false,
        "progress_note_sent" => false,
        "timeout_notice_sent" => false,
        "final_delivery_mode" => "send"
      }
    }
  end
end
