defmodule MaraithonWeb.AdminNavigation do
  @moduledoc """
  Shared top-level navigation for the admin control center.
  """

  use MaraithonWeb, :html

  @tabs [
    %{label: "Dashboard", path: "/"},
    %{label: "Connectors", path: "/connectors"},
    %{label: "How it works", path: "/how-it-works"},
    %{label: "Settings", path: "/settings"}
  ]

  attr :current_path, :string, default: "/"

  def admin_tabs(assigns) do
    assigns =
      assigns
      |> assign(:tabs, @tabs)
      |> assign(:normalized_path, normalize_path(assigns.current_path))

    ~H"""
    <nav class="bg-indigo-600">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div class="flex h-16 items-center justify-between">
          <div class="flex items-center">
            <div class="flex-shrink-0">
              <span class="text-2xl font-bold text-white">Maraithon</span>
            </div>
            <div class="hidden md:block">
              <div class="ml-10 flex items-baseline space-x-3">
                <a
                  :for={tab <- @tabs}
                  href={tab.path}
                  class={tab_link_class(@normalized_path, tab.path)}
                >
                  <%= tab.label %>
                </a>
              </div>
            </div>
          </div>
          <div class="hidden md:block">
            <div class="ml-4 flex items-center md:ml-6">
              <span class="text-sm text-indigo-200">Long-lived LLM Agent Runtime</span>
            </div>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  defp normalize_path(nil), do: "/"

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.split("?", parts: 2)
    |> List.first()
    |> case do
      nil -> "/"
      "" -> "/"
      value -> value
    end
  end

  defp normalize_path(_path), do: "/"

  defp tab_link_class(current_path, tab_path) do
    base = "rounded-md px-3 py-2 text-sm font-medium"

    if active_tab?(current_path, tab_path) do
      base <> " bg-indigo-700 text-white"
    else
      base <> " text-indigo-100 hover:bg-indigo-500 hover:text-white"
    end
  end

  defp active_tab?(path, "/"), do: path in ["/", "/admin"]
  defp active_tab?(path, tab_path), do: path == tab_path
end
