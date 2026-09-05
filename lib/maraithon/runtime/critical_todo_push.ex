defmodule Maraithon.Runtime.CriticalTodoPush do
  @moduledoc """
  Three bounded daily reminders for actionable Critical todos, without an LLM.

  The recurring coordinator discovers due users; APNs delivery runs in a leased
  provider partition. Each local date/hour has one durable PushBroker receipt.
  A two-hour delivery window allows temporary holds/rejections to recover but
  never replays a morning reminder in the evening. Todos are reread at send time.
  """

  alias Maraithon.BriefingSchedules
  alias Maraithon.Push.{APNS, Notifier}
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PushBroker
  alias Maraithon.Todos

  @hours [9, 13, 17]

  def enabled? do
    Notifier.enabled?() and APNS.configured?() and TelegramAssistant.unified_push_enabled?()
  end

  def due_slot(user_id, now) do
    schedule = BriefingSchedules.summarize_for_prompt(user_id, now: now)
    local_now = DateTime.add(now, schedule.timezone_offset_hours, :hour)

    case slot(local_now) do
      nil ->
        nil

      slot ->
        if Notifier.enabled_for_user?(user_id) and
             is_nil(TelegramAssistant.push_receipt_for(user_id, dedupe_key(slot))) and
             Todos.list_critical_for_push(user_id) != [] do
          slot
        end
    end
  end

  @doc false
  def slot(%DateTime{} = local_now) do
    case Enum.find(@hours, &(local_now.hour >= &1 and local_now.hour < &1 + 2)) do
      nil -> nil
      hour -> "#{Date.to_iso8601(DateTime.to_date(local_now))}:#{hour}"
    end
  end

  def run_for_user(user_id, expected_slot, %DateTime{} = now)
      when is_binary(user_id) and is_binary(expected_slot) do
    if enabled?() and due_slot(user_id, now) == expected_slot do
      case Todos.list_critical_for_push(user_id) do
        [] -> {:ok, %{outcome: "no_critical_todos"}}
        todos -> deliver(user_id, expected_slot, todos)
      end
    else
      {:ok, %{outcome: "not_due"}}
    end
  end

  defp deliver(user_id, slot, todos) do
    # The broker accepts Telegram-safe HTML and converts it to push plaintext.
    body =
      todos
      |> Enum.map_join("\n", fn todo -> "• " <> String.slice(todo.title, 0, 120) end)
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    PushBroker.deliver(%{
      user_id: user_id,
      origin_type: "assistant_digest",
      origin_id: "critical_todos:#{slot}",
      dedupe_key: dedupe_key(slot),
      title: "Critical todos need your attention",
      body: body,
      urgency: 0.9,
      digest: true,
      # A scheduled digest is not an emergency exemption: it respects both
      # quiet hours and the shared hourly interruption budget.
      interrupt_now: false,
      structured_data: %{"message_class" => "todo_digest"},
      receipt_metadata: %{
        "kind" => "critical_todos",
        "slot" => slot,
        "todo_ids" => Enum.map(todos, & &1.id)
      }
    })
    |> case do
      {:fallback, :disabled} -> {:ok, %{outcome: "disabled"}}
      result -> result
    end
  end

  defp dedupe_key(slot), do: "critical-todos:#{slot}"
end
