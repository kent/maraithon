defmodule MaraithonWeb.Router do
  use MaraithonWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug MaraithonWeb.Plugs.FetchCurrentUser
    plug :fetch_live_flash
    plug :put_root_layout, html: {MaraithonWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_authenticated_user do
    plug MaraithonWeb.Plugs.RequireAuthenticatedUser
  end

  pipeline :browser_admin do
    plug MaraithonWeb.Plugs.RequireAdmin
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug MaraithonWeb.Plugs.RequireApiToken
  end

  # Health check endpoint
  scope "/health", MaraithonWeb do
    get "/", HealthController, :index
  end

  # Public auth routes
  scope "/", MaraithonWeb do
    pipe_through :browser

    get "/", HomeController, :index
    post "/auth/magic-link", SessionController, :create_magic_link
    get "/auth/magic/:token", SessionController, :consume_magic_link
    delete "/logout", SessionController, :delete
  end

  # OAuth routes
  scope "/auth", MaraithonWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/google", OAuthController, :google
    get "/google/callback", OAuthController, :google_callback
    get "/github", OAuthController, :github
    get "/github/callback", OAuthController, :github_callback
    get "/slack", OAuthController, :slack
    get "/slack/callback", OAuthController, :slack_callback
    get "/linear", OAuthController, :linear
    get "/linear/callback", OAuthController, :linear_callback
    get "/notion", OAuthController, :notion
    get "/notion/callback", OAuthController, :notion_callback
  end

  # Web UI - authenticated user pages
  scope "/", MaraithonWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/connectors", ConnectorsController, :index
    get "/connectors/:provider", ConnectorsController, :show
    post "/connectors/:provider/disconnect", ConnectorsController, :disconnect
    get "/conenctors", ConnectorsController, :legacy_redirect
    get "/how-it-works", HowItWorksController, :index
  end

  # Web UI - admin-only pages
  scope "/", MaraithonWeb do
    pipe_through [:browser, :browser_admin]

    get "/admin", AdminPageController, :index
    get "/settings", SettingsController, :index
  end

  scope "/", MaraithonWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: [{MaraithonWeb.LiveUserAuth, :ensure_authenticated}] do
      live "/agents/new", AgentBuilderLive, :new
      live "/dashboard", DashboardLive, :index
    end
  end

  # API v1
  scope "/api/v1", MaraithonWeb do
    pipe_through [:api, :api_auth]

    # Agent management
    post "/agents", AgentController, :create
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show
    patch "/agents/:id", AgentController, :update
    delete "/agents/:id", AgentController, :delete
    post "/agents/:id/start", AgentController, :start
    post "/agents/:id/ask", AgentController, :ask
    post "/agents/:id/stop", AgentController, :stop
    get "/agents/:id/events", AgentController, :events
    get "/agents/:id/spend", AgentController, :spend
    get "/admin/dashboard", AdminController, :dashboard
    get "/admin/agents/:id/inspection", AdminController, :agent_inspection
    get "/admin/fly/logs", AdminController, :fly_logs
    get "/admin/connections", AdminController, :connections
    delete "/admin/connections/:provider", AdminController, :disconnect_connection

    # Spend tracking
    get "/spend", AgentController, :total_spend

    # System health with details
    get "/health", HealthController, :detailed

    # Event ingress - external systems publish events here
    post "/events", EventController, :publish
    get "/events/topics", EventController, :topics

    # Integration sync endpoints
    post "/integrations/notaui/sync", NotauiController, :sync
  end

  # Webhooks from external services (connectors)
  scope "/webhooks", MaraithonWeb do
    pipe_through :api

    post "/github", WebhookController, :github
    post "/google/calendar", WebhookController, :google_calendar
    post "/google/gmail", WebhookController, :google_gmail
    post "/slack", WebhookController, :slack
    get "/whatsapp", WebhookController, :whatsapp
    post "/whatsapp", WebhookController, :whatsapp
    post "/linear", WebhookController, :linear
    post "/telegram/:secret_path", WebhookController, :telegram
  end
end
