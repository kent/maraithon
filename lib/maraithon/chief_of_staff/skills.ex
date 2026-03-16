defmodule Maraithon.ChiefOfStaff.Skills do
  @moduledoc """
  Registry and helper utilities for AI Chief of Staff skills.
  """

  @process_override_key {__MODULE__, :config_override}

  @default_skill_modules %{
    "followthrough" => Maraithon.ChiefOfStaff.Skills.Followthrough,
    "travel_logistics" => Maraithon.ChiefOfStaff.Skills.TravelLogistics,
    "briefing" => Maraithon.ChiefOfStaff.Skills.Briefing
  }

  @default_enabled_ids ["followthrough", "travel_logistics", "briefing"]

  @doc false
  def put_process_override(config) when is_list(config) do
    Process.put(@process_override_key, config)
    :ok
  end

  @doc false
  def clear_process_override do
    Process.delete(@process_override_key)
    :ok
  end

  def modules do
    config()
    |> Keyword.get(:skill_modules, @default_skill_modules)
  end

  def list_ids do
    modules()
    |> Map.keys()
    |> Enum.sort()
  end

  def get(id) when is_binary(id) do
    Map.get(modules(), id)
  end

  def get!(id) when is_binary(id) do
    case get(id) do
      nil -> raise ArgumentError, "Unknown Chief of Staff skill: #{id}"
      module -> module
    end
  end

  def default_enabled_ids do
    configured =
      config()
      |> Keyword.get(:default_enabled_ids, @default_enabled_ids)

    configured
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> case do
      [] -> @default_enabled_ids
      ids -> Enum.uniq(ids)
    end
  end

  def enabled_ids(config) when is_map(config) do
    config
    |> Map.get("enabled_skills", Map.get(config, :enabled_skills, default_enabled_ids()))
    |> List.wrap()
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> case do
      [] -> default_enabled_ids()
      ids -> Enum.uniq(ids)
    end
  end

  def requirements(skill_ids) when is_list(skill_ids) do
    skill_ids
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> Enum.flat_map(fn id -> get!(id).requirements() end)
    |> Enum.uniq_by(fn requirement ->
      {
        Map.get(requirement, :kind),
        Map.get(requirement, :provider),
        Map.get(requirement, :service),
        Map.get(requirement, :label)
      }
    end)
  end

  def subscriptions(skill_configs, user_id, skill_ids \\ nil)

  def subscriptions(skill_configs, user_id, nil)
      when is_map(skill_configs) and is_binary(user_id) do
    subscriptions(skill_configs, user_id, Map.keys(skill_configs))
  end

  def subscriptions(skill_configs, user_id, skill_ids)
      when is_map(skill_configs) and is_binary(user_id) and is_list(skill_ids) do
    skill_ids
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> Enum.flat_map(fn id ->
      module = get!(id)
      config = Map.get(skill_configs, id, %{})
      module.subscriptions(config, user_id)
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_id(id) when is_binary(id), do: String.trim(id)
  defp normalize_id(id) when is_atom(id), do: id |> Atom.to_string() |> normalize_id()
  defp normalize_id(id), do: id |> to_string() |> normalize_id()

  defp config do
    Process.get(@process_override_key) || Application.get_env(:maraithon, __MODULE__, [])
  end
end
