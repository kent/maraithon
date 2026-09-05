defmodule MaraithonWeb.EventController do
  use MaraithonWeb, :controller

  alias Maraithon.AgentSubscriptions
  alias Maraithon.Runtime.AgentDirectiveIngress
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  require Logger

  @doc """
  Publish an event to PubSub for agents to receive.

  POST /api/v1/events
  {
    "topic": "calendar",
    "payload": { ... }
  }

  This is the ingress point for external systems to send events
  to agents subscribed to topics.
  """
  def publish(conn, params) do
    payload = params["payload"] || %{}

    with {:ok, topic} <- normalize_topic(params["topic"]),
         {:ok, dedupe_key} <- event_dedupe_key(conn, params) do
      publish(conn, topic, payload, dedupe_key)
    else
      {:error, :topic_required} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "topic is required"})

      {:error, :invalid_topic} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "topic is invalid"})

      {:error, :invalid_idempotency_key} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "idempotency key is invalid"})
    end
  end

  defp publish(conn, topic, payload, dedupe_key) do
    result =
      if RuntimeConfig.exact_agent_runtime_enabled?() do
        # Web and runtime processes intentionally do not share an in-memory
        # PubSub cluster in production. Persist one Directive per subscriber;
        # the runtime's local notification remains only a latency hint.
        AgentDirectiveIngress.publish_topic(topic, payload, dedupe_key: dedupe_key)
      else
        :ok =
          Phoenix.PubSub.broadcast(
            Maraithon.PubSub,
            topic,
            {:pubsub_event, topic, payload}
          )

        {:ok, %{accepted_count: nil}}
      end

    case result do
      {:ok, ingress} ->
        Logger.info("Event published",
          topic: topic,
          accepted_count: ingress.accepted_count
        )

        conn
        |> put_status(:accepted)
        |> json(%{status: "published", topic: topic})

      {:error, reason} ->
        publish_error(conn, topic, reason)
    end
  end

  defp publish_error(conn, _topic, reason)
       when reason in [:invalid_ingress, :invalid_ingress_payload, :invalid_ingress_dedupe_key] do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "event payload is invalid"})
  end

  defp publish_error(conn, _topic, :directive_idempotency_conflict) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "idempotency key conflicts with an earlier event"})
  end

  defp publish_error(conn, topic, reason) do
    Logger.warning("Event persistence failed",
      topic: topic,
      failure_code: Maraithon.Redaction.error_class(reason)
    )

    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "event persistence unavailable"})
  end

  defp normalize_topic(topic) when is_binary(topic) do
    normalized = String.trim(topic)

    cond do
      normalized == "" -> {:error, :topic_required}
      byte_size(normalized) <= 500 and String.valid?(normalized) -> {:ok, normalized}
      true -> {:error, :invalid_topic}
    end
  end

  defp normalize_topic(nil), do: {:error, :topic_required}
  defp normalize_topic(_topic), do: {:error, :invalid_topic}

  # Callers may make delivery retry-safe with either Idempotency-Key or the
  # equivalent JSON field. Without one, preserve the endpoint's historical
  # semantics: each accepted request is a distinct event.
  defp event_dedupe_key(conn, params) do
    header_values = get_req_header(conn, "idempotency-key")
    param_value = params["idempotency_key"]

    candidate =
      case {header_values, param_value} do
        {[header], nil} -> header
        {[], nil} -> Ecto.UUID.generate()
        {[], param} -> param
        _ambiguous -> :invalid
      end

    case candidate do
      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" and byte_size(value) <= 200 and String.valid?(value) do
          {:ok, "api_event:#{value}"}
        else
          {:error, :invalid_idempotency_key}
        end

      _invalid ->
        {:error, :invalid_idempotency_key}
    end
  end

  @doc """
  List all topics that have active subscribers.
  Useful for debugging and observability.
  """
  def topics(conn, _params) do
    topics =
      AgentSubscriptions.list_active_topic_summaries()
      |> Enum.map(&serialize_topic_summary/1)

    conn
    |> json(%{
      count: length(topics),
      topics: topics
    })
  end

  defp serialize_topic_summary(summary) do
    %{
      topic: summary.topic,
      subscriber_count: summary.subscriber_count,
      agent_ids: summary.agent_ids,
      user_ids: summary.user_ids,
      project_ids: summary.project_ids,
      updated_at: format_datetime(summary.updated_at)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
