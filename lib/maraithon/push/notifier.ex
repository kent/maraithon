defmodule Maraithon.Push.Notifier do
  @moduledoc """
  The single "notify this user on their phone" entry point.

  Fans one notification out to every active device the user has registered,
  pruning tokens APNs reports dead. Callers decide *whether* to notify (the
  PushBroker's dedupe/budget/quiet-hours machinery); this module only
  decides *how*.
  """

  alias Maraithon.Push.APNS
  alias Maraithon.Push.Devices

  require Logger

  @doc """
  True when this user's proactive delivery should go to their phone instead
  of Telegram: the global switch is on, APNs is configured, and the user has
  at least one active registered device. The per-user device gate is what
  makes the hard cutover safe — a user with no phone registered keeps
  Telegram until the day they sign in on the app.
  """
  def enabled_for_user?(user_id) do
    enabled?() and APNS.configured?() and Devices.any_active?(user_id)
  end

  @doc """
  Sends an alert to every active device.

  Returns `{:ok, delivered_count}` when at least one device accepted,
  `{:error, :no_devices}` when none are registered, and
  `{:error, :undelivered}` when every send failed (dead tokens are pruned
  along the way; transient failures surface so the broker's cycle retries).
  """
  def notify(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, prepared} <- prepare(user_id, attrs) do
      deliver_prepared(prepared)
    end
  end

  @doc false
  def prepare(user_id, attrs)
      when is_binary(user_id) and byte_size(user_id) <= 1_280 and is_map(attrs) do
    try do
      case Devices.active_for_user(user_id) do
        [] ->
          {:error, :no_devices}

        devices ->
          case Process.whereis(Maraithon.Runtime.ToolCallSupervisor) do
            pid when is_pid(pid) ->
              {:ok,
               {:prepared_notification, user_id, Enum.take(devices, 5), APNS.payload(attrs),
                attrs[:collapse_id]}}

            _missing ->
              {:error, :preparation_failed}
          end
      end
    rescue
      _exception -> {:error, :preparation_failed}
    catch
      _kind, _reason -> {:error, :preparation_failed}
    end
  end

  def prepare(_user_id, _attrs), do: {:error, :preparation_failed}

  @doc false
  def deliver_prepared(prepared, opts \\ [])

  def deliver_prepared(
        {:prepared_notification, user_id, devices, payload, collapse_id},
        opts
      )
      when is_binary(user_id) and byte_size(user_id) <= 1_280 and is_list(devices) and
             is_map(payload) and is_list(opts) do
    devices = Enum.take(devices, 5)

    outcomes =
      Task.Supervisor.async_stream_nolink(
        Maraithon.Runtime.ToolCallSupervisor,
        devices,
        fn device ->
          result =
            try do
              APNS.send(device.device_token, payload,
                collapse_id: collapse_id,
                environment: device.environment
              )
            rescue
              _exception -> {:error, :delivery_unknown}
            catch
              _kind, _reason -> {:error, :delivery_unknown}
            end

          {device, result}
        end,
        max_concurrency: 5,
        timeout: 12_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{delivered: 0, unknown: 0, unregistered: 0, rejected: 0}, fn
        {:ok, {_device, :ok}}, counts ->
          Map.update!(counts, :delivered, &(&1 + 1))

        {:ok, {device, {:error, :unregistered}}}, counts ->
          _ = disable_safely(device)
          Map.update!(counts, :unregistered, &(&1 + 1))

        {:ok, {_device, {:error, :delivery_unknown}}}, counts ->
          Map.update!(counts, :unknown, &(&1 + 1))

        {:ok, {_device, {:error, _reason}}}, counts ->
          Map.update!(counts, :rejected, &(&1 + 1))

        {:exit, _reason}, counts ->
          Map.update!(counts, :unknown, &(&1 + 1))
      end)

    maybe_log_outcomes(user_id, length(devices), outcomes, opts)

    cond do
      outcomes.delivered > 0 ->
        {:ok, outcomes.delivered}

      outcomes.unknown > 0 ->
        {:error, :delivery_unknown}

      outcomes.unregistered == length(devices) ->
        {:error, :no_devices}

      true ->
        {:error, :undelivered}
    end
  end

  def deliver_prepared(_prepared, _opts), do: {:error, :preparation_failed}

  defp maybe_log_outcomes(user_id, device_count, outcomes, opts) do
    if Keyword.get(opts, :log_failures?, true) do
      cond do
        outcomes.unknown > 0 ->
          Logger.warning("Push notification batch had ambiguous device outcomes",
            user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
            device_count: device_count,
            delivered: outcomes.delivered,
            delivery_unknown: outcomes.unknown,
            rejected: outcomes.rejected,
            unregistered: outcomes.unregistered,
            failure_code: "delivery_unknown"
          )

        outcomes.delivered == 0 and outcomes.rejected > 0 ->
          Logger.warning("Push notification batch was rejected",
            user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
            device_count: device_count,
            rejected: outcomes.rejected,
            unregistered: outcomes.unregistered,
            failure_code: "undelivered"
          )

        true ->
          :ok
      end
    end
  end

  defp disable_safely(device) do
    Devices.disable(device)
  rescue
    _exception -> {:error, :disable_failed}
  catch
    _kind, _reason -> {:error, :disable_failed}
  end

  def enabled? do
    Application.get_env(:maraithon, :mobile_push, [])
    |> Keyword.get(:enabled, true)
    |> truthy?()
  end

  defp truthy?(value) when value in [true, "true", "1"], do: true
  defp truthy?(_value), do: false
end
