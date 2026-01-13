defmodule MaraithonWeb.CoreComponents do
  @moduledoc """
  Core UI components for MaraithonWeb.
  """

  use Phoenix.Component

  @doc """
  Renders flash notices.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 right-4 z-50 space-y-2">
      <%= if info = @flash["info"] do %>
        <div class="rounded-md bg-blue-50 p-4 shadow-lg">
          <div class="flex">
            <div class="ml-3">
              <p class="text-sm font-medium text-blue-800"><%= info %></p>
            </div>
          </div>
        </div>
      <% end %>
      <%= if error = @flash["error"] do %>
        <div class="rounded-md bg-red-50 p-4 shadow-lg">
          <div class="flex">
            <div class="ml-3">
              <p class="text-sm font-medium text-red-800"><%= error %></p>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a badge with status colors.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    color_class =
      case assigns.status do
        "running" -> "bg-green-100 text-green-800"
        "stopped" -> "bg-gray-100 text-gray-800"
        "error" -> "bg-red-100 text-red-800"
        _ -> "bg-yellow-100 text-yellow-800"
      end

    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <span class={"inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium #{@color_class}"}>
      <%= @status %>
    </span>
    """
  end
end
