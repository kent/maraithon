defmodule Maraithon.Briefs do
  @moduledoc """
  Persistence and Telegram delivery for chief-of-staff briefing messages.
  """

  import Ecto.Query

  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias MaraithonWeb.Endpoint

  require Logger

  @open_statuses ["pending", "failed"]

  def record_many(user_id, agent_id, briefs)
      when is_binary(user_id) and is_binary(agent_id) and is_list(briefs) do
    items =
      briefs
      |> Enum.map(&record(user_id, agent_id, &1))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, brief} -> brief end)

    {:ok, items}
  end

  def record(user_id, agent_id, attrs)
      when is_binary(user_id) and is_binary(agent_id) and is_map(attrs) do
    normalized = normalize_attrs(attrs, user_id, agent_id)

    case Repo.get_by(Brief, user_id: user_id, dedupe_key: normalized["dedupe_key"]) do
      nil ->
        %Brief{}
        |> Brief.changeset(normalized)
        |> Repo.insert()

      %Brief{} = brief ->
        update_attrs =
          normalized
          |> Map.drop(["user_id", "agent_id", "dedupe_key"])
          |> Map.put("status", preserve_status(brief.status))
          |> Map.put(
            "provider_message_id",
            if(brief.status == "sent", do: brief.provider_message_id)
          )
          |> Map.put("sent_at", if(brief.status == "sent", do: brief.sent_at))
          |> Map.put("error_message", if(brief.status == "failed", do: brief.error_message))

        brief
        |> Brief.changeset(update_attrs)
        |> Repo.update()
    end
  end

  def list_pending(limit \\ 20) when is_integer(limit) and limit > 0 do
    Brief
    |> where([b], b.status in ^@open_statuses)
    |> order_by([b], asc: b.scheduled_for, asc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 20)

    Brief
    |> where([b], b.user_id == ^user_id)
    |> order_by([b], desc: b.scheduled_for, desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def dispatch_telegram_batch(opts \\ []) do
    if telegram_module().configured?() do
      batch_size = Keyword.get(opts, :batch_size, 10)

      list_pending(batch_size)
      |> Enum.reduce(%{sent: 0, failed: 0, skipped: 0}, fn brief, acc ->
        case send_brief(brief) do
          :ok -> %{acc | sent: acc.sent + 1}
          :skip -> %{acc | skipped: acc.skipped + 1}
          {:error, _reason} -> %{acc | failed: acc.failed + 1}
        end
      end)
    else
      %{sent: 0, failed: 0, skipped: 0}
    end
  end

  def send_brief(%Brief{} = brief) do
    case TelegramAssistant.deliver_brief(brief) do
      :ok ->
        :ok

      {:fallback, :disabled} ->
        case telegram_destination(brief.user_id) do
          nil ->
            :skip

          destination ->
            payload = telegram_payload(brief)

            case telegram_module().send_message(
                   destination,
                   payload.text,
                   parse_mode: "HTML",
                   reply_markup: payload.reply_markup
                 ) do
              {:ok, result} ->
                message_id = read_message_id(result)

                brief
                |> Ecto.Changeset.change(%{
                  status: "sent",
                  sent_at: DateTime.utc_now(),
                  provider_message_id: message_id,
                  error_message: nil
                })
                |> Repo.update()

                :ok

              {:error, reason} ->
                Logger.warning("Failed to send Telegram brief",
                  reason: inspect(reason),
                  brief_id: brief.id
                )

                brief
                |> Ecto.Changeset.change(%{
                  status: "failed",
                  error_message: inspect(reason)
                })
                |> Repo.update()

                {:error, reason}
            end
        end

      {:error, reason} ->
        Logger.warning("Failed to broker Telegram brief",
          reason: inspect(reason),
          brief_id: brief.id
        )

        {:error, reason}
    end
  end

  def telegram_payload(%Brief{} = brief) do
    %{
      text: render_telegram_text(brief),
      reply_markup: brief_reply_markup(brief)
    }
  end

  defp normalize_attrs(attrs, user_id, agent_id) do
    %{
      "user_id" => user_id,
      "agent_id" => agent_id,
      "cadence" => read_string(attrs, "cadence", "morning"),
      "title" => read_string(attrs, "title", "Chief of staff brief"),
      "summary" => read_string(attrs, "summary", "Review the latest loop summary."),
      "body" =>
        read_string(attrs, "body", "Open Maraithon to review the latest follow-through summary."),
      "status" => read_string(attrs, "status", "pending"),
      "scheduled_for" => read_datetime(attrs, "scheduled_for") || DateTime.utc_now(),
      "dedupe_key" => read_string(attrs, "dedupe_key", Ecto.UUID.generate()),
      "metadata" => read_map(attrs, "metadata")
    }
  end

  defp preserve_status("sent"), do: "sent"
  defp preserve_status(_), do: "pending"

  defp telegram_destination(user_id) do
    case ConnectedAccounts.get(user_id, "telegram") do
      %{status: "connected", external_account_id: destination}
      when is_binary(destination) and destination != "" ->
        destination

      %{status: "connected", metadata: %{"chat_id" => destination}}
      when is_binary(destination) and destination != "" ->
        destination

      _ ->
        nil
    end
  end

  defp render_telegram_text(%Brief{} = brief) do
    cadence_label = cadence_label(brief.cadence)
    scheduled_at = Calendar.strftime(brief.scheduled_for, "%Y-%m-%d %H:%M UTC")

    """
    <b>#{safe(cadence_label)}</b>
    <b>#{safe(brief.title)}</b>

    #{safe(brief.summary)}

    #{safe(brief.body)}

    <i>Scheduled for #{safe(scheduled_at)}</i>
    """
    |> String.trim()
  end

  defp brief_reply_markup(%Brief{} = brief) do
    buttons = [
      [
        %{"text" => "Open Dashboard", "url" => "#{Endpoint.url()}/dashboard"}
      ]
    ]

    case brief.metadata do
      %{"agent_behavior" => behavior} when is_binary(behavior) and behavior != "" ->
        %{
          "inline_keyboard" =>
            buttons ++
              [
                [
                  %{
                    "text" => "Tune Agent",
                    "url" =>
                      "#{Endpoint.url()}/agents/new?behavior=#{URI.encode_www_form(behavior)}"
                  }
                ]
              ]
        }

      _ ->
        %{"inline_keyboard" => buttons}
    end
  end

  defp cadence_label("morning"), do: "Morning brief"
  defp cadence_label("end_of_day"), do: "End-of-day debt"
  defp cadence_label("weekly_review"), do: "Weekly review"
  defp cadence_label(other), do: other

  defp safe(value) when is_binary(value),
    do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

  defp safe(value), do: value |> to_string() |> safe()

  defp read_message_id(%{"message_id" => value}) when is_integer(value),
    do: Integer.to_string(value)

  defp read_message_id(%{"message_id" => value}) when is_binary(value), do: value
  defp read_message_id(_), do: nil

  defp telegram_module do
    Application.get_env(:maraithon, :briefs, [])
    |> Keyword.get(:telegram_module, Telegram)
  end

  defp read_string(map, key, default) when is_map(map) do
    case fetch_attr(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp read_map(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_datetime(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      %DateTime{} = value ->
        value

      %NaiveDateTime{} = value ->
        DateTime.from_naive!(value, "Etc/UTC")

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_attr(map, key) when is_map(map) and is_binary(key) do
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
