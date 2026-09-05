defmodule Maraithon.Runtime.Coordination.TaskClaims do
  @moduledoc """
  Durable task-incarnation ledger.

  Assignment IDs, claim tokens and physical Task.Supervisor identities are
  immutable. Lease expiry requests termination; it never proves it. Only an
  exact monitored supervisor proof or a separately authorized external proof
  permits recovery, and provider outcome remains explicit.
  """

  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.SecretParameterLoggingPolicy

  @guardian_persistence_timeout_ms 5_000

  alias Maraithon.Runtime.Coordination.{
    Authority,
    NodeIncarnation,
    Protocol,
    TaskAssignment,
    TaskSupervisor
  }

  @doc false
  def set_guardian_persistence_timeouts! do
    SQL.query!(
      Repo,
      """
      SELECT set_config('lock_timeout', '5s', true),
             set_config('statement_timeout', '5s', true)
      """,
      [],
      timeout: @guardian_persistence_timeout_ms
    )

    :ok
  end

  def reserve(%NodeIncarnation{} = session, partition, identity, opts \\ [])
      when is_map(partition) and is_map(identity) and is_list(opts) do
    assignment_id = Map.get(identity, :assignment_id, Ecto.UUID.generate())
    ttl_ms = Keyword.get(opts, :ttl_ms, 30_000)
    work_kind = to_string(identity.work_kind)
    authority_lease_cap = Keyword.get(opts, :authority_lease_cap)

    with {:ok, assignment_id} <- cast_uuid(assignment_id),
         {:ok, work_id} <- cast_uuid(identity.work_id),
         {:ok, claim_token} <- cast_uuid(identity.claim_token),
         {:ok, supervisor_id} <- cast_uuid(identity.supervisor_id),
         {:ok, local_task_id} <- cast_uuid(identity.local_task_id),
         termination_capability_digest when is_binary(termination_capability_digest) <-
           Map.get(identity, :termination_capability_digest),
         true <- byte_size(termination_capability_digest) == 32,
         true <- work_kind in ~w(background_job effect),
         true <- valid_authority_lease_cap?(work_kind, authority_lease_cap),
         true <- is_integer(ttl_ms) and ttl_ms in 1_000..300_000 do
      Repo.transaction(fn ->
        Authority.fence_partition!(
          session,
          partition.partition_id,
          partition.ownership_epoch,
          :ready
        )

        set_action!(assignment_id)

        result =
          SQL.query!(
            Repo,
            """
            INSERT INTO public.runtime_task_assignments
              (id, activation_epoch, work_kind, work_id, claim_token,
               partition_id, partition_epoch, node_incarnation_id,
               supervisor_id, local_task_id, termination_capability_digest,
               state, provider_boundary, lease_expires_at, inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid,
                    $6, $7, $8::uuid, $9::uuid, $10::uuid, $11,
                    'reserved', 'not_entered',
                    -- The first heartbeat must never discover an earlier
                    -- upstream authority deadline than the one recorded at
                    -- reservation time. Cap the task by every authority row
                    -- already fenced and locked in this transaction.
                    LEAST(
                      timezone('UTC', clock_timestamp()) + ($12::bigint * interval '1 millisecond'),
                      (SELECT lease_expires_at FROM public.runtime_node_incarnations
                       WHERE id = $8::uuid AND activation_epoch = $2::uuid),
                      (SELECT lease_expires_at FROM public.runtime_partitions
                       WHERE partition_id = $6 AND activation_epoch = $2::uuid
                         AND ownership_epoch = $7
                         AND owner_node_incarnation_id = $8::uuid),
                      COALESCE($13::timestamp, 'infinity'::timestamp)
                    ), timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                      partition_id, partition_epoch, node_incarnation_id,
                      supervisor_id, local_task_id, termination_capability_digest,
                      state, provider_boundary,
                      lease_expires_at, ready_at, termination_requested_at,
                      termination_proven_at, settled_at, outcome, inserted_at, updated_at
            """,
            [
              Ecto.UUID.dump!(assignment_id),
              Ecto.UUID.dump!(session.activation_epoch),
              work_kind,
              Ecto.UUID.dump!(work_id),
              Ecto.UUID.dump!(claim_token),
              partition.partition_id,
              partition.ownership_epoch,
              Ecto.UUID.dump!(session.id),
              Ecto.UUID.dump!(supervisor_id),
              Ecto.UUID.dump!(local_task_id),
              termination_capability_digest,
              ttl_ms,
              authority_lease_cap_param(authority_lease_cap)
            ]
          )

        load(result)
      end)
    else
      false -> {:error, :invalid_task_assignment}
      {:error, _} = error -> error
      _invalid_capability_digest -> {:error, :invalid_task_assignment}
    end
  end

  defp valid_authority_lease_cap?("effect", %DateTime{utc_offset: 0, std_offset: 0}), do: true
  defp valid_authority_lease_cap?("effect", _lease_cap), do: false
  defp valid_authority_lease_cap?("background_job", nil), do: true

  defp authority_lease_cap_param(%DateTime{} = lease_cap), do: DateTime.to_naive(lease_cap)
  defp authority_lease_cap_param(nil), do: nil

  def activate(%TaskAssignment{work_kind: "effect"}),
    do: {:error, :effect_requires_canonical_effect_transaction}

  def activate(%TaskAssignment{} = assignment) do
    with :ok <- TaskSupervisor.authorize_activation(task_identity(assignment)) do
      transition(
        assignment,
        """
        state = 'running', ready_at = timezone('UTC', clock_timestamp()),
        updated_at = timezone('UTC', clock_timestamp())
        """,
        "state = 'reserved' AND lease_expires_at > timezone('UTC', clock_timestamp())",
        :ready
      )
    end
  end

  def mark_provider_entered(%TaskAssignment{work_kind: "effect"}),
    do: {:error, :effect_requires_canonical_effect_transaction}

  def mark_provider_entered(%TaskAssignment{} = assignment) do
    with :ok <- TaskSupervisor.authorize_activation(task_identity(assignment)) do
      transition(
        assignment,
        """
        provider_boundary = 'entered', updated_at = timezone('UTC', clock_timestamp())
        """,
        "state = 'running' AND provider_boundary = 'not_entered'",
        :ready
      )
    end
  end

  def renew(%TaskAssignment{work_kind: "effect"}, _ttl_ms),
    do: {:error, :effect_requires_canonical_effect_transaction}

  def renew(%TaskAssignment{} = assignment, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms in 1_000..300_000 do
    transition(
      assignment,
      """
      lease_expires_at = LEAST(
        timezone('UTC', clock_timestamp()) + (#{ttl_ms}::bigint * interval '1 millisecond'),
        (SELECT lease_expires_at FROM public.runtime_partitions
         WHERE partition_id = runtime_task_assignments.partition_id)
      ), updated_at = timezone('UTC', clock_timestamp())
      """,
      """
      lease_expires_at > timezone('UTC', clock_timestamp()) AND
      (state = 'running' OR
       (state = 'reserved' AND ready_at IS NULL AND provider_boundary = 'not_entered'))
      """,
      :ready
    )
  end

  def request_termination(%TaskAssignment{work_kind: "effect"}),
    do: {:error, :effect_requires_canonical_effect_transaction}

  def request_termination(%TaskAssignment{} = assignment) do
    transition(
      assignment,
      """
      state = 'termination_requested',
      provider_boundary = CASE WHEN provider_boundary = 'entered'
                               THEN 'outcome_unknown' ELSE provider_boundary END,
      termination_requested_at = timezone('UTC', clock_timestamp()),
      updated_at = timezone('UTC', clock_timestamp())
      """,
      "state = 'running'"
    )
  end

  def abort_reserved(%TaskAssignment{}),
    do: {:error, :local_task_termination_capability_required}

  def abort_reserved(%TaskAssignment{} = assignment, capability_secret)
      when is_binary(capability_secret) and byte_size(capability_secret) == 32 do
    evidence_id = never_activated_evidence_id(assignment)

    with {:ok, proven} <-
           record_local_termination(assignment, "never_activated", evidence_id, capability_secret),
         {:ok, :ok} <- reconcile_never_activated(proven) do
      {:ok, get(assignment.id)}
    end
  end

  def abort_reserved(%TaskAssignment{}, _capability),
    do: {:error, :local_task_termination_capability_required}

  @doc false
  def persist_guardian_termination(identity, physical_proof_kind, evidence_id, capability_secret)
      when is_map(identity) and physical_proof_kind in ["supervisor_down", "never_activated"] and
             is_binary(evidence_id) and byte_size(evidence_id) in 1..256 and
             is_binary(capability_secret) and byte_size(capability_secret) == 32 do
    Repo.transaction(
      fn ->
        set_guardian_persistence_timeouts!()

        result =
          with assignment_id when is_binary(assignment_id) <- Map.get(identity, :assignment_id) do
            case get(assignment_id) do
              %TaskAssignment{} = assignment ->
                persist_loaded_guardian_assignment(
                  assignment,
                  identity,
                  physical_proof_kind,
                  evidence_id,
                  capability_secret
                )

              nil ->
                classify_uncommitted_background_reservation(
                  identity,
                  physical_proof_kind,
                  evidence_id,
                  capability_secret
                )
            end
          else
            _invalid -> {:error, :task_authority_lost}
          end

        case result do
          {:ok, disposition} -> disposition
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @guardian_persistence_timeout_ms
    )
  rescue
    _error -> {:error, :task_termination_persistence_failed}
  catch
    :exit, _reason -> {:error, :task_termination_persistence_failed}
  end

  def persist_guardian_termination(_identity, _proof_kind, _evidence_id, _secret),
    do: {:error, :local_task_termination_capability_required}

  defp persist_loaded_guardian_assignment(
         assignment,
         identity,
         physical_proof_kind,
         evidence_id,
         capability_secret
       ) do
    with true <- exact_guardian_identity?(assignment, identity),
         true <-
           assignment.termination_capability_digest ==
             :crypto.hash(:sha256, capability_secret) do
      case assignment.state do
        "reserved" ->
          # Proof-first: never_activated commits before work reconciliation. If
          # reconciliation fails, the exact durable proof remains retryable
          # without relying on this process's ETS preimage.
          persist_guardian_assignment(
            assignment,
            physical_proof_kind,
            evidence_id,
            capability_secret
          )

        state when state in ["running", "termination_requested"] ->
          persist_running_guardian_assignment_atomic(
            identity,
            physical_proof_kind,
            evidence_id,
            capability_secret
          )

        state when state in ["termination_proven", "settled", "outcome_ambiguous"] ->
          guardian_termination_disposition(assignment)

        _other ->
          {:error, :task_not_awaiting_termination_proof}
      end
    else
      false -> {:error, :task_termination_capability_mismatch}
    end
  end

  defp classify_uncommitted_background_reservation(
         %{work_kind: "background_job"} = identity,
         physical_proof_kind,
         evidence_id,
         capability_secret
       ) do
    outcome =
      Repo.transaction(
        fn ->
          _epoch = Protocol.locked_active!()

          job_rows =
            SQL.query!(
              Repo,
              """
              SELECT status, claim_token, coordination_task_assignment_id,
                     coordination_task_supervisor_id, coordination_local_task_id
              FROM public.background_jobs
              WHERE id = $1::uuid
              FOR UPDATE
              """,
              [Ecto.UUID.dump!(identity.work_id)]
            ).rows

          assignment = get(identity.assignment_id)
          expected_claim_token = Ecto.UUID.dump!(identity.claim_token)
          expected_assignment_id = Ecto.UUID.dump!(identity.assignment_id)
          expected_supervisor_id = Ecto.UUID.dump!(identity.supervisor_id)
          expected_local_task_id = Ecto.UUID.dump!(identity.local_task_id)

          case {job_rows, assignment} do
            {[["pending", nil, nil, nil, nil]], nil} ->
              :uncommitted

            {[[_status, claim_token, assignment_id, supervisor_id, local_task_id]], nil}
            when is_binary(claim_token) and claim_token != expected_claim_token and
                   is_binary(supervisor_id) and
                   is_binary(local_task_id) and local_task_id != expected_local_task_id and
                   (is_nil(assignment_id) or assignment_id != expected_assignment_id) ->
              :uncommitted

            {[
               [
                 "pending",
                 ^expected_claim_token,
                 ^expected_assignment_id,
                 ^expected_supervisor_id,
                 ^expected_local_task_id
               ]
             ], %TaskAssignment{} = assignment} ->
              {:committed, assignment}

            _partial_or_mismatched ->
              Repo.rollback(:background_job_claim_commit_outcome_mismatched)
          end
        end,
        timeout: @guardian_persistence_timeout_ms
      )

    case outcome do
      {:ok, :uncommitted} ->
        {:ok, :uncommitted}

      {:ok, {:committed, assignment}} ->
        persist_loaded_guardian_assignment(
          assignment,
          identity,
          physical_proof_kind,
          evidence_id,
          capability_secret
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_uncommitted_background_reservation(
         _identity,
         _physical_proof_kind,
         _evidence_id,
         _capability_secret
       ),
       do: {:error, :task_assignment_not_found}

  defp persist_running_guardian_assignment_atomic(
         identity,
         physical_proof_kind,
         evidence_id,
         capability_secret
       ) do
    Repo.transaction(
      fn ->
        result =
          with %TaskAssignment{} = assignment <- get(identity.assignment_id),
               true <- exact_guardian_identity?(assignment, identity),
               true <-
                 assignment.termination_capability_digest ==
                   :crypto.hash(:sha256, capability_secret) do
            case assignment.state do
              state when state in ["running", "termination_requested"] ->
                persist_guardian_assignment(
                  assignment,
                  physical_proof_kind,
                  evidence_id,
                  capability_secret
                )

              state when state in ["termination_proven", "settled", "outcome_ambiguous"] ->
                guardian_termination_disposition(assignment)

              _other ->
                {:error, :task_not_awaiting_termination_proof}
            end
          else
            nil -> {:error, :task_assignment_not_found}
            false -> {:error, :task_termination_capability_mismatch}
          end

        case result do
          {:ok, disposition} -> disposition
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @guardian_persistence_timeout_ms
    )
  end

  defp persist_guardian_assignment(
         %TaskAssignment{state: "reserved", provider_boundary: "not_entered", ready_at: nil} =
           assignment,
         _physical_proof_kind,
         _evidence_id,
         secret
       ) do
    evidence_id = never_activated_evidence_id(assignment)

    case record_proof(
           assignment,
           "never_activated",
           evidence_id,
           Atom.to_string(node()),
           "LOCAL_TASK_NEVER_ACTIVATED_PROOF",
           secret,
           timeout: @guardian_persistence_timeout_ms
         ) do
      {:ok, %TaskAssignment{state: "termination_proven"} = proven} ->
        guardian_termination_disposition(proven)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_guardian_assignment(
         %TaskAssignment{state: "running"} = assignment,
         "supervisor_down",
         evidence_id,
         secret
       ) do
    with {:ok, requested} <- request_termination(assignment),
         {:ok, %TaskAssignment{state: "termination_proven"} = proven} <-
           record_local_termination(requested, "supervisor_down", evidence_id, secret) do
      guardian_termination_disposition(proven)
    else
      {:error, reason} -> {:error, reason}
      _lost -> {:error, :task_termination_proof_lost}
    end
  end

  defp persist_guardian_assignment(
         %TaskAssignment{state: "termination_requested"} = assignment,
         "supervisor_down",
         evidence_id,
         secret
       ) do
    case record_local_termination(assignment, "supervisor_down", evidence_id, secret) do
      {:ok, %TaskAssignment{state: "termination_proven"} = proven} ->
        guardian_termination_disposition(proven)

      {:error, reason} ->
        {:error, reason}

      _lost ->
        {:error, :task_termination_proof_lost}
    end
  end

  defp persist_guardian_assignment(
         %TaskAssignment{state: state} = assignment,
         _proof_kind,
         _evidence_id,
         _secret
       )
       when state in ["termination_proven", "settled", "outcome_ambiguous"],
       do: guardian_termination_disposition(assignment)

  defp persist_guardian_assignment(_assignment, _proof_kind, _evidence_id, _secret),
    do: {:error, :task_not_awaiting_termination_proof}

  @doc false
  def guardian_termination_disposition(%TaskAssignment{} = assignment) do
    rows =
      SQL.query!(
        Repo,
        """
        SELECT proof_kind
        FROM public.runtime_task_termination_proofs
        WHERE assignment_id = $1::uuid AND activation_epoch = $2::uuid
          AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
          AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
        ORDER BY proof_kind
        LIMIT 2
        """,
        [
          Ecto.UUID.dump!(assignment.id),
          Ecto.UUID.dump!(assignment.activation_epoch),
          Ecto.UUID.dump!(assignment.claim_token),
          Ecto.UUID.dump!(assignment.node_incarnation_id),
          Ecto.UUID.dump!(assignment.supervisor_id),
          Ecto.UUID.dump!(assignment.local_task_id)
        ]
      ).rows

    case {assignment.state, rows} do
      {_state, [["never_activated"]]} -> {:ok, :never_activated}
      {_state, [["supervisor_down"]]} -> {:ok, :supervisor_down}
      {_state, [["external_destroyed"]]} -> {:ok, :external_destroyed}
      {state, []} when state in ["settled", "outcome_ambiguous"] -> {:ok, :completion}
      {_state, []} -> {:error, :task_termination_proof_missing}
      {_state, _conflicting} -> {:error, :task_termination_proof_conflict}
    end
  end

  defp exact_guardian_identity?(assignment, identity) do
    fields = [:work_kind, :work_id, :claim_token, :assignment_id, :supervisor_id, :local_task_id]
    Map.take(task_identity(assignment), fields) == Map.take(identity, fields)
  end

  @doc false
  def reconcile_never_activated(%TaskAssignment{work_kind: "background_job"} = assignment) do
    Repo.transaction(fn ->
      current = lock_assignment!(assignment)

      case current do
        %TaskAssignment{state: "termination_proven", provider_boundary: "not_entered"} ->
          require_never_activated_proof!(current)
          _result = reconcile_one!(current)
          :ok

        %TaskAssignment{
          state: "settled",
          provider_boundary: "not_entered",
          outcome: "cancelled_before_provider"
        } ->
          :ok

        _noncanonical ->
          Repo.rollback(:task_not_canonical_never_activated)
      end
    end)
  end

  defp require_never_activated_proof!(assignment) do
    case SQL.query!(
           Repo,
           """
           SELECT 1 FROM public.runtime_task_termination_proofs
           WHERE assignment_id = $1::uuid AND activation_epoch = $2::uuid
             AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
             AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
             AND proof_kind IN ('never_activated', 'external_destroyed')
           """,
           identity_params(assignment)
         ).rows do
      [[1]] -> :ok
      _missing -> Repo.rollback(:task_termination_proof_lost)
    end
  end

  @doc false
  def activate_effect_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    unless locked.state == "reserved" and locked.provider_boundary == "not_entered",
      do: Repo.rollback(:coordination_task_authority_lost)

    _lease_cap =
      fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :ready)

    set_action!(locked.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = 'running', ready_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND activation_epoch = $2::uuid
          AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
          AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
          AND state = 'reserved' AND provider_boundary = 'not_entered'
          AND lease_expires_at > timezone('UTC', clock_timestamp())
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, termination_capability_digest,
                  state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        identity_params(locked)
      )

    load!(result, :coordination_task_authority_lost)
  end

  @doc false
  def enter_effect_provider_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    unless locked.state == "running" and locked.provider_boundary == "not_entered",
      do: Repo.rollback(:coordination_task_authority_lost)

    _lease_cap =
      fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :ready)

    set_action!(locked.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET provider_boundary = 'entered', updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND activation_epoch = $2::uuid
          AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
          AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
          AND state = 'running' AND provider_boundary = 'not_entered'
          AND lease_expires_at > timezone('UTC', clock_timestamp())
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, termination_capability_digest,
                  state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        identity_params(locked)
      )

    load!(result, :coordination_task_authority_lost)
  end

  @doc false
  def renew_effect_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation,
        ttl_ms
      )
      when is_integer(ttl_ms) and ttl_ms in 1_000..300_000 do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "reserved", provider_boundary: "not_entered", ready_at: nil} ->
        _lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :ready)

        unless pristine_effect_preactivation_live?(
                 locked,
                 agent_id,
                 owner_generation,
                 Atom.to_string(node())
               ),
               do: Repo.rollback(:coordination_task_authority_lost)

        # Guardian activation precedes the durable activation transaction so
        # command preflight can run under an exact PID-bound identity. This
        # tag proves the locked reservation is still that pristine handoff; it
        # deliberately performs no lease or timestamp write.
        {:preactivation, locked}

      %TaskAssignment{state: "running"} ->
        lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :ready)

        set_action!(locked.id)

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_task_assignments
            SET lease_expires_at = LEAST(
                  timezone('UTC', clock_timestamp()) + ($7::bigint * interval '1 millisecond'),
                  $8::timestamp
                ),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE id = $1::uuid AND activation_epoch = $2::uuid
              AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
              AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
              AND state = 'running'
              AND lease_expires_at > timezone('UTC', clock_timestamp())
            RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                      partition_id, partition_epoch, node_incarnation_id,
                      supervisor_id, local_task_id, termination_capability_digest,
                      state, provider_boundary,
                      lease_expires_at, ready_at, termination_requested_at,
                      termination_proven_at, settled_at, outcome, inserted_at, updated_at
            """,
            identity_params(locked) ++ [ttl_ms, lease_cap]
          )

        renewed = load!(result, :coordination_task_authority_lost)

        case DateTime.compare(renewed.lease_expires_at, locked.lease_expires_at) do
          :gt -> {:renewed, renewed}
          :eq -> {:unchanged, renewed}
          :lt -> Repo.rollback(:coordination_task_authority_lost)
        end

      _noncanonical ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp pristine_effect_preactivation_live?(
         %TaskAssignment{} = assignment,
         agent_id,
         owner_generation,
         owner_node
       ) do
    # This is the final DB-clock check after the exact Effect, assignment, node,
    # partition, and Agent-authority locks have all been acquired. Locks prevent
    # identity mutation; this single statement also prevents a near-expiry row
    # from becoming stale while a later lock was contended.
    case SQL.query!(
           Repo,
           """
           SELECT 1
           FROM public.runtime_task_assignments AS task
           JOIN public.effects AS effect
             ON effect.id = task.work_id
            AND effect.agent_id = $10::uuid
            AND effect.status = 'claimed'
            AND effect.runtime_owner_generation = $11::uuid
            AND effect.claim_token = task.claim_token
            AND effect.claimed_by = $12
            AND effect.claim_owner_node = $12
            AND effect.claim_supervisor_id = task.supervisor_id
            AND effect.claim_task_id = task.local_task_id
            AND effect.coordination_activation_epoch = task.activation_epoch
            AND effect.coordination_partition_id = task.partition_id
            AND effect.coordination_partition_epoch = task.partition_epoch
            AND effect.coordination_node_incarnation_id = task.node_incarnation_id
            AND effect.coordination_task_assignment_id = task.id
            AND effect.cancellation_state IS NULL
            AND effect.claim_expires_at > timezone('UTC', clock_timestamp())
           JOIN public.runtime_node_incarnations AS node
             ON node.id = task.node_incarnation_id
            AND node.activation_epoch = task.activation_epoch
            AND node.state = 'ready' AND node.ready_at IS NOT NULL
            AND node.lease_expires_at > timezone('UTC', clock_timestamp())
           JOIN public.runtime_partitions AS partition
             ON partition.partition_id = task.partition_id
            AND partition.activation_epoch = task.activation_epoch
            AND partition.ownership_epoch = task.partition_epoch
            AND partition.owner_node_incarnation_id = task.node_incarnation_id
            AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
            AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
           JOIN public.agent_runtime_leases AS lease
             ON lease.agent_id = $10::uuid AND lease.owner_token = $11::uuid
            AND lease.coordination_activation_epoch = task.activation_epoch
            AND lease.coordination_partition_id = task.partition_id
            AND lease.coordination_partition_epoch = task.partition_epoch
            AND lease.coordination_node_incarnation_id = task.node_incarnation_id
            AND lease.ready_at IS NOT NULL AND lease.draining_at IS NULL
            AND lease.lease_until > timezone('UTC', clock_timestamp())
           WHERE task.id = $1::uuid AND task.activation_epoch = $2::uuid
             AND task.claim_token = $3::uuid AND task.node_incarnation_id = $4::uuid
             AND task.supervisor_id = $5::uuid AND task.local_task_id = $6::uuid
             AND task.work_kind = 'effect' AND task.work_id = $7::uuid
             AND task.partition_id = $8 AND task.partition_epoch = $9
             AND task.state = 'reserved' AND task.provider_boundary = 'not_entered'
             AND task.ready_at IS NULL
             AND task.lease_expires_at > timezone('UTC', clock_timestamp())
           """,
           identity_params(assignment) ++
             [
               Ecto.UUID.dump!(assignment.work_id),
               assignment.partition_id,
               assignment.partition_epoch,
               Ecto.UUID.dump!(agent_id),
               Ecto.UUID.dump!(owner_generation),
               owner_node
             ]
         ).rows do
      [[1]] -> true
      _expired_or_mismatched -> false
    end
  end

  @doc false
  def settle_effect_before_provider_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "running", provider_boundary: "not_entered"} ->
        _lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :owner)

        set_action!(locked.id)
        settle_with_boundary!(locked, "not_entered", "cancelled_before_provider")

      %TaskAssignment{
        state: "settled",
        provider_boundary: "not_entered",
        outcome: "cancelled_before_provider"
      } ->
        locked

      _noncanonical ->
        Repo.rollback(:coordination_task_settlement_lost)
    end
  end

  @doc false
  def settle_effect_in_transaction(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation,
        outcome
      )
      when is_binary(outcome) and byte_size(outcome) in 1..255 do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "running", provider_boundary: "entered"} ->
        _lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :owner)

        # Outcome evidence and the settlement UPDATE are trigger-fenced to the
        # exact task action, exactly like activation and provider entry.
        set_action!(locked.id)
        record_outcome_and_settle!(locked, outcome)

      %TaskAssignment{state: "settled", provider_boundary: boundary, outcome: ^outcome}
      when boundary == "outcome_known" or
             (boundary == "not_entered" and outcome == "cancelled_before_provider") ->
        locked

      %TaskAssignment{state: "outcome_ambiguous"} ->
        # A later canonical Effect observation must never rewrite durable
        # ambiguity or manufacture provider evidence.
        locked

      _noncanonical ->
        Repo.rollback(:coordination_task_settlement_lost)
    end
  end

  @doc false
  def request_effect_termination_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "reserved", provider_boundary: "not_entered", ready_at: nil} ->
        locked

      %TaskAssignment{state: "running"} ->
        request_termination_locked!(locked)

      %TaskAssignment{state: "termination_requested"} ->
        locked

      %TaskAssignment{state: state}
      when state in ["termination_proven", "settled", "outcome_ambiguous"] ->
        locked

      _mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  def abort_effect_reserved_in_transaction!(%TaskAssignment{}, _agent_id, _generation),
    do: {:error, :local_task_termination_capability_required}

  @doc false
  def abort_effect_reserved_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation,
        capability_secret
      )
      when is_binary(capability_secret) and byte_size(capability_secret) == 32 do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "reserved", provider_boundary: "not_entered", ready_at: nil} ->
        _lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :owner)

        proven =
          case record_local_termination(
                 locked,
                 "never_activated",
                 never_activated_evidence_id(locked),
                 capability_secret
               ) do
            {:ok, %TaskAssignment{state: "termination_proven"} = value} -> value
            _lost -> Repo.rollback(:coordination_task_termination_proof_lost)
          end

        reconcile_effect_proven_in_transaction(proven, agent_id, owner_generation)

      %TaskAssignment{
        state: "settled",
        provider_boundary: "not_entered",
        outcome: "cancelled_before_provider"
      } ->
        locked

      _activated_or_mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  def abort_effect_reserved_in_transaction!(
        %TaskAssignment{},
        _agent_id,
        _generation,
        _capability
      ),
      do: {:error, :local_task_termination_capability_required}

  @doc false
  def lock_effect_assignment_in_transaction!(%TaskAssignment{work_kind: "effect"} = assignment) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "effect task lock requires transaction")

    case Repo.one(
           from a in TaskAssignment,
             where: a.id == ^assignment.id,
             where: a.activation_epoch == ^assignment.activation_epoch,
             where: a.work_kind == "effect",
             where: a.work_id == ^assignment.work_id,
             where: a.claim_token == ^assignment.claim_token,
             where: a.partition_id == ^assignment.partition_id,
             where: a.partition_epoch == ^assignment.partition_epoch,
             where: a.node_incarnation_id == ^assignment.node_incarnation_id,
             where: a.supervisor_id == ^assignment.supervisor_id,
             where: a.local_task_id == ^assignment.local_task_id,
             lock: "FOR UPDATE"
         ) do
      %TaskAssignment{} = locked -> locked
      nil -> Repo.rollback(:coordination_task_authority_lost)
    end
  end

  def fence_running!(%TaskAssignment{} = assignment) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "task fence requires transaction")

    assignment = lock_assignment!(assignment)

    case SQL.query!(
           Repo,
           """
           SELECT id, provider_boundary FROM public.runtime_task_assignments
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
             AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
             AND work_kind = $7 AND work_id = $8::uuid
             AND partition_id = $9 AND partition_epoch = $10
             AND state = 'running' AND lease_expires_at > timezone('UTC', clock_timestamp())
             AND public.runtime_task_authority_valid(id, activation_epoch, partition_id,
                   partition_epoch, node_incarnation_id, claim_token)
           """,
           identity_params(assignment) ++
             [
               assignment.work_kind,
               Ecto.UUID.dump!(assignment.work_id),
               assignment.partition_id,
               assignment.partition_epoch
             ]
         ).rows do
      [[_id, provider_boundary]] ->
        set_action!(assignment.id)
        provider_boundary

      [] ->
        Repo.rollback(:task_authority_lost)
    end
  end

  def settle_in_transaction(%TaskAssignment{work_kind: "effect"}, _outcome),
    do: Repo.rollback(:effect_requires_canonical_effect_transaction)

  def settle_in_transaction(%TaskAssignment{} = assignment, outcome)
      when is_binary(outcome) and byte_size(outcome) in 1..255 do
    case fence_running!(assignment) do
      "entered" -> record_outcome_and_settle!(assignment, outcome)
      _not_entered_or_unknown -> Repo.rollback(:task_provider_not_entered)
    end
  end

  def cancel_before_provider_in_transaction(%TaskAssignment{work_kind: "effect"}),
    do: Repo.rollback(:effect_requires_canonical_effect_transaction)

  def cancel_before_provider_in_transaction(%TaskAssignment{} = assignment) do
    case fence_running!(assignment) do
      "not_entered" ->
        settle_with_boundary!(assignment, "not_entered", "cancelled_before_provider")

      _entered_or_unknown ->
        Repo.rollback(:task_provider_already_entered)
    end
  end

  defp record_outcome_and_settle!(assignment, outcome) do
    evidence_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO public.runtime_task_outcome_evidence
        (id, assignment_id, activation_epoch, claim_token, node_incarnation_id,
         supervisor_id, local_task_id, outcome, recorded_at, inserted_at, updated_at)
      VALUES ($7::uuid, $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid,
              $8, timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
              timezone('UTC', clock_timestamp()))
      """,
      identity_params(assignment) ++ [Ecto.UUID.dump!(evidence_id), outcome]
    )

    settle_with_boundary!(assignment, "outcome_known", outcome)
  end

  defp settle_with_boundary!(assignment, boundary, outcome, expected_state \\ "running") do
    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = 'settled', settled_at = timezone('UTC', clock_timestamp()), outcome = $8,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND activation_epoch = $2::uuid AND claim_token = $3::uuid
          AND node_incarnation_id = $4::uuid AND supervisor_id = $5::uuid
          AND local_task_id = $6::uuid AND state = $9 AND provider_boundary = $7
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, termination_capability_digest,
                  state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        identity_params(assignment) ++ [boundary, outcome, expected_state]
      )

    load!(result, :task_authority_lost)
  end

  def record_local_termination(%TaskAssignment{}, _proof_kind, _evidence_id),
    do: {:error, :local_task_termination_capability_required}

  def record_local_termination(
        %TaskAssignment{} = assignment,
        proof_kind,
        evidence_id,
        capability_secret
      )
      when proof_kind in ["supervisor_down", "never_activated"] and
             is_binary(capability_secret) and byte_size(capability_secret) == 32 do
    confirmation =
      if proof_kind == "supervisor_down",
        do: "LOCAL_TASK_SUPERVISOR_PROOF",
        else: "LOCAL_TASK_NEVER_ACTIVATED_PROOF"

    record_proof(
      assignment,
      proof_kind,
      evidence_id,
      Atom.to_string(node()),
      confirmation,
      capability_secret
    )
  end

  def record_local_termination(%TaskAssignment{}, _proof_kind, _evidence_id, _capability),
    do: {:error, :local_task_termination_capability_required}

  def record_external_termination(%TaskAssignment{} = assignment, evidence_id, proved_by) do
    record_proof(
      assignment,
      "external_destroyed",
      evidence_id,
      proved_by,
      "PHYSICAL_TASK_TERMINATED",
      nil
    )
  end

  def reconcile_proven(limit \\ 25) when is_integer(limit) and limit in 1..100 do
    # Discovery is deliberately unlocked and bounded. Each candidate takes the
    # canonical authority locks before attempting its assignment row, so a busy
    # assignment is skipped without reversing protocol -> node -> partition ->
    # assignment -> work ordering or blocking another reconciler.
    candidates =
      Repo.all(
        from a in TaskAssignment,
          where: a.state == "termination_proven",
          where: a.work_kind != "effect",
          order_by: [asc: a.termination_proven_at, asc: a.id],
          limit: ^limit
      )

    candidates
    |> Enum.reduce_while({:ok, []}, fn assignment, {:ok, results} ->
      case Repo.transaction(fn ->
             case try_lock_assignment(assignment) do
               %TaskAssignment{state: "termination_proven"} = locked -> reconcile_one!(locked)
               %TaskAssignment{} -> :already_converged
               nil -> :busy
             end
           end) do
        {:ok, state} when state in [:already_converged, :busy] ->
          {:cont, {:ok, results}}

        {:ok, result} ->
          {:cont, {:ok, [result | results]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc false
  def reconcile_effect_proven_in_transaction(
        %TaskAssignment{} = assignment,
        agent_id,
        owner_generation
      ) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "effect task reconciliation requires transaction")

    locked =
      Repo.one(
        from a in TaskAssignment,
          where: a.id == ^assignment.id,
          where: a.activation_epoch == ^assignment.activation_epoch,
          where: a.work_kind == "effect",
          where: a.work_id == ^assignment.work_id,
          where: a.claim_token == ^assignment.claim_token,
          where: a.partition_id == ^assignment.partition_id,
          where: a.partition_epoch == ^assignment.partition_epoch,
          where: a.node_incarnation_id == ^assignment.node_incarnation_id,
          where: a.supervisor_id == ^assignment.supervisor_id,
          where: a.local_task_id == ^assignment.local_task_id,
          where: a.state == "termination_proven",
          lock: "FOR UPDATE"
      )

    case locked do
      %TaskAssignment{} = proven ->
        _lease_cap =
          fence_effect_authority_in_transaction!(proven, agent_id, owner_generation, :owner)

        outcome =
          if proven.provider_boundary in ["entered", "outcome_unknown"],
            do: "provider_outcome_ambiguous",
            else: "cancelled_before_provider"

        finish_proven!(proven, outcome)

      nil ->
        Repo.rollback(:task_termination_proof_lost)
    end
  end

  def get(id) when is_binary(id), do: Repo.get(TaskAssignment, id)

  defp reconcile_one!(%TaskAssignment{work_kind: "background_job"} = assignment) do
    set_action!(assignment.id)
    set_local!("maraithon.effect_writer_protocol", "generation_fenced_v1")
    provider_entered? = assignment.provider_boundary in ["entered", "outcome_unknown"]
    set_local!("maraithon.runtime_task_reconciliation", assignment.id)

    updates =
      if provider_entered? do
        """
        status = 'failed', failed_at = timezone('UTC', clock_timestamp()),
        last_error = 'provider_outcome_ambiguous', claimed_by = NULL, claimed_at = NULL,
        completed_at = NULL, updated_at = timezone('UTC', clock_timestamp())
        """
      else
        """
        status = 'pending', scheduled_at = timezone('UTC', clock_timestamp()),
        claimed_by = NULL, claimed_at = NULL, claim_token = NULL,
        coordination_activation_epoch = NULL, coordination_partition_epoch = NULL,
        coordination_node_incarnation_id = NULL, coordination_task_assignment_id = NULL,
        coordination_task_supervisor_id = NULL, coordination_local_task_id = NULL,
        updated_at = timezone('UTC', clock_timestamp())
        """
      end

    outcome =
      if provider_entered?, do: "provider_outcome_ambiguous", else: "cancelled_before_provider"

    finish_proven!(assignment, outcome)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.background_jobs SET #{updates}
        WHERE id = $1::uuid AND claim_token = $2::uuid
          AND coordination_task_assignment_id = $3::uuid
          AND ((status = 'running' AND $4::boolean) OR
               (status IN ('pending', 'running') AND NOT $4::boolean))
        """,
        [
          Ecto.UUID.dump!(assignment.work_id),
          Ecto.UUID.dump!(assignment.claim_token),
          Ecto.UUID.dump!(assignment.id),
          provider_entered?
        ]
      )

    if result.num_rows != 1, do: Repo.rollback(:coordinated_work_not_converged)
    {assignment.id, result.num_rows, outcome}
  end

  defp finish_proven!(assignment, outcome) do
    set_action!(assignment.id)
    state = if outcome == "provider_outcome_ambiguous", do: "outcome_ambiguous", else: "settled"

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = $2, settled_at = timezone('UTC', clock_timestamp()), outcome = $3,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND state = 'termination_proven'
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, termination_capability_digest,
                  state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        [Ecto.UUID.dump!(assignment.id), state, outcome]
      )

    load!(result, :task_termination_proof_lost)
  end

  defp record_proof(
         assignment,
         proof_kind,
         evidence_id,
         proved_by,
         confirmation,
         capability,
         opts \\ []
       )
       when is_binary(evidence_id) and byte_size(evidence_id) in 1..256 and
              is_binary(proved_by) and byte_size(proved_by) in 1..320 do
    Repo.transaction(
      fn ->
        locked = lock_assignment!(assignment)
        locked = prepare_assignment_for_proof!(locked, proof_kind)

        set_action!(locked.id)
        set_local!("maraithon.runtime_task_termination_proof", confirmation)

        if proof_kind in ["supervisor_down", "never_activated"] do
          verify_secret_logging_policy!()
          set_local_termination_capability!(capability)
        end

        digest = :crypto.hash(:sha256, evidence_id)
        proof_id = Ecto.UUID.generate()

        case SQL.query(
               Repo,
               """
               INSERT INTO public.runtime_task_termination_proofs
                 (id, assignment_id, activation_epoch, claim_token, node_incarnation_id,
                  supervisor_id, local_task_id, proof_kind, evidence_id, evidence_digest,
                  proved_by, proved_at, inserted_at, updated_at)
               VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid,
                       $8, $9, $10, $11, timezone('UTC', clock_timestamp()),
                       timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
               ON CONFLICT (assignment_id) DO NOTHING
               """,
               [
                 Ecto.UUID.dump!(proof_id),
                 Ecto.UUID.dump!(locked.id),
                 Ecto.UUID.dump!(locked.activation_epoch),
                 Ecto.UUID.dump!(locked.claim_token),
                 Ecto.UUID.dump!(locked.node_incarnation_id),
                 Ecto.UUID.dump!(locked.supervisor_id),
                 Ecto.UUID.dump!(locked.local_task_id),
                 proof_kind,
                 evidence_id,
                 digest,
                 proved_by
               ]
             ) do
          {:ok, _result} ->
            :ok

          {:error,
           %Postgrex.Error{
             postgres: %{
               code: :check_violation,
               message: "task termination proof does not match its exact physical authority"
             }
           }} ->
            Repo.rollback(:task_termination_capability_mismatch)

          {:error, error} ->
            raise error
        end

        if proof_kind in ["supervisor_down", "never_activated"] do
          clear_local_termination_capability!()
        end

        promote_termination_proof!(locked, proof_kind)
      end,
      opts
    )
  end

  defp prepare_assignment_for_proof!(locked, "never_activated") do
    if locked.state == "reserved" and locked.provider_boundary == "not_entered" and
         is_nil(locked.ready_at) do
      locked
    else
      Repo.rollback(:task_not_canonical_never_activated)
    end
  end

  defp prepare_assignment_for_proof!(locked, "supervisor_down") do
    locked =
      if locked.state == "running",
        do: request_termination_locked!(locked),
        else: locked

    if locked.state == "termination_requested" and not is_nil(locked.ready_at),
      do: locked,
      else: Repo.rollback(:task_not_awaiting_termination_proof)
  end

  defp prepare_assignment_for_proof!(locked, "external_destroyed") do
    case locked do
      %TaskAssignment{state: "reserved", provider_boundary: "not_entered", ready_at: nil} ->
        locked

      %TaskAssignment{state: "termination_requested"} ->
        locked

      _not_provable ->
        Repo.rollback(:task_not_awaiting_termination_proof)
    end
  end

  defp promote_termination_proof!(locked, proof_kind) do
    {set_sql, where_sql} =
      case proof_kind do
        "never_activated" ->
          {
            """
            state = 'termination_proven',
            termination_requested_at = timezone('UTC', clock_timestamp()),
            termination_proven_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
            """,
            "state = 'reserved' AND provider_boundary = 'not_entered' AND ready_at IS NULL"
          }

        "supervisor_down" ->
          {
            """
            state = 'termination_proven',
            termination_proven_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
            """,
            "state = 'termination_requested' AND ready_at IS NOT NULL"
          }

        "external_destroyed" when locked.state == "reserved" ->
          {
            """
            state = 'termination_proven',
            termination_requested_at = timezone('UTC', clock_timestamp()),
            termination_proven_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
            """,
            "state = 'reserved' AND provider_boundary = 'not_entered' AND ready_at IS NULL"
          }

        "external_destroyed" ->
          {
            """
            state = 'termination_proven',
            termination_proven_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
            """,
            "state = 'termination_requested'"
          }
      end

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET #{set_sql}
        WHERE id = $1::uuid AND #{where_sql}
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, termination_capability_digest,
                  state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        [Ecto.UUID.dump!(locked.id)]
      )

    load!(result, :task_termination_proof_lost)
  end

  defp request_termination_locked!(assignment) do
    set_action!(assignment.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = 'termination_requested',
            provider_boundary = CASE WHEN provider_boundary = 'entered'
                                     THEN 'outcome_unknown' ELSE provider_boundary END,
            termination_requested_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND state = 'running'
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, termination_capability_digest,
                  state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        [Ecto.UUID.dump!(assignment.id)]
      )

    load!(result, :task_authority_lost)
  end

  # Canonical mutation order is coordination protocol -> node -> partition ->
  # assignment. Work-specific callers may lock canonical Effect authority first.
  defp lock_authority_rows!(assignment) do
    _ = Protocol.locked_active!()

    node_rows =
      SQL.query!(
        Repo,
        """
        SELECT id FROM public.runtime_node_incarnations
        WHERE id = $1::uuid AND activation_epoch = $2::uuid
        FOR SHARE
        """,
        [
          Ecto.UUID.dump!(assignment.node_incarnation_id),
          Ecto.UUID.dump!(assignment.activation_epoch)
        ]
      ).rows

    if node_rows == [], do: Repo.rollback(:task_authority_lost)

    partition_rows =
      SQL.query!(
        Repo,
        """
        SELECT partition_id FROM public.runtime_partitions
        WHERE partition_id = $1 AND activation_epoch = $2::uuid
          AND ownership_epoch = $3
          AND owner_node_incarnation_id = $4::uuid
        FOR SHARE
        """,
        [
          assignment.partition_id,
          Ecto.UUID.dump!(assignment.activation_epoch),
          assignment.partition_epoch,
          Ecto.UUID.dump!(assignment.node_incarnation_id)
        ]
      ).rows

    if partition_rows == [], do: Repo.rollback(:task_authority_lost)
    :ok
  end

  defp try_lock_assignment(assignment) do
    lock_authority_rows!(assignment)

    Repo.one(
      from(current in TaskAssignment,
        where: current.id == ^assignment.id,
        where: current.activation_epoch == ^assignment.activation_epoch,
        where: current.work_kind == ^assignment.work_kind,
        where: current.work_id == ^assignment.work_id,
        where: current.claim_token == ^assignment.claim_token,
        where: current.partition_id == ^assignment.partition_id,
        where: current.partition_epoch == ^assignment.partition_epoch,
        where: current.node_incarnation_id == ^assignment.node_incarnation_id,
        where: current.supervisor_id == ^assignment.supervisor_id,
        where: current.local_task_id == ^assignment.local_task_id,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp lock_assignment!(assignment) do
    lock_authority_rows!(assignment)

    case Repo.one(
           from(current in TaskAssignment,
             where: current.id == ^assignment.id,
             where: current.activation_epoch == ^assignment.activation_epoch,
             where: current.work_kind == ^assignment.work_kind,
             where: current.work_id == ^assignment.work_id,
             where: current.claim_token == ^assignment.claim_token,
             where: current.partition_id == ^assignment.partition_id,
             where: current.partition_epoch == ^assignment.partition_epoch,
             where: current.node_incarnation_id == ^assignment.node_incarnation_id,
             where: current.supervisor_id == ^assignment.supervisor_id,
             where: current.local_task_id == ^assignment.local_task_id,
             lock: "FOR UPDATE"
           )
         ) do
      %TaskAssignment{} = current -> current
      nil -> Repo.rollback(:task_authority_lost)
    end
  end

  defp transition(assignment, set_sql, where_sql, authority_mode \\ nil) do
    Repo.transaction(fn ->
      fence_assignment_authority!(assignment, authority_mode)
      assignment = lock_assignment!(assignment)
      set_action!(assignment.id)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_task_assignments SET #{set_sql}
          WHERE id = $1::uuid AND activation_epoch = $2::uuid
            AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
            AND supervisor_id = $5::uuid AND local_task_id = $6::uuid AND #{where_sql}
          RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                    partition_id, partition_epoch, node_incarnation_id,
                    supervisor_id, local_task_id, termination_capability_digest,
                  state, provider_boundary,
                    lease_expires_at, ready_at, termination_requested_at,
                    termination_proven_at, settled_at, outcome, inserted_at, updated_at
          """,
          identity_params(assignment)
        )

      load!(result, :task_authority_lost)
    end)
  end

  defp fence_assignment_authority!(_assignment, nil), do: :ok

  defp fence_assignment_authority!(%TaskAssignment{} = assignment, :ready) do
    session = %NodeIncarnation{
      id: assignment.node_incarnation_id,
      activation_epoch: assignment.activation_epoch
    }

    Authority.fence_partition!(
      session,
      assignment.partition_id,
      assignment.partition_epoch,
      :ready
    )
  end

  defp fence_effect_authority_in_transaction!(
         %TaskAssignment{} = assignment,
         agent_id,
         owner_generation,
         mode
       )
       when mode in [:ready, :owner] do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "effect authority fence requires transaction")

    {node_states, partition_states, lease_shape, topology_shape, authority_value} =
      case mode do
        :ready ->
          {
            ["ready"],
            ["ready"],
            """
            lease.ready_at IS NOT NULL AND lease.draining_at IS NULL
              AND lease.lease_until > timezone('UTC', clock_timestamp())
            """,
            """
            node.ready_at IS NOT NULL
              AND node.lease_expires_at > timezone('UTC', clock_timestamp())
              AND partition.ready_at IS NOT NULL
              AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
            """,
            "LEAST(node.lease_expires_at, partition.lease_expires_at, lease.lease_until)"
          }

        :owner ->
          {
            ["ready", "draining"],
            ["ready", "draining", "blocked"],
            "(lease.ready_at IS NOT NULL OR lease.draining_at IS NOT NULL)",
            "TRUE",
            "TRUE"
          }
      end

    params = [
      Ecto.UUID.dump!(assignment.activation_epoch),
      assignment.partition_id,
      assignment.partition_epoch,
      Ecto.UUID.dump!(assignment.node_incarnation_id),
      Ecto.UUID.dump!(agent_id),
      Ecto.UUID.dump!(owner_generation)
    ]

    # Settlement can outlive the exact Agent lease row, but bare absence is not
    # authority: only its reconciled, identity-matched termination proof may
    # substitute. A successor lease is a different generation and is not locked
    # here. Admission, provider entry, and renewal always use :ready.
    lease_present? =
      case SQL.query!(
             Repo,
             """
             SELECT lease.agent_id
             FROM public.agent_runtime_leases AS lease
             WHERE lease.agent_id = $5::uuid AND lease.owner_token = $6::uuid
               AND lease.coordination_activation_epoch = $1::uuid
               AND lease.coordination_partition_id = $2
               AND lease.coordination_partition_epoch = $3
               AND lease.coordination_node_incarnation_id = $4::uuid
             FOR SHARE
             """,
             params
           ).rows do
        [[_agent_id]] -> true
        [] when mode == :owner -> false
        [] -> Repo.rollback(:coordination_task_authority_lost)
      end

    case SQL.query!(
           Repo,
           """
           SELECT id
           FROM public.runtime_node_incarnations
           WHERE id = $2::uuid AND activation_epoch = $1::uuid
           FOR SHARE
           """,
           [Enum.at(params, 0), Enum.at(params, 3)]
         ).rows do
      [[_node_id]] -> :ok
      _missing_or_mismatched -> Repo.rollback(:coordination_task_authority_lost)
    end

    case SQL.query!(
           Repo,
           """
           SELECT partition_id
           FROM public.runtime_partitions
           WHERE partition_id = $2 AND activation_epoch = $1::uuid
             AND ownership_epoch = $3
             AND owner_node_incarnation_id = $4::uuid
           FOR SHARE
           """,
           Enum.take(params, 4)
         ).rows do
      [[_partition_id]] -> :ok
      _missing_or_mismatched -> Repo.rollback(:coordination_task_authority_lost)
    end

    case SQL.query!(
           Repo,
           """
           SELECT #{authority_value}
           FROM public.runtime_node_incarnations AS node
           JOIN public.runtime_partitions AS partition
             ON partition.partition_id = $2
            AND partition.activation_epoch = $1::uuid
            AND partition.ownership_epoch = $3
            AND partition.owner_node_incarnation_id = $4::uuid
            AND partition.state = ANY($8::text[])
           LEFT JOIN public.agent_runtime_leases AS lease
             ON lease.agent_id = $5::uuid AND lease.owner_token = $6::uuid
            AND lease.coordination_activation_epoch = $1::uuid
            AND lease.coordination_partition_id = $2
            AND lease.coordination_partition_epoch = $3
            AND lease.coordination_node_incarnation_id = $4::uuid
           WHERE node.id = $4::uuid AND node.activation_epoch = $1::uuid
             AND node.state = ANY($7::text[])
             AND #{topology_shape}
             AND (
               ($9::boolean AND lease.agent_id IS NOT NULL AND #{lease_shape})
               OR
               (NOT $9::boolean AND $10::boolean AND lease.agent_id IS NULL
                AND EXISTS (
                  SELECT 1
                  FROM public.agent_termination_incidents AS incident
                  JOIN public.agent_termination_proofs AS proof
                    ON proof.id = incident.proof_id
                   AND proof.incident_id = incident.id
                   AND proof.activation_epoch = incident.activation_epoch
                   AND proof.node_incarnation_id = incident.node_incarnation_id
                   AND proof.partition_id = incident.partition_id
                   AND proof.partition_epoch = incident.partition_epoch
                   AND proof.agent_id = incident.agent_id
                   AND proof.lease_token = incident.lease_token
                   AND proof.proof_kind = incident.proof_kind
                   AND proof.proved_at = incident.proved_at
                  WHERE incident.status = 'reconciled'
                    AND incident.reconciled_at IS NOT NULL
                    AND incident.activation_epoch = $1::uuid
                    AND incident.node_incarnation_id = $4::uuid
                    AND incident.partition_id = $2
                    AND incident.partition_epoch = $3
                    AND incident.agent_id = $5::uuid
                    AND incident.lease_token = $6::uuid
                    AND proof.activation_epoch = $1::uuid
                    AND proof.node_incarnation_id = $4::uuid
                    AND proof.partition_id = $2
                    AND proof.partition_epoch = $3
                    AND proof.agent_id = $5::uuid
                    AND proof.lease_token = $6::uuid
                ))
             )
           """,
           params ++ [node_states, partition_states, lease_present?, mode == :owner]
         ).rows do
      [[authority]] when not is_nil(authority) -> authority
      [] -> Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp never_activated_evidence_id(assignment),
    do: "task-supervisor:never_activated:#{assignment.local_task_id}"

  defp task_identity(assignment) do
    %{
      work_kind: assignment.work_kind,
      work_id: assignment.work_id,
      claim_token: assignment.claim_token,
      assignment_id: assignment.id,
      supervisor_id: assignment.supervisor_id,
      local_task_id: assignment.local_task_id
    }
  end

  defp identity_params(a),
    do: [
      Ecto.UUID.dump!(a.id),
      Ecto.UUID.dump!(a.activation_epoch),
      Ecto.UUID.dump!(a.claim_token),
      Ecto.UUID.dump!(a.node_incarnation_id),
      Ecto.UUID.dump!(a.supervisor_id),
      Ecto.UUID.dump!(a.local_task_id)
    ]

  defp load(%{columns: columns, rows: [row]}), do: Repo.load(TaskAssignment, {columns, row})
  defp load!(%{rows: []}, reason), do: Repo.rollback(reason)
  defp load!(result, _), do: load(result)

  defp set_action!(id), do: set_local!("maraithon.runtime_task_action", id)

  defp set_local!(key, value),
    do: SQL.query!(Repo, "SELECT set_config($1, $2, true)", [key, to_string(value)])

  defp verify_secret_logging_policy! do
    SecretParameterLoggingPolicy.verify!(:task_termination_secret_logging_policy_unsafe)
  end

  defp set_local_termination_capability!(capability_secret) do
    case SQL.query!(
           Repo,
           "SELECT set_config($1, $2, true) IS NOT NULL",
           [
             "maraithon.runtime_task_termination_capability",
             Base.encode64(capability_secret)
           ],
           log: false,
           telemetry_event: false
         ).rows do
      [[true]] -> :ok
      _not_set -> Repo.rollback(:task_termination_capability_not_set)
    end
  end

  defp clear_local_termination_capability! do
    _ =
      SQL.query!(
        Repo,
        "SELECT set_config($1, '', true) IS NOT NULL",
        ["maraithon.runtime_task_termination_capability"],
        log: false,
        telemetry_event: false
      )

    :ok
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_task_identity}
    end
  end
end
