defmodule Maraithon.TelegramConversations do
  @moduledoc """
  Persistence and lookup for Telegram conversations and turns.
  """

  import Ecto.Query

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations.{Conversation, Turn}

  @general_idle_seconds 24 * 60 * 60
  @linked_idle_seconds 7 * 24 * 60 * 60

  def start_or_continue(user_id, chat_id, attrs \\ %{})
      when is_binary(user_id) and is_binary(chat_id) and is_map(attrs) do
    linked_delivery_id = read_string(attrs, "linked_delivery_id")
    linked_insight_id = read_string(attrs, "linked_insight_id")
    reply_to_message_id = read_string(attrs, "reply_to_message_id")
    root_message_id = read_string(attrs, "root_message_id", reply_to_message_id)
    now = DateTime.utc_now()

    conversation =
      find_by_reply(chat_id, reply_to_message_id) ||
        open_pending_confirmation(chat_id) ||
        find_open_linked(chat_id, linked_delivery_id, linked_insight_id) ||
        find_recent_general(chat_id, now)

    case conversation do
      %Conversation{} = existing ->
        existing
        |> Conversation.changeset(%{
          status: existing.status,
          last_turn_at: now,
          root_message_id: existing.root_message_id || root_message_id
        })
        |> Repo.update()

      nil ->
        %Conversation{}
        |> Conversation.changeset(%{
          user_id: user_id,
          chat_id: chat_id,
          root_message_id: root_message_id,
          linked_delivery_id: linked_delivery_id,
          linked_insight_id: linked_insight_id,
          status: "open",
          last_turn_at: now,
          metadata: read_map(attrs, "metadata")
        })
        |> Repo.insert()
    end
  end

  def append_turn(%Conversation{} = conversation, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      turn =
        %Turn{}
        |> Turn.changeset(
          Map.merge(attrs, %{
            "conversation_id" => conversation.id
          })
        )
        |> Repo.insert!()

      updated_conversation =
        conversation
        |> Conversation.changeset(%{
          last_turn_at: now,
          last_intent: read_string(attrs, "intent", conversation.last_intent),
          summary: summarize_recent_turns(conversation.id)
        })
        |> Repo.update!()

      {updated_conversation, turn}
    end)
    |> case do
      {:ok, {conversation, turn}} -> {:ok, {conversation, turn}}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_turn_text(chat_id, telegram_message_id, text)
      when is_binary(chat_id) and is_binary(telegram_message_id) and is_binary(text) do
    with %Conversation{} = conversation <- find_by_message(chat_id, telegram_message_id),
         %Turn{} = turn <-
           Repo.get_by(Turn,
             conversation_id: conversation.id,
             telegram_message_id: telegram_message_id
           ),
         {:ok, turn} <- turn |> Turn.changeset(%{text: text}) |> Repo.update() do
      {:ok, turn}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_by_message(chat_id, telegram_message_id)
      when is_binary(chat_id) and is_binary(telegram_message_id) do
    Conversation
    |> join(:inner, [c], t in assoc(c, :turns))
    |> where([c, t], c.chat_id == ^chat_id and t.telegram_message_id == ^telegram_message_id)
    |> preload([_c, t], [:linked_delivery, :linked_insight, turns: t])
    |> order_by([c, _t], desc: c.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  def find_by_reply(chat_id, reply_to_message_id)
      when is_binary(chat_id) and is_binary(reply_to_message_id) do
    find_by_message(chat_id, reply_to_message_id)
  end

  def find_by_reply(_chat_id, _reply_to_message_id), do: nil

  def find_by_delivery(delivery_id) when is_binary(delivery_id) do
    Conversation
    |> where([c], c.linked_delivery_id == ^delivery_id)
    |> order_by([c], desc: c.updated_at)
    |> preload(:turns)
    |> limit(1)
    |> Repo.one()
  end

  def open_pending_confirmation(chat_id) when is_binary(chat_id) do
    Conversation
    |> where([c], c.chat_id == ^chat_id and c.status == "awaiting_confirmation")
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
  end

  def mark_awaiting_confirmation(%Conversation{} = conversation, attrs \\ %{}) do
    conversation
    |> Conversation.changeset(%{
      status: "awaiting_confirmation",
      metadata: Map.merge(conversation.metadata || %{}, read_map(attrs, "metadata"))
    })
    |> Repo.update()
  end

  def reopen(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{status: "open"})
    |> Repo.update()
  end

  def close(%Conversation{} = conversation, attrs \\ %{}) do
    conversation
    |> Conversation.changeset(%{
      status: "closed",
      summary: read_string(attrs, "summary", conversation.summary),
      metadata: Map.merge(conversation.metadata || %{}, read_map(attrs, "metadata"))
    })
    |> Repo.update()
  end

  def recent_turns(%Conversation{} = conversation, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)

    Turn
    |> where([t], t.conversation_id == ^conversation.id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def preload(%Conversation{} = conversation),
    do: Repo.preload(conversation, [:turns, :linked_delivery, :linked_insight])

  def latest_delivery_for_chat(chat_id) when is_binary(chat_id) do
    Delivery
    |> where([d], d.channel == "telegram" and d.destination == ^chat_id)
    |> order_by([d], desc: d.inserted_at)
    |> preload(:insight)
    |> limit(1)
    |> Repo.one()
  end

  defp find_open_linked(chat_id, delivery_id, insight_id) do
    if is_nil(delivery_id) and is_nil(insight_id) do
      nil
    else
      threshold = DateTime.add(DateTime.utc_now(), -@linked_idle_seconds, :second)

      base_query =
        Conversation
        |> where([c], c.chat_id == ^chat_id and c.status in ["open", "awaiting_confirmation"])
        |> where([c], c.updated_at >= ^threshold)

      scoped_query =
        cond do
          is_binary(delivery_id) and is_binary(insight_id) ->
            where(
              base_query,
              [c],
              c.linked_delivery_id == ^delivery_id or c.linked_insight_id == ^insight_id
            )

          is_binary(delivery_id) ->
            where(base_query, [c], c.linked_delivery_id == ^delivery_id)

          is_binary(insight_id) ->
            where(base_query, [c], c.linked_insight_id == ^insight_id)

          true ->
            base_query
        end

      scoped_query
      |> order_by([c], desc: c.updated_at)
      |> preload([:linked_delivery, :linked_insight, :turns])
      |> limit(1)
      |> Repo.one()
    end
  end

  defp find_recent_general(chat_id, now) do
    threshold = DateTime.add(now, -@general_idle_seconds, :second)

    Conversation
    |> where([c], c.chat_id == ^chat_id and c.status == "open")
    |> where([c], is_nil(c.linked_delivery_id) and is_nil(c.linked_insight_id))
    |> where([c], c.updated_at >= ^threshold)
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
  end

  defp summarize_recent_turns(conversation_id) do
    Turn
    |> where([t], t.conversation_id == ^conversation_id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(6)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map_join("\n", fn turn ->
      "#{turn.role}: #{String.slice(turn.text || "", 0, 160)}"
    end)
  end

  defp read_string(map, key, default \\ nil) when is_map(map) do
    case fetch(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        default
    end
  end

  defp read_map(map, key) when is_map(map) do
    case fetch(map, key) do
      %{} = value -> value
      _ -> %{}
    end
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
end
