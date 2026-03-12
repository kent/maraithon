defmodule MaraithonWeb.AdminNavigation do
  @moduledoc """
  Shared top-level navigation for the admin control center.
  """

  use MaraithonWeb, :html

  @tabs [
    %{label: "Dashboard", path: "/dashboard"},
    %{label: "Agents", path: "/agents"},
    %{label: "Connectors", path: "/connectors"},
    %{label: "How it works", path: "/how-it-works"}
  ]

  attr :current_path, :string, default: "/dashboard"
  attr :current_user, :map, default: nil

  def admin_tabs(assigns) do
    tabs =
      if admin_user?(assigns.current_user) do
        @tabs ++ [%{label: "Settings", path: "/settings"}]
      else
        @tabs
      end

    assigns =
      assigns
      |> assign(:tabs, tabs)
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
            <div class="ml-4 flex items-center gap-4 md:ml-6">
              <%= if @current_user do %>
                <span class="text-sm text-indigo-100"><%= @current_user.email %></span>
                <.form for={%{}} action={~p"/logout"} method="post">
                  <input type="hidden" name="_method" value="delete" />
                  <button
                    type="submit"
                    class="rounded-md border border-indigo-300 px-2.5 py-1 text-xs font-medium text-white hover:bg-indigo-500"
                  >
                    Logout
                  </button>
                </.form>
              <% end %>
              <span class="text-sm text-indigo-200">Long-lived LLM Agent Runtime</span>
            </div>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  defp normalize_path(nil), do: "/dashboard"

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.split("?", parts: 2)
    |> List.first()
    |> case do
      nil -> "/dashboard"
      "" -> "/dashboard"
      value -> value
    end
  end

  defp normalize_path(_path), do: "/dashboard"

  defp tab_link_class(current_path, tab_path) do
    base = "rounded-md px-3 py-2 text-sm font-medium"

    if active_tab?(current_path, tab_path) do
      base <> " bg-indigo-700 text-white"
    else
      base <> " text-indigo-100 hover:bg-indigo-500 hover:text-white"
    end
  end

  defp active_tab?(path, "/dashboard"), do: path in ["/dashboard", "/admin"]
  defp active_tab?(path, "/agents"), do: path in ["/agents", "/agents/new"]
  defp active_tab?(path, tab_path), do: path == tab_path

  defp admin_user?(%{is_admin: true}), do: true
  defp admin_user?(_), do: false
end
