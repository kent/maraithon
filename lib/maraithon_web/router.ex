defmodule MaraithonWeb.Router do
  use MaraithonWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check - no auth required
  scope "/", MaraithonWeb do
    get "/health", HealthController, :index
    get "/", HealthController, :index
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

    # System health with details
    get "/health", HealthController, :detailed
  end
end
