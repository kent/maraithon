defmodule Maraithon.Connectors.Connector do
  @moduledoc """
  Behavior for external service connectors.

  A connector bridges external services (GitHub, Slack, etc.) to the agent
  framework by:

  1. Receiving webhooks from external services
  2. Validating/authenticating requests
  3. Normalizing events to a standard format
  4. Publishing to PubSub topics for agents to consume

  ## Implementing a Connector

      defmodule MyApp.Connectors.GitHub do
        @behaviour Maraithon.Connectors.Connector

        @impl true
        def handle_webhook(conn, params) do
          # Parse the webhook, return normalized event
          {:ok, "github:owner/repo", %{type: "issue_opened", ...}}
        end

        @impl true
        def verify_signature(conn, payload) do
          # Verify webhook signature
          :ok
        end
      end

  ## Standard Event Format

  All connectors should normalize events to:

      %{
        type: "event_type",           # e.g., "issue_opened", "message_received"
        source: "connector_name",     # e.g., "github", "slack"
        timestamp: DateTime.t(),
        data: %{...},                 # Event-specific data
        raw: %{...}                   # Original payload (optional)
      }
  """

  @type event :: %{
          type: String.t(),
          source: String.t(),
          timestamp: DateTime.t(),
          data: map(),
          raw: map() | nil
        }

  @doc """
  Handle an incoming webhook request.

  Should parse the webhook payload and return a normalized event
  with the topic to publish to.

  Returns:
    - `{:ok, topic, event}` - Event parsed successfully
    - `{:error, reason}` - Failed to parse or invalid webhook
    - `{:ignore, reason}` - Valid webhook but should not be published (e.g., ping)
  """
  @callback handle_webhook(conn :: Plug.Conn.t(), params :: map()) ::
              {:ok, topic :: String.t(), event()}
              | {:error, reason :: term()}
              | {:ignore, reason :: String.t()}

  @doc """
  Verify the webhook signature/authenticity.

  Called before handle_webhook to ensure the request is legitimate.

  Returns:
    - `:ok` - Signature valid
    - `{:error, reason}` - Signature invalid
  """
  @callback verify_signature(conn :: Plug.Conn.t(), raw_body :: binary()) ::
              :ok | {:error, reason :: term()}

  @doc """
  Helper to publish an event to PubSub.
  """
  def publish(topic, event) do
    Phoenix.PubSub.broadcast(
      Maraithon.PubSub,
      topic,
      {:pubsub_event, topic, event}
    )
  end

  @doc """
  Build a standard event struct.
  """
  def build_event(type, source, data, raw \\ nil) do
    %{
      type: type,
      source: source,
      timestamp: DateTime.utc_now(),
      data: data,
      raw: raw
    }
  end
end
