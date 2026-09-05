defmodule Maraithon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Maraithon.Vault.validate_config!()
    :ok = Maraithon.DurablePayloadBinding.validate_config!()

    # OpenTelemetry auto-instrumentation. Must run before the supervisor starts
    # so :telemetry handlers are attached before the first request. No-op for
    # export when traces_exporter is :none (default dev/test).
    # Bandit creates its span before Endpoint plugs run. Never allowlist the
    # Telegram secret-token header (or other request credentials) into spans.
    OpentelemetryBandit.setup(request_headers: [])
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:maraithon, :repo])

    children = children_for_role(Maraithon.Runtime.Config.process_role())

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options. Intensity is raised above
    # the OTP default so a flapping child (e.g. during a DB outage) backs off
    # via its own resilience machinery instead of shutting the node down.
    opts = [strategy: :one_for_one, name: Maraithon.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def children_for_role(:web) do
    foundation_children() ++
      service_support_children() ++ web_runtime_support_children() ++ [MaraithonWeb.Endpoint]
  end

  def children_for_role(role) when role in [:runtime, :combined] do
    foundation_children() ++
      [
        # Stable exact-Agent guardian. It must outlive Runtime.Supervisor so an
        # AgentSupervisor subtree restart/shutdown still yields the original
        # monitor's exact DOWN proof.
        Supervisor.child_spec(Maraithon.Runtime.AgentWatcher, shutdown: 30_000),
        Maraithon.Accounts.AdminBootstrap
      ] ++
      service_support_children() ++
      [
        # Legacy todo ingestion becomes dormant under multinode coordination,
        # but remains available for the combined development topology.
        {Task.Supervisor, name: Maraithon.Todos.IngestionTaskSupervisor},
        Maraithon.Todos.IngestionCoordinator,
        # Owns exact Agents, leases, schedulers, and every durable queue poller.
        Maraithon.Runtime.Supervisor,
        # Cloud Run runtime instances still need a health/control listener.
        MaraithonWeb.Endpoint
      ]
  end

  # Release maintenance commands start the Repo they need with
  # Ecto.Migrator.with_repo/2. Starting the application in this role must not
  # accidentally create a server, a Session, or any background ownership.
  def children_for_role(:maintenance), do: []

  defp foundation_children do
    [
      MaraithonWeb.Telemetry,
      # Encryption vault (must start before Repo for encrypted fields)
      Maraithon.Vault,
      Maraithon.Repo,
      # A zero proof is an irreversible PostgreSQL write fence. Refuse to
      # start any new web/runtime writer still configured to use that tag.
      Maraithon.KeyRetirementBootGuard
    ]
  end

  defp service_support_children do
    [
      {DNSCluster, query: Application.get_env(:maraithon, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Maraithon.PubSub},
      # APNs requires HTTP/2; one small dedicated pool per Apple host.
      {Finch,
       name: Maraithon.Push.Finch,
       pools: %{
         "https://api.push.apple.com" => [protocols: [:http2], count: 1],
         "https://api.sandbox.push.apple.com" => [protocols: [:http2], count: 1]
       }},
      Maraithon.LogBuffer,
      Maraithon.ContextCache,
      Maraithon.UserIdentity,
      Maraithon.TelegramAssistant.LivenessSupervisor,
      Maraithon.TelegramAssistant.RunStreamPreview,
      # Per-chat inbound-message workers: keep webhook acks fast and serialize
      # concurrent messages within a chat.
      {Registry, keys: :unique, name: Maraithon.TelegramAssistant.ChatRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Maraithon.TelegramAssistant.ChatSupervisor},
      {Registry, keys: :unique, name: Maraithon.AssistantChat.ThreadRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Maraithon.AssistantChat.ThreadSupervisor}
    ]
  end

  defp web_runtime_support_children do
    [
      # These are bounded request-path dependencies, not exact-runtime owners.
      # The empty Registry also keeps status and lifecycle lookups total on web.
      {Registry, keys: :unique, name: Maraithon.Runtime.AgentRegistry},
      {Task.Supervisor, name: Maraithon.Runtime.EffectSupervisor},
      {Task.Supervisor, name: Maraithon.Runtime.ToolCallSupervisor},
      Maraithon.Runtime.Effects.LLMRateLimiter
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MaraithonWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
