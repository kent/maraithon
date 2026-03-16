defmodule Maraithon.Behaviors.PersonalAssistantAgentTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.PersonalAssistantAgent
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.TestSupport.{TravelCalendarStub, TravelGmailStub}

  setup do
    original_travel = Application.get_env(:maraithon, :travel, [])
    original_gmail_stub = Application.get_env(:maraithon, TravelGmailStub, [])
    original_calendar_stub = Application.get_env(:maraithon, TravelCalendarStub, [])

    Application.put_env(:maraithon, :travel,
      gmail_module: TravelGmailStub,
      calendar_module: TravelCalendarStub
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :travel, original_travel)
      Application.put_env(:maraithon, TravelGmailStub, original_gmail_stub)
      Application.put_env(:maraithon, TravelCalendarStub, original_calendar_stub)
    end)

    user_id = "assistant-agent@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "personal_assistant_agent",
        config: %{}
      })

    {:ok, _google_token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "assistant-google-token",
        scopes: ["gmail", "calendar"]
      })

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "777123",
        metadata: %{"chat_id" => "777123", "username" => "assistant-agent"}
      })

    now = ~U[2026-03-14 22:00:00Z]
    TravelGmailStub.configure(messages: gmail_messages(now), contents: gmail_contents(now))
    TravelCalendarStub.configure(events: calendar_events())

    %{agent: agent, now: now, user_id: user_id}
  end

  test "handle_wakeup emits when it records travel briefs", %{
    agent: agent,
    now: now,
    user_id: user_id
  } do
    state =
      PersonalAssistantAgent.init(%{
        "user_id" => user_id,
        "email_scan_limit" => "10",
        "event_scan_limit" => "10",
        "lookback_hours" => "720",
        "min_confidence" => "0.8",
        "timezone_offset_hours" => "-5",
        "wakeup_interval_ms" => "1800000"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, new_state} =
             PersonalAssistantAgent.handle_wakeup(state, context)

    assert payload.count == 1
    assert payload.user_id == user_id
    assert payload.cadences == ["travel_prep"]
    assert new_state.user_id == user_id
  end

  test "returns idle when no user id is available", %{agent: agent, now: now} do
    state = PersonalAssistantAgent.init(%{})

    context = %{
      agent_id: agent.id,
      user_id: nil,
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:idle, _state} = PersonalAssistantAgent.handle_wakeup(state, context)
  end

  test "schedules the next wakeup from config" do
    state = PersonalAssistantAgent.init(%{"wakeup_interval_ms" => "60000"})
    assert {:relative, 60_000} = PersonalAssistantAgent.next_wakeup(state)
  end

  defp gmail_messages(now) do
    [
      %{
        message_id: "flight-msg-1",
        thread_id: "travel-thread-1",
        subject: "Your flight to Austin is confirmed",
        snippet:
          "Air Canada flight AC 123 Toronto YYZ -> Austin AUS Mar 15, 2026 at 2:00 PM Booking Ref ABC123",
        from: "Air Canada <noreply@aircanada.com>",
        internal_date: DateTime.add(now, -3, :hour)
      },
      %{
        message_id: "hotel-msg-1",
        thread_id: "travel-thread-2",
        subject: "Austin Marriott Downtown reservation confirmed",
        snippet:
          "Hotel reservation with check-in Mar 15, 2026 and check-out Mar 17, 2026. Itinerary H98765.",
        from: "Austin Marriott Downtown <reservations@marriott.com>",
        internal_date: DateTime.add(now, -2, :hour)
      }
    ]
  end

  defp gmail_contents(now) do
    %{
      "flight-msg-1" => %{
        "message_id" => "flight-msg-1",
        "thread_id" => "travel-thread-1",
        "subject" => "Your flight to Austin is confirmed",
        "snippet" =>
          "Air Canada flight AC 123 Toronto YYZ -> Austin AUS Mar 15, 2026 at 2:00 PM Booking Ref ABC123",
        "from" => "Air Canada <noreply@aircanada.com>",
        "internal_date" => DateTime.add(now, -3, :hour),
        "text_body" => """
        Air Canada
        AC 123
        Toronto YYZ -> Austin AUS
        Departure: Mar 15, 2026 at 2:00 PM
        Booking Ref: ABC123
        """
      },
      "hotel-msg-1" => %{
        "message_id" => "hotel-msg-1",
        "thread_id" => "travel-thread-2",
        "subject" => "Austin Marriott Downtown reservation confirmed",
        "snippet" =>
          "Hotel reservation with check-in Mar 15, 2026 and check-out Mar 17, 2026. Itinerary H98765.",
        "from" => "Austin Marriott Downtown <reservations@marriott.com>",
        "internal_date" => DateTime.add(now, -2, :hour),
        "text_body" => """
        Austin Marriott Downtown
        304 East Cesar Chavez St, Austin, TX 78701
        Check-in: Mar 15, 2026
        Check-out: Mar 17, 2026
        Room: King Room
        Hotel Phone: 512-555-1212
        Itinerary #: H98765
        """
      }
    }
  end

  defp calendar_events do
    [
      %{
        event_id: "event-austin-1",
        summary: "Austin work trip",
        description: "Travel to Austin for meetings and hotel stay",
        location: "Austin",
        status: "confirmed",
        start: ~U[2026-03-15 19:00:00Z],
        end: ~U[2026-03-17 16:00:00Z]
      }
    ]
  end
end
