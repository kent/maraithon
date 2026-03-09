defmodule MaraithonWeb.HowItWorksController do
  use MaraithonWeb, :controller

  def index(conn, _params) do
    render(conn, :index,
      page_title: "How it works",
      current_path: ~p"/how-it-works",
      stages: stages(),
      principles: principles()
    )
  end

  defp stages do
    [
      %{
        title: "1. Ingress",
        description:
          "External systems push events via webhook endpoints or API ingress. Each event is normalized and persisted."
      },
      %{
        title: "2. Runtime Scheduling",
        description:
          "The runtime scheduler claims queued work, dispatches agent jobs, and tracks retries, staleness, and delivery state."
      },
      %{
        title: "3. Agent Reasoning",
        description:
          "Agents run their configured behavior using the active LLM provider and persist every effect for durability and auditability."
      },
      %{
        title: "4. Tool Execution",
        description:
          "Tool effects are executed through allow-listed adapters (filesystem, HTTP, connectors), with limits and timeout controls."
      },
      %{
        title: "5. Monitoring",
        description:
          "Admin APIs and dashboard telemetry expose health checks, queue depth, recent failures, and raw logs for operators."
      }
    ]
  end

  defp principles do
    [
      "Durable state in Postgres so agents can resume after restarts",
      "Context modules isolate domain logic from controllers and templates",
      "Explicit auth boundaries for browser admin routes and API token routes",
      "Small composable modules over monolithic controller logic",
      "Operational visibility first: health, queues, failures, and activity trails"
    ]
  end
end
