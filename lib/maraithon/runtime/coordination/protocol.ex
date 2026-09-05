defmodule Maraithon.Runtime.Coordination.Protocol do
  @moduledoc """
  Database-owned, irreversible activation gate for partition-fenced runtime work.

  A configuration flag is only a capability interlock. PostgreSQL mode and the
  manual stopped-fleet cutover are the authority; a rolling node may never
  promote this protocol.
  """

  alias Ecto.Adapters.SQL
  alias Maraithon.Effects.ProtocolCutover, as: EffectProtocol
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.StorageVerificationCache

  @name "runtime"
  @dark "dark"
  @active "partition_fenced_v1"
  @effect_exact "generation_fenced_v1"
  @confirmation "NON_ROLLING_MULTINODE_FLEET_DRAINED"
  @migration 20_260_810_140_004
  @repair_migration 20_260_811_000_420
  @deployment_gate_migration 20_260_904_190_000

  @opaque effect_pair_lock :: {:effect_pair_lock, Ecto.UUID.t()}

  def mode do
    case SQL.query(
           Repo,
           "SELECT mode FROM public.runtime_coordination_protocols WHERE name = $1",
           [@name]
         ) do
      {:ok, %{rows: [[@dark]]}} ->
        :dark

      {:ok, %{rows: [[@active]]}} ->
        if(storage_ready?(), do: :active, else: {:blocked, :storage_not_ready})

      {:ok, %{rows: []}} ->
        {:blocked, :protocol_missing}

      {:ok, _} ->
        {:blocked, :protocol_invalid}

      {:error, _} ->
        {:blocked, :protocol_unavailable}
    end
  rescue
    _ -> {:blocked, :protocol_unavailable}
  catch
    :exit, _ -> {:blocked, :protocol_unavailable}
  end

  def active?, do: mode() == :active
  def activation_confirmation, do: @confirmation

  def activation_epoch do
    case SQL.query(
           Repo,
           "SELECT activation_epoch FROM public.runtime_coordination_protocols WHERE name = $1 AND mode = $2",
           [@name, @active]
         ) do
      {:ok, %{rows: [[epoch]]}} when not is_nil(epoch) -> Ecto.UUID.load(epoch)
      _ -> :error
    end
  end

  def activation_preconditions do
    with :exact <- EffectProtocol.mode(),
         true <- storage_ready_uncached?(),
         {:ok, %{rows: [[0, 0, 0, 0, 0, 0]]}} <- SQL.query(Repo, quiescence_sql(), []) do
      :ok
    else
      :legacy ->
        {:error, :exact_effect_protocol_required}

      {:blocked, reason} ->
        {:error, {:effect_protocol_blocked, reason}}

      false ->
        {:error, :runtime_coordination_storage_not_ready}

      {:ok, %{rows: [[leases, jobs, schedules, effects, nodes, tasks]]}} ->
        {:error,
         {:runtime_coordination_requires_drain, leases, jobs, schedules, effects, nodes, tasks}}

      {:error, _} ->
        {:error, :runtime_coordination_protocol_unavailable}

      _ ->
        {:error, :runtime_coordination_preflight_failed}
    end
  end

  def activate(opts \\ [])

  def activate(opts) when is_list(opts) do
    StorageVerificationCache.invalidate()

    try do
      do_activate(opts)
    after
      StorageVerificationCache.invalidate()
    end
  end

  def activate(_), do: {:error, :invalid_coordination_activation}

  defp do_activate(opts) do
    with @confirmation <- Keyword.get(opts, :confirmation),
         {:ok, epoch} <- cast_epoch(Keyword.get(opts, :activation_epoch, Ecto.UUID.generate())),
         {:ok, timeout} <- lock_timeout(Keyword.get(opts, :lock_timeout_ms, 15_000)),
         {:ok, evidence} <- activation_evidence(opts) do
      activate_locked(epoch, timeout, evidence)
    else
      nil -> {:error, :non_rolling_confirmation_required}
      value when value != @confirmation -> {:error, :non_rolling_confirmation_required}
      {:error, _} = error -> error
    end
  end

  @doc "Attests stopped-fleet evidence before the irreversible Effect cutover."
  def attest_effect_activation_evidence(opts) when is_list(opts) do
    with {:ok, evidence} <- activation_evidence(opts) do
      Repo.transaction(fn ->
        SQL.query!(Repo, "SET LOCAL ROLE maraithon_activation_operator", [])

        runtime_mode =
          case SQL.query!(
                 Repo,
                 "SELECT mode FROM public.runtime_coordination_protocols WHERE name = $1 FOR UPDATE",
                 [@name]
               ).rows do
            [[mode]] when mode in [@dark, @active] -> mode
            [[mode]] -> Repo.rollback({:coordination_protocol_invalid, mode})
            [] -> Repo.rollback(:coordination_protocol_missing)
          end

        effect_row =
          case SQL.query!(
                 Repo,
                 """
                 SELECT mode, activation_evidence_id, activation_evidence_digest, activated_by,
                        exact_revision
                 FROM public.effect_execution_protocols
                 WHERE name = 'effects'
                 FOR UPDATE
                 """,
                 []
               ).rows do
            [row] -> row
            [] -> Repo.rollback(:effect_protocol_missing)
          end

        case {runtime_mode, effect_row} do
          {@dark, ["legacy", nil, nil, nil, nil]} ->
            SQL.query!(
              Repo,
              "SELECT set_config('maraithon.effect_activation_evidence', 'ATTEST_STOPPED_FLEET_EVIDENCE', true)",
              []
            )

            %{num_rows: 1} =
              SQL.query!(
                Repo,
                """
                UPDATE public.effect_execution_protocols
                SET activation_evidence_id = $1, activation_evidence_digest = $2,
                    activated_by = $3, exact_revision = $4,
                    updated_at = timezone('UTC', clock_timestamp())
                WHERE name = 'effects' AND mode = 'legacy'
                  AND activation_evidence_digest IS NULL
                """,
                [evidence.id, evidence.digest, evidence.activated_by, evidence.revision]
              )

            :attested

          {runtime_mode, [effect_mode, id, digest, by, revision]}
          when {runtime_mode, effect_mode} in [
                 {@dark, "legacy"},
                 {@dark, "generation_fenced_v1"},
                 {@active, "generation_fenced_v1"}
               ] and id == evidence.id and digest == evidence.digest and
                 by == evidence.activated_by and revision == evidence.revision ->
            :already_attested

          {@dark, ["legacy", _id, _digest, _by, _revision]} ->
            Repo.rollback(:effect_activation_evidence_mismatch)

          {_runtime_mode, ["generation_fenced_v1", _id, _digest, _by, _revision]} ->
            # Exact protocol identity is immutable. Missing or different evidence
            # must never be repaired after activation.
            Repo.rollback(:effect_activation_evidence_mismatch)

          {mode, [effect_mode, _id, _digest, _by, _revision]} ->
            Repo.rollback({:runtime_effect_protocol_pair_mismatch, mode, effect_mode})
        end
      end)
    end
  end

  def attest_effect_activation_evidence(_), do: {:error, :invalid_effect_activation_attestation}

  @doc false
  def locked_mode! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "coordination fence requires transaction")

    case SQL.query!(
           Repo,
           "SELECT mode, activation_epoch FROM public.runtime_coordination_protocols WHERE name = $1 FOR SHARE",
           [@name]
         ).rows do
      [[@dark, nil]] -> :dark
      [[@active, epoch]] when not is_nil(epoch) -> {:active, Ecto.UUID.load!(epoch)}
      [[mode, _epoch]] -> Repo.rollback({:coordination_protocol_invalid, mode})
      [] -> Repo.rollback(:coordination_protocol_missing)
    end
  end

  @doc "Locks runtime before Effect protocol and rejects mixed cutover states."
  def locked_pair! do
    runtime_mode = locked_mode!()
    effect_mode = EffectProtocol.locked_mode!()

    case {runtime_mode, effect_mode} do
      {:dark, :legacy} ->
        :legacy

      {{:active, _epoch}, :exact} ->
        :ok = mark_effect_writer_after_pair_lock!()
        :exact

      mismatch ->
        Repo.rollback({:runtime_effect_protocol_pair_mismatch, mismatch})
    end
  end

  @doc false
  def lock_effect_pair!(trace \\ fn _stage -> :ok end) when is_function(trace, 1) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "runtime/Effect protocol pair lock requires transaction")

    runtime =
      case SQL.query!(
             Repo,
             "SELECT mode, activation_epoch FROM public.runtime_coordination_protocols WHERE name = $1 FOR SHARE",
             [@name]
           ).rows do
        [[@dark, nil]] -> :dark
        [[@active, epoch]] when not is_nil(epoch) -> {:active, Ecto.UUID.load!(epoch)}
        [[mode, _epoch]] -> Repo.rollback({:coordination_protocol_invalid, mode})
        [] -> Repo.rollback(:coordination_protocol_missing)
      end

    trace.(:runtime_protocol_locked)
    effect = EffectProtocol.locked_mode!()
    trace.(:effect_protocol_locked)

    case {runtime, effect} do
      {:dark, :legacy} ->
        :legacy

      {{:active, epoch}, :exact} ->
        :ok = mark_effect_writer_after_pair_lock!()
        {:active, epoch}

      {runtime_mode, effect_mode} ->
        Repo.rollback({:runtime_effect_protocol_pair_mismatch, runtime_mode, effect_mode})
    end
  end

  @doc false
  @spec lock_effect_pair_with_capability!((atom() -> term())) :: effect_pair_lock() | :legacy
  def lock_effect_pair_with_capability!(trace \\ fn _stage -> :ok end)
      when is_function(trace, 1) do
    case lock_effect_pair!(trace) do
      {:active, epoch} -> {:effect_pair_lock, epoch}
      :legacy -> :legacy
    end
  end

  @doc false
  @spec reuse_effect_pair_lock!(effect_pair_lock(), (atom() -> term())) :: :ok
  def reuse_effect_pair_lock!(capability, trace \\ fn _stage -> :ok end)

  def reuse_effect_pair_lock!({:effect_pair_lock, expected_epoch}, trace)
      when is_binary(expected_epoch) and is_function(trace, 1) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "runtime/Effect pair-lock capability requires transaction")

    expected_epoch = Ecto.UUID.dump!(expected_epoch)

    case SQL.query!(
           Repo,
           """
           SELECT runtime_protocol.activation_epoch
           FROM public.runtime_coordination_protocols AS runtime_protocol
           JOIN public.effect_execution_protocols AS effect_protocol
             ON effect_protocol.name = 'effects'
           WHERE runtime_protocol.name = $1
             AND runtime_protocol.mode = $2
             AND runtime_protocol.activation_epoch = $3::uuid
             AND effect_protocol.mode = $4
             AND current_setting('maraithon.effect_writer_protocol', true) = $4
           FOR SHARE OF runtime_protocol, effect_protocol
           """,
           [@name, @active, expected_epoch, @effect_exact]
         ).rows do
      [[^expected_epoch]] ->
        trace.(:effect_pair_lock_reused)
        :ok

      [] ->
        Repo.rollback(:runtime_effect_protocol_pair_lock_capability_invalid)

      _unexpected ->
        Repo.rollback(:runtime_effect_protocol_pair_lock_capability_invalid)
    end
  end

  def reuse_effect_pair_lock!(_capability, trace) when is_function(trace, 1) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "runtime/Effect pair-lock capability requires transaction")

    Repo.rollback(:runtime_effect_protocol_pair_lock_capability_invalid)
  end

  # This marker is transaction-local PostgreSQL state, not a process cache. The
  # opaque tuple only guides trusted runtime code: a module with arbitrary Repo
  # SQL access can forge either representation, so the database-local marker and
  # locked exact rows remain the safety proof and expire at commit or rollback.
  # The Effect protocol row has already been locked and fully attested by
  # `EffectProtocol.locked_mode!/0`, and the pair match has already succeeded.
  # Mark this one transaction without repeating the expensive catalog pass.
  defp mark_effect_writer_after_pair_lock! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "exact Effect writer marker requires a transaction")

    case SQL.query!(
           Repo,
           "SELECT set_config('maraithon.effect_writer_protocol', $1, true)",
           [@effect_exact]
         ).rows do
      [[@effect_exact]] -> :ok
      _unexpected -> Repo.rollback(:effect_writer_protocol_marker_failed)
    end
  end

  def locked_active! do
    case locked_mode!() do
      {:active, epoch} -> epoch
      :dark -> Repo.rollback({:coordination_protocol_not_active, @dark})
    end
  end

  defp activate_locked(epoch, timeout, evidence) do
    try do
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "SELECT set_config('lock_timeout', $1, true)", ["#{timeout}ms"])

          [[mode, evidence_id, evidence_digest, activated_by, exact_revision]] =
            SQL.query!(
              Repo,
              """
              SELECT mode, activation_evidence_id, activation_evidence_digest, activated_by,
                     exact_revision
              FROM public.runtime_coordination_protocols WHERE name = $1 FOR UPDATE
              """,
              [@name]
            ).rows

          effect_mode = EffectProtocol.locked_mode!()

          case mode do
            @active ->
              ensure_effect_evidence_matches!(evidence)

              if {evidence_id, evidence_digest, activated_by, exact_revision} ==
                   {evidence.id, evidence.digest, evidence.activated_by, evidence.revision},
                 do: :already_active,
                 else: Repo.rollback(:runtime_coordination_activation_evidence_mismatch)

            @dark ->
              ensure_effect_evidence_matches!(evidence)

              # These locks serialize against every old admission/claim path. The
              # repeated quiescence check, not operator timing, closes the race.
              SQL.query!(
                Repo,
                "SELECT public.lock_durable_runtime_activation_sources()",
                []
              )

              case activation_preconditions_locked(effect_mode) do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              SQL.query!(
                Repo,
                "SELECT set_config('maraithon.runtime_coordination_activation', 'ACTIVATE_PARTITION_FENCED_V1', true)",
                []
              )

              %{num_rows: 1} =
                SQL.query!(
                  Repo,
                  """
                  UPDATE public.runtime_coordination_protocols
                  SET mode = $2, activation_epoch = $3::uuid,
                      activation_evidence_id = $4, activation_evidence_digest = $5,
                      activated_by = $6, exact_revision = $7,
                      updated_at = timezone('UTC', clock_timestamp())
                  WHERE name = $1 AND mode = 'dark'
                  """,
                  [
                    @name,
                    @active,
                    Ecto.UUID.dump!(epoch),
                    evidence.id,
                    evidence.digest,
                    evidence.activated_by,
                    evidence.revision
                  ]
                )

              :activated

            _ ->
              Repo.rollback(:runtime_coordination_protocol_invalid)
          end
        end,
        timeout: timeout + 60_000
      )
    rescue
      error in Postgrex.Error ->
        if error.postgres && error.postgres[:code] in [:lock_not_available, :query_canceled],
          do: {:error, :runtime_coordination_lock_timeout},
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp activation_preconditions_locked(effect_mode) do
    if effect_mode != :exact do
      {:error, :exact_effect_protocol_required}
    else
      case SQL.query!(Repo, quiescence_sql(), []).rows do
        [[0, 0, 0, 0, 0, 0]] ->
          if(storage_ready_uncached?(),
            do: :ok,
            else: {:error, :runtime_coordination_storage_not_ready}
          )

        [[a, b, c, d, e, f]] ->
          {:error, {:runtime_coordination_requires_drain, a, b, c, d, e, f}}
      end
    end
  end

  defp quiescence_sql do
    """
    SELECT
      (SELECT count(*) FROM public.agent_runtime_leases),
      (SELECT count(*) FROM public.background_jobs WHERE status = 'running'),
      (SELECT count(*) FROM public.scheduled_jobs WHERE status = 'dispatched'),
      (SELECT count(*) FROM public.effects WHERE status IN ('pending', 'claimed', 'executing', 'cancelling')),
      (SELECT count(*) FROM public.runtime_node_incarnations WHERE state <> 'revoked'),
      (SELECT count(*) FROM public.runtime_task_assignments
       WHERE state IN ('reserved', 'running', 'termination_requested', 'termination_proven'))
    """
  end

  # Bounded positive cache; see StorageVerificationCache. Activation paths
  # call storage_ready_uncached?/0 directly.
  defp storage_ready? do
    StorageVerificationCache.fetch(
      {__MODULE__, @active},
      &storage_ready_uncached?/0,
      &(&1 == true)
    )
  end

  defp storage_ready_uncached? do
    case SQL.query(
           Repo,
           """
           SELECT
             (SELECT count(*) FROM public.schema_migrations WHERE version = #{@migration}) = 1 AND
             (SELECT count(*) FROM public.schema_migrations WHERE version = #{@repair_migration}) = 1 AND
             (SELECT count(*) FROM public.schema_migrations
              WHERE version = #{@deployment_gate_migration}) = 1 AND
             public.runtime_coordination_catalog_ready_count() = 120 AND
             public.runtime_coordination_roles_ready() AND
             public.runtime_coordination_acl_ready() AND
             public.durable_payload_roles_ready() AND
             public.durable_payload_catalog_ready() AND
             public.privacy_protocol_catalog_ready() AND
             EXISTS (
               SELECT 1
               FROM public.runtime_coordination_protocols AS protocol
               JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = protocol.name
               WHERE protocol.name = 'runtime' AND protocol.manifest_digest = public.digest(convert_to(pg_catalog.jsonb_build_object(
                 'constraints', manifest.constraint_fingerprints,
                 'functions', manifest.function_fingerprints,
                 'triggers', manifest.trigger_fingerprints,
                 'indexes', manifest.index_fingerprints,
                 'catalogs', manifest.catalog_fingerprints
               )::text, 'UTF8'), 'sha256')
             )
           """,
           []
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp ensure_effect_evidence_matches!(evidence) do
    expected = [evidence.id, evidence.digest, evidence.activated_by, evidence.revision]

    case SQL.query!(
           Repo,
           """
           SELECT activation_evidence_id, activation_evidence_digest, activated_by,
                  exact_revision
           FROM public.effect_execution_protocols
           WHERE name = 'effects'
           """,
           []
         ).rows do
      [^expected] -> :ok
      _mismatch -> Repo.rollback(:runtime_effect_protocol_evidence_mismatch)
    end
  end

  defp activation_evidence(opts) do
    with {:ok, id} <-
           bounded_string(
             Keyword.get(opts, :evidence_id),
             1,
             256,
             :invalid_activation_evidence_id
           ),
         {:ok, digest} <- digest(Keyword.get(opts, :evidence_digest)),
         {:ok, activated_by} <-
           bounded_string(Keyword.get(opts, :activated_by), 1, 320, :invalid_activation_operator),
         {:ok, revision} <-
           exact_revision(Keyword.get(opts, :exact_revision, Keyword.get(opts, :revision))) do
      {:ok, %{id: id, digest: digest, activated_by: activated_by, revision: revision}}
    end
  end

  defp exact_revision(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[0-9a-f]{40}([0-9a-f]{24})?$/, value),
      do: {:ok, value},
      else: {:error, :invalid_exact_revision}
  end

  defp exact_revision(_value), do: {:error, :invalid_exact_revision}

  defp bounded_string(value, min, max, error) when is_binary(value) do
    value = String.trim(value)
    if byte_size(value) in min..max, do: {:ok, value}, else: {:error, error}
  end

  defp bounded_string(_, _, _, error), do: {:error, error}

  defp digest(value) when is_binary(value) and byte_size(value) == 32, do: {:ok, value}

  defp digest(value) when is_binary(value) do
    case Base.decode16(String.trim(value), case: :mixed) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _ -> {:error, :invalid_activation_evidence_digest}
    end
  end

  defp digest(_), do: {:error, :invalid_activation_evidence_digest}

  defp cast_epoch(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, epoch} -> {:ok, epoch}
      :error -> {:error, :invalid_coordination_activation_epoch}
    end
  end

  defp cast_epoch(_), do: {:error, :invalid_coordination_activation_epoch}

  defp lock_timeout(value) when is_integer(value) and value in 100..300_000, do: {:ok, value}
  defp lock_timeout(_), do: {:error, :invalid_coordination_lock_timeout}
end
