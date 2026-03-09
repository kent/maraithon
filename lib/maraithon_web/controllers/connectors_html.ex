defmodule MaraithonWeb.ConnectorsHTML do
  use MaraithonWeb, :html

  embed_templates "connectors_html/*"

  def provider_detail_path(provider) when is_map(provider),
    do: "/connectors/#{provider.provider}"

  def provider_subtitle(%{details: details}) when is_list(details) do
    details
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  def provider_subtitle(_provider), do: "No details yet."

  def setup_completion_text(%{setup_status: :configured}), do: "Connector configured"
  def setup_completion_text(_provider), do: "Connector setup required"

  def connection_primary_action(%{provider: "google", status: :connected}),
    do: "Update Google Access"

  def connection_primary_action(%{provider: "google"}), do: "Connect Google"

  def connection_primary_action(%{provider: "telegram", status: :connected}),
    do: "Reconnect Telegram"

  def connection_primary_action(%{provider: "telegram"}), do: "Link Telegram"
  def connection_primary_action(%{status: :connected}), do: "Reconnect"
  def connection_primary_action(_provider), do: "Connect"

  def connection_status_label(:connected), do: "connected"
  def connection_status_label(:partial), do: "partial"
  def connection_status_label(:missing_scope), do: "needs scope"
  def connection_status_label(:not_configured), do: "not configured"
  def connection_status_label(:unknown), do: "unknown"
  def connection_status_label(_status), do: "disconnected"

  def connection_status_badge_class(:connected),
    do:
      "inline-flex items-center rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-medium text-emerald-800"

  def connection_status_badge_class(:partial),
    do:
      "inline-flex items-center rounded-full bg-amber-100 px-2.5 py-1 text-xs font-medium text-amber-800"

  def connection_status_badge_class(:missing_scope),
    do:
      "inline-flex items-center rounded-full bg-amber-100 px-2.5 py-1 text-xs font-medium text-amber-800"

  def connection_status_badge_class(:not_configured),
    do:
      "inline-flex items-center rounded-full bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-700"

  def connection_status_badge_class(:unknown),
    do:
      "inline-flex items-center rounded-full bg-purple-100 px-2.5 py-1 text-xs font-medium text-purple-700"

  def connection_status_badge_class(_status),
    do:
      "inline-flex items-center rounded-full bg-rose-100 px-2.5 py-1 text-xs font-medium text-rose-700"

  def setup_status_label(:configured), do: "configured"
  def setup_status_label(:incomplete), do: "needs setup"
  def setup_status_label(_status), do: "unknown"

  def setup_status_badge_class(:configured),
    do:
      "inline-flex items-center rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-medium text-emerald-800"

  def setup_status_badge_class(:incomplete),
    do:
      "inline-flex items-center rounded-full bg-amber-100 px-2.5 py-1 text-xs font-medium text-amber-800"

  def setup_status_badge_class(_status),
    do:
      "inline-flex items-center rounded-full bg-slate-200 px-2.5 py-1 text-xs font-medium text-slate-700"

  def callback_badge_class(true),
    do:
      "inline-flex items-center rounded-full bg-indigo-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-indigo-700"

  def callback_badge_class(false),
    do:
      "inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-600"

  def env_status_label(true, _required), do: "present"
  def env_status_label(false, true), do: "missing"
  def env_status_label(false, false), do: "optional"

  def env_status_badge_class(true, _required),
    do:
      "inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-emerald-800"

  def env_status_badge_class(false, true),
    do:
      "inline-flex items-center rounded-full bg-rose-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-rose-800"

  def env_status_badge_class(false, false),
    do:
      "inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-600"

  def connection_token_summary(token) when is_map(token) do
    scopes =
      case Map.get(token, :scopes) || Map.get(token, "scopes") do
        values when is_list(values) and values != [] -> "Scopes: #{Enum.join(values, ", ")}"
        _ -> nil
      end

    expires =
      case Map.get(token, :expires_at) || Map.get(token, "expires_at") do
        %DateTime{} = value -> "Expires #{format_datetime(value)}"
        %NaiveDateTime{} = value -> "Expires #{format_datetime(value)}"
        _ -> nil
      end

    [scopes, expires]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No additional token metadata"
      values -> Enum.join(values, " • ")
    end
  end

  def format_datetime(nil), do: "never"
  def format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  def format_datetime(%NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  def format_datetime(value) when is_binary(value), do: value
  def format_datetime(_value), do: "unknown"

  def endpoint_url do
    MaraithonWeb.Endpoint.url()
  end

  attr :provider, :atom, required: true

  def oauth_logo(%{provider: :google} = assigns) do
    ~H"""
    <div class="h-10 w-10 overflow-hidden rounded-xl border border-slate-200 bg-white p-1.5 shadow-sm">
      <img src="https://www.google.com/favicon.ico" alt="Google" class="h-full w-full object-contain" />
    </div>
    """
  end

  def oauth_logo(%{provider: :github} = assigns) do
    ~H"""
    <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-950 text-xs font-semibold text-white shadow-sm">
      GH
    </div>
    """
  end

  def oauth_logo(%{provider: :linear} = assigns) do
    ~H"""
    <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-900 text-xs font-semibold text-white shadow-sm">
      LN
    </div>
    """
  end

  def oauth_logo(%{provider: :notion} = assigns) do
    ~H"""
    <div class="flex h-10 w-10 items-center justify-center rounded-xl border border-slate-300 bg-white text-xs font-semibold text-slate-900 shadow-sm">
      N
    </div>
    """
  end

  def oauth_logo(%{provider: :telegram} = assigns) do
    ~H"""
    <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-sky-500 text-xs font-semibold text-white shadow-sm">
      TG
    </div>
    """
  end

  def oauth_logo(assigns) do
    ~H"""
    <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-200 text-xs font-semibold text-slate-700">
      ?
    </div>
    """
  end
end
