defmodule MaraithonWeb.Router do
  use MaraithonWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MaraithonWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check endpoint
  scope "/health", MaraithonWeb do
    get "/", HealthController, :index
  end

  # Web UI - Dashboard
  scope "/", MaraithonWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
  end

  # API v1
  scope "/api/v1", MaraithonWeb do
    pipe_through :api

    # Agent management
    post "/agents", AgentController, :create
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show
    post "/agents/:id/ask", AgentController, :ask
    post "/agents/:id/stop", AgentController, :stop
    get "/agents/:id/events", AgentController, :events
    get "/agents/:id/spend", AgentController, :spend

    # Spend tracking
    get "/spend", AgentController, :total_spend

    # System health with details
    get "/health", HealthController, :detailed

    # Event ingress - external systems publish events here
    post "/events", EventController, :publish
    get "/events/topics", EventController, :topics
  end

  # Webhooks from external services (connectors)
  scope "/webhooks", MaraithonWeb do
    pipe_through :api

    post "/github", WebhookController, :github
    # Future: post "/slack", WebhookController, :slack
    # Future: post "/google/calendar", WebhookController, :google_calendar
  end
end
