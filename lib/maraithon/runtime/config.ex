defmodule Maraithon.Runtime.Config do
  @moduledoc """
  Runtime configuration helpers with lightweight validation.
  """

  require Logger

  @runtime_key Maraithon.Runtime
  @process_roles [:web, :runtime, :maintenance, :combined]

  @doc "Returns the configured service role. Unknown values fail closed as maintenance."
  def process_role do
    case Application.get_env(:maraithon, :process_role, :combined) do
      role when role in @process_roles -> role
      _invalid -> :maintenance
    end
  end

  @doc "Returns whether this process may serve the public web application."
  def web_process?, do: process_role() in [:web, :combined]

  @doc "Returns whether this process owns exact and background runtime work."
  def runtime_process?, do: process_role() in [:runtime, :combined]

  @doc "Returns whether this process is restricted to one-shot maintenance work."
  def maintenance_process?, do: process_role() == :maintenance

  @doc """
  Fetch a raw runtime config value with a default.
  """
  def get(key, default) do
    Application.get_env(:maraithon, @runtime_key, [])
    |> Keyword.get(key, default)
  end

  @doc """
  Fetch a positive integer runtime setting.
  Falls back to default when the value is invalid.
  """
  def positive_integer(key, default) when is_integer(default) and default > 0 do
    value = get(key, default)

    if is_integer(value) and value > 0 do
      value
    else
      Logger.warning("Invalid runtime config; using default", key: key, value: inspect(value))
      default
    end
  end

  @doc """
  Returns whether this revision may participate in the exact Agent runtime.

  This is deliberately fail-closed. Production must enable it only after the
  externally verified non-rolling legacy fleet drain described in the rollout
  runbook; process registries and BootGate are not fleet-absence proof.
  """
  def exact_agent_runtime_enabled? do
    get(:exact_agent_runtime_enabled, false) == true
  end

  @doc """
  Returns whether the durable exact-Agent protocols are active.

  Unlike `exact_agent_runtime_ready?/0`, this does not require a local
  coordination Session. Web processes use it before persisting desired state
  for the fixed runtime service to consume.
  """
  def exact_agent_protocol_ready? do
    exact_agent_runtime_enabled?() and
      (Maraithon.Effects.ProtocolCutover.mode() == :exact or test_protocol_bypass?()) and
      coordination_protocol_ready?()
  rescue
    _storage_unavailable -> false
  catch
    :exit, _reason -> false
  end

  @doc """
  Returns whether this process has both the durable protocol and a ready local
  coordination Session. Only runtime-role processes may report local runtime
  readiness.
  """
  def exact_agent_runtime_ready? do
    runtime_process?() and exact_agent_protocol_ready?() and
      (local_coordination_session_ready?() or test_protocol_bypass?())
  rescue
    _storage_unavailable -> false
  catch
    :exit, _reason -> false
  end

  defp coordination_protocol_ready? do
    (multinode_coordination_enabled?() and
       Maraithon.Runtime.Coordination.Protocol.mode() == :active) or
      test_protocol_bypass?()
  end

  defp local_coordination_session_ready? do
    match?({:ok, _session}, Maraithon.Runtime.Coordination.Session.current())
  end

  if Mix.env() == :test do
    def protocol_test_bypass? do
      get(:allow_legacy_effect_protocol_in_test, false) == true
    end

    def coordination_test_session, do: get(:coordination_test_session, nil)
  else
    def protocol_test_bypass?, do: false
    def coordination_test_session, do: nil
  end

  defp test_protocol_bypass?, do: protocol_test_bypass?()

  @doc "Returns whether this revision may participate in DB-owned multi-node coordination."
  def multinode_coordination_enabled? do
    get(:multinode_coordination_enabled, false) == true
  end

  @doc "Fails closed unless config, catalog-attested DB mode, and local ready-last session agree."
  def multinode_coordination_ready? do
    runtime_process?() and multinode_coordination_enabled?() and
      Maraithon.Runtime.Coordination.Protocol.mode() == :active and
      local_coordination_session_ready?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Returns absolute allowed tool root directories.
  """
  def tool_allowed_paths do
    get(:tool_allowed_paths, default_tool_roots())
    |> normalize_paths()
  end

  defp normalize_paths(paths) when is_binary(paths) do
    [paths] |> normalize_paths()
  end

  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalize_paths(_), do: default_tool_roots() |> Enum.map(&Path.expand/1)

  defp default_tool_roots do
    [File.cwd!(), System.tmp_dir!()]
  end
end
