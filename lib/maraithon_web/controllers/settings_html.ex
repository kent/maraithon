defmodule MaraithonWeb.SettingsHTML do
  use MaraithonWeb, :html

  embed_templates "settings_html/*"

  def setting_badge_class(true),
    do:
      "inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-emerald-800"

  def setting_badge_class(false),
    do:
      "inline-flex items-center rounded-full bg-rose-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-rose-800"

  def setting_badge_label(true), do: "present"
  def setting_badge_label(false), do: "missing"
end
