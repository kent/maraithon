defmodule Maraithon.Runtime.Coordination.Authority do
  @moduledoc """
  PostgreSQL-clock node, leader and partition authority.

  All mutating functions carry the activation epoch plus an exact node/leader
  incarnation token into the same transaction as the action. Expired epochs
  are never renewed. Readiness is a separate, final write.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.{NodeIncarnation, Partition, Protocol}

  @max_ttl_ms 300_000
  @deployment_gate_node_name "__maraithon_deployment_gate__"
  @legacy_deployment_generation "legacy"
  @deployment_generation_pattern ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @image_digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/
  @deployment_gate_migration 20_260_904_190_000

  @doc "Returns the immutable Cloud Run revision identity used by the deployment gate."
  def deployment_generation do
    case System.get_env("MARAITHON_DEPLOYMENT_GENERATION", "") |> String.trim() do
      "" ->
        case System.get_env("K_REVISION") do
          value when is_binary(value) and value != "" -> value
          _ -> @legacy_deployment_generation
        end

      stable_generation ->
        stable_generation
    end
  end

  @doc "Returns the latest durable deployment gate projection used by deploy status checks."
  def deployment_gate_status do
    case latest_deployment_gate!() do
      nil ->
        nil

      gate ->
        %{
          state: Map.fetch!(gate, "state"),
          target_generation: Map.fetch!(gate, "target_generation"),
          stable_generation: Map.fetch!(gate, "stable_generation"),
          image_digest: Map.fetch!(gate, "image_digest")
        }
    end
  end

  def register_node(opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    node_name = Keyword.get(opts, :node_name, Atom.to_string(node()))
    revision = Keyword.get(opts, :revision, System.get_env("GIT_SHA", "development"))
    ttl_ms = Keyword.get(opts, :ttl_ms, 30_000)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, id} <- cast_uuid(id),
         :ok <- valid_text(node_name),
         :ok <- valid_text(revision),
         :ok <- valid_ttl(ttl_ms),
         true <- is_map(metadata) do
      Repo.transaction(fn ->
        require_read_committed!()
        activation_epoch = Protocol.locked_active!()
        require_deployment_gate_installed!()
        require_deployment_generation_admitted!(metadata)
        set_local!("maraithon.runtime_node_action", id)

        result =
          SQL.query!(
            Repo,
            """
            INSERT INTO public.runtime_node_incarnations
              (id, activation_epoch, node_name, revision, state, lease_expires_at, metadata,
               inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, $3, $4, 'joining',
                    timezone('UTC', clock_timestamp()) + ($5::bigint * interval '1 millisecond'),
                    $6::jsonb, timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            RETURNING id, activation_epoch, node_name, revision, state, lease_expires_at,
                      ready_at, draining_at, revoked_at, metadata, inserted_at, updated_at
            """,
            [
              Ecto.UUID.dump!(id),
              Ecto.UUID.dump!(activation_epoch),
              node_name,
              revision,
              ttl_ms,
              metadata
            ]
          )

        load(NodeIncarnation, result)
      end)
    else
      false -> {:error, :invalid_node_metadata}
      {:error, _} = error -> error
    end
  end

  @doc """
  Atomically closes new node admission before a revision drain starts.

  Deployment gates are append-only revoked rows in the node-incarnation
  ledger. The database trigger serializes this operation with registration and
  readiness publication through the protocol-row lock. Only the migrator role
  may append one.
  """
  def arm_deployment_handoff(target_generation, image_digest)
      when is_binary(target_generation) and is_binary(image_digest) do
    with :ok <- valid_deployment_generation(target_generation),
         :ok <- valid_image_digest(image_digest),
         false <- target_generation == @legacy_deployment_generation do
      Repo.transaction(fn ->
        require_read_committed!()
        {activation_epoch, exact_revision} = lock_deployment_protocol!()
        latest = latest_deployment_gate!()

        case latest do
          %{
            "state" => "handoff",
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          } ->
            :already_armed

          %{
            "state" => state,
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          }
          when state in ["deploying", "activating"] ->
            Repo.rollback(:deployment_handoff_already_proven)

          %{"state" => state, "target_generation" => pending_generation}
          when state in ["handoff", "deploying", "activating"] ->
            Repo.rollback({:deployment_handoff_already_armed, pending_generation})

          %{"state" => state, "stable_generation" => stable_generation}
          when state in ["stable", "aborted"] ->
            reject_reused_deployment_generation!(target_generation)

            append_deployment_gate!(
              activation_epoch,
              exact_revision,
              latest,
              "handoff",
              target_generation,
              stable_generation,
              image_digest
            )

            :armed

          nil ->
            reject_reused_deployment_generation!(target_generation)

            append_deployment_gate!(
              activation_epoch,
              exact_revision,
              nil,
              "handoff",
              target_generation,
              @legacy_deployment_generation,
              image_digest
            )

            :armed

          _ ->
            Repo.rollback(:deployment_gate_invalid)
        end
      end)
    else
      true -> {:error, :legacy_generation_cannot_be_a_handoff_target}
      {:error, _reason} = error -> error
    end
  end

  def arm_deployment_handoff(_target_generation, _image_digest),
    do: {:error, :invalid_deployment_handoff}

  @doc "Closes all admission after repeating the exact drain proof in PostgreSQL."
  def prove_deployment_handoff(target_generation, image_digest)
      when is_binary(target_generation) and is_binary(image_digest) do
    with :ok <- valid_deployment_generation(target_generation),
         :ok <- valid_image_digest(image_digest) do
      Repo.transaction(fn ->
        require_read_committed!()
        {activation_epoch, exact_revision} = lock_deployment_protocol!()
        latest = latest_deployment_gate!()

        case latest do
          %{
            "state" => state,
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          }
          when state in ["deploying", "activating"] ->
            :already_proven

          %{
            "state" => "handoff",
            "target_generation" => ^target_generation,
            "stable_generation" => stable_generation,
            "image_digest" => ^image_digest
          } ->
            prove_deployment_handoff_quiescent!()

            append_deployment_gate!(
              activation_epoch,
              exact_revision,
              latest,
              "deploying",
              target_generation,
              stable_generation,
              image_digest
            )

            :proven

          %{"state" => state, "target_generation" => pending_generation}
          when state in ["handoff", "deploying", "activating"] ->
            Repo.rollback({:deployment_handoff_target_mismatch, pending_generation})

          %{"state" => state, "stable_generation" => stable_generation}
          when state in ["stable", "aborted"] ->
            Repo.rollback({:deployment_handoff_not_armed, stable_generation})

          _ ->
            Repo.rollback(:deployment_gate_missing)
        end
      end)
    end
  end

  def prove_deployment_handoff(_target_generation, _image_digest),
    do: {:error, :invalid_deployment_handoff}

  @doc "Admits only the proven target generation while its runtime readiness is verified."
  def activate_deployment_generation(target_generation, image_digest)
      when is_binary(target_generation) and is_binary(image_digest) do
    with :ok <- valid_deployment_generation(target_generation),
         :ok <- valid_image_digest(image_digest) do
      Repo.transaction(fn ->
        require_read_committed!()
        {activation_epoch, exact_revision} = lock_deployment_protocol!()
        latest = latest_deployment_gate!()

        case latest do
          %{
            "state" => "activating",
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          } ->
            :already_activating

          %{
            "state" => "deploying",
            "target_generation" => ^target_generation,
            "stable_generation" => stable_generation,
            "previous_generation" => previous_generation,
            "image_digest" => ^image_digest
          } ->
            append_deployment_gate!(
              activation_epoch,
              exact_revision,
              latest,
              "activating",
              target_generation,
              stable_generation,
              image_digest,
              previous_generation
            )

            :activated

          %{"state" => state, "target_generation" => pending_generation}
          when state in ["handoff", "deploying", "activating"] ->
            Repo.rollback({:deployment_activation_target_mismatch, pending_generation})

          %{"state" => state, "stable_generation" => stable_generation}
          when state in ["stable", "aborted"] ->
            Repo.rollback({:deployment_handoff_not_proven, stable_generation})

          _ ->
            Repo.rollback(:deployment_gate_missing)
        end
      end)
    end
  end

  def activate_deployment_generation(_target_generation, _image_digest),
    do: {:error, :invalid_deployment_handoff}

  @doc "Retargets an irreversible handoff when its Cloud Run revision cannot become viable."
  def retarget_deployment_handoff(
        current_generation,
        current_image_digest,
        target_generation,
        target_image_digest
      )
      when is_binary(current_generation) and is_binary(current_image_digest) and
             is_binary(target_generation) and is_binary(target_image_digest) do
    with :ok <- valid_deployment_generation(current_generation),
         :ok <- valid_image_digest(current_image_digest),
         :ok <- valid_deployment_generation(target_generation),
         :ok <- valid_image_digest(target_image_digest),
         false <- target_generation == @legacy_deployment_generation,
         false <- target_generation == current_generation do
      Repo.transaction(fn ->
        require_read_committed!()
        {activation_epoch, exact_revision} = lock_deployment_protocol!()
        latest = latest_deployment_gate!()

        case latest do
          %{
            "state" => "deploying",
            "target_generation" => ^target_generation,
            "image_digest" => ^target_image_digest,
            "sequence" => sequence
          } ->
            if deployment_gate_predecessor_matches?(
                 sequence,
                 current_generation,
                 current_image_digest
               ) do
              :already_retargeted
            else
              Repo.rollback(:deployment_retarget_predecessor_mismatch)
            end

          %{
            "state" => state,
            "target_generation" => ^current_generation,
            "stable_generation" => stable_generation,
            "image_digest" => ^current_image_digest
          }
          when state in ["deploying", "activating"] ->
            reject_reused_deployment_generation!(target_generation)
            prove_deployment_handoff_quiescent!()

            append_deployment_gate!(
              activation_epoch,
              exact_revision,
              latest,
              "deploying",
              target_generation,
              stable_generation,
              target_image_digest
            )

            :retargeted

          %{"state" => state, "target_generation" => pending_generation}
          when state in ["deploying", "activating"] ->
            Repo.rollback({:deployment_handoff_target_mismatch, pending_generation})

          %{"state" => state} when state in ["handoff", "stable", "aborted"] ->
            Repo.rollback({:deployment_handoff_not_deploying, state})

          _ ->
            Repo.rollback(:deployment_gate_missing)
        end
      end)
    else
      true -> {:error, :invalid_deployment_retarget}
      {:error, _reason} = error -> error
    end
  end

  def retarget_deployment_handoff(
        _current_generation,
        _current_image_digest,
        _target_generation,
        _target_image_digest
      ),
      do: {:error, :invalid_deployment_retarget}

  @doc "Makes a fully ready activating Cloud Run revision the stable generation."
  def stabilize_deployment_generation(target_generation, image_digest)
      when is_binary(target_generation) and is_binary(image_digest) do
    with :ok <- valid_deployment_generation(target_generation),
         :ok <- valid_image_digest(image_digest) do
      Repo.transaction(fn ->
        require_read_committed!()
        {activation_epoch, exact_revision} = lock_deployment_protocol!()
        latest = latest_deployment_gate!()

        case latest do
          %{
            "state" => "stable",
            "stable_generation" => ^target_generation,
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          } ->
            :already_stable

          %{
            "state" => "activating",
            "target_generation" => ^target_generation,
            "stable_generation" => previous_generation,
            "image_digest" => ^image_digest
          } ->
            require_deployment_generation_ready!(
              target_generation,
              activation_epoch,
              exact_revision
            )

            append_deployment_gate!(
              activation_epoch,
              exact_revision,
              latest,
              "stable",
              target_generation,
              target_generation,
              image_digest,
              previous_generation
            )

            :stabilized

          %{
            "state" => "deploying",
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          } ->
            Repo.rollback({:deployment_generation_not_activating, "deploying"})

          %{"state" => state, "target_generation" => pending_generation}
          when state in ["handoff", "deploying", "activating"] ->
            Repo.rollback({:deployment_handoff_target_mismatch, pending_generation})

          %{"state" => state, "stable_generation" => stable_generation}
          when state in ["stable", "aborted"] ->
            Repo.rollback({:deployment_handoff_not_armed, stable_generation})

          _ ->
            Repo.rollback(:deployment_gate_missing)
        end
      end)
    end
  end

  def stabilize_deployment_generation(_target_generation, _image_digest),
    do: {:error, :invalid_deployment_handoff}

  @doc "Records a pre-proof abort and reopens admission for the last stable generation."
  def abort_deployment_handoff(target_generation, image_digest)
      when is_binary(target_generation) and is_binary(image_digest) do
    with :ok <- valid_deployment_generation(target_generation),
         :ok <- valid_image_digest(image_digest) do
      Repo.transaction(fn ->
        require_read_committed!()
        {activation_epoch, exact_revision} = lock_deployment_protocol!()
        latest = latest_deployment_gate!()

        case latest do
          %{
            "state" => "handoff",
            "target_generation" => ^target_generation,
            "stable_generation" => stable_generation,
            "image_digest" => ^image_digest
          } ->
            append_deployment_gate!(
              activation_epoch,
              exact_revision,
              latest,
              "aborted",
              target_generation,
              stable_generation,
              image_digest
            )

            :aborted

          %{
            "state" => state,
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          }
          when state in ["deploying", "activating"] ->
            Repo.rollback(:deployment_handoff_irreversible)

          %{"state" => state, "target_generation" => pending_generation}
          when state in ["handoff", "deploying", "activating"] ->
            Repo.rollback({:deployment_handoff_target_mismatch, pending_generation})

          %{
            "state" => "aborted",
            "target_generation" => ^target_generation,
            "image_digest" => ^image_digest
          } ->
            :already_aborted

          %{"state" => state, "stable_generation" => stable_generation}
          when state in ["stable", "aborted"] ->
            Repo.rollback({:deployment_handoff_not_armed, stable_generation})

          _ ->
            Repo.rollback(:deployment_gate_missing)
        end
      end)
    end
  end

  def abort_deployment_handoff(_target_generation, _image_digest),
    do: {:error, :invalid_deployment_handoff}

  def mark_node_ready(%NodeIncarnation{} = session) do
    Repo.transaction(fn ->
      require_read_committed!()
      _ = Protocol.locked_active!()
      require_deployment_gate_installed!()
      require_deployment_generation_admitted!(session.metadata)
      set_local!("maraithon.runtime_node_action", session.id)

      update_node!(
        session,
        """
        state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
        draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
        """,
        "state = 'joining' AND lease_expires_at > timezone('UTC', clock_timestamp())"
      )
    end)
  end

  def renew_node(%NodeIncarnation{} = session, ttl_ms) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        _ = Protocol.locked_active!()
        set_local!("maraithon.runtime_node_action", session.id)

        update_node!(
          session,
          """
          lease_expires_at = timezone('UTC', clock_timestamp()) +
            (#{ttl_ms}::bigint * interval '1 millisecond'),
          updated_at = timezone('UTC', clock_timestamp())
          """,
          "state IN ('joining', 'ready', 'draining') AND lease_expires_at > timezone('UTC', clock_timestamp())"
        )
      end)
    end
  end

  def begin_node_drain(%NodeIncarnation{} = session) do
    # Phase one is topology-only. It must commit before touching Agent leases,
    # Effects, or assignments: provider entry takes Agent lease -> topology,
    # while Guardian persistence takes Effect -> topology -> assignment.
    case Repo.transaction(fn ->
           _ = lock_active_effect_pair!()
           revoke_owned_leader!(session)
           locked = lock_node!(session)
           set_local!("maraithon.runtime_node_action", session.id)

           now_sql = "timezone('UTC', clock_timestamp())"

           update_node!(
             locked,
             "state = 'draining', ready_at = NULL, draining_at = COALESCE(draining_at, #{now_sql}), updated_at = #{now_sql}",
             "state IN ('joining', 'ready', 'draining')"
           )

           rows =
             SQL.query!(
               Repo,
               """
               SELECT partition_id, ownership_epoch FROM public.runtime_partitions
               WHERE owner_node_incarnation_id = $1::uuid AND state IN ('preparing', 'ready')
               ORDER BY partition_id FOR UPDATE
               """,
               [Ecto.UUID.dump!(session.id)]
             ).rows

           Enum.each(rows, fn [partition_id, _ownership_epoch] ->
             SQL.query!(
               Repo,
               """
               UPDATE public.runtime_partitions
               SET state = 'draining', ready_at = NULL,
                   draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE partition_id = $1 AND owner_node_incarnation_id = $2::uuid
                 AND state IN ('preparing', 'ready')
               """,
               [partition_id, Ecto.UUID.dump!(session.id)]
             )

             SQL.query!(
               Repo,
               """
               UPDATE public.runtime_partition_transitions
               SET state = 'draining', updated_at = timezone('UTC', clock_timestamp())
               WHERE id = (SELECT transition_id FROM public.runtime_partitions WHERE partition_id = $1)
                 AND state IN ('preparing', 'ready')
               """,
               [partition_id]
             )
           end)

           SQL.query!(
             Repo,
             """
             SELECT partition_id, ownership_epoch FROM public.runtime_partitions
             WHERE activation_epoch = $1::uuid AND owner_node_incarnation_id = $2::uuid
               AND state IN ('draining', 'blocked')
             ORDER BY partition_id FOR UPDATE
             """,
             [
               Ecto.UUID.dump!(session.activation_epoch),
               Ecto.UUID.dump!(session.id)
             ]
           ).rows
           |> Enum.map(fn [partition_id, ownership_epoch] ->
             {partition_id, ownership_epoch}
           end)
         end) do
      {:ok, partitions} -> revoke_node_workload_after_fence(session, partitions)
      {:error, _reason} = error -> error
    end
  end

  def revoke_node(%NodeIncarnation{} = session) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      set_local!("maraithon.runtime_node_action", session.id)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_node_incarnations AS node
          SET state = 'revoked', ready_at = NULL,
              revoked_at = timezone('UTC', clock_timestamp()),
              updated_at = timezone('UTC', clock_timestamp())
          WHERE node.id = $1::uuid AND node.activation_epoch = $2::uuid
            AND node.state = 'draining'
            AND NOT EXISTS (
              SELECT 1 FROM public.runtime_task_assignments AS assignment
              WHERE assignment.node_incarnation_id = node.id
                AND assignment.state IN (
                  'reserved', 'running', 'termination_requested', 'termination_proven'
                )
            )
            AND NOT EXISTS (
              SELECT 1 FROM public.agent_runtime_leases AS lease
              WHERE lease.coordination_node_incarnation_id = node.id
            )
            AND NOT EXISTS (
              SELECT 1 FROM public.runtime_partitions AS partition
              WHERE partition.owner_node_incarnation_id = node.id
            )
          RETURNING node.id, node.activation_epoch, node.node_name, node.revision,
                    node.state, node.lease_expires_at, node.ready_at, node.draining_at,
                    node.revoked_at, node.metadata, node.inserted_at, node.updated_at
          """,
          [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
        )

      case result.rows do
        [_row] -> load(NodeIncarnation, result)
        [] -> Repo.rollback(:node_not_drained)
      end
    end)
  end

  def acquire_leader(%NodeIncarnation{} = session, ttl_ms \\ 15_000) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        activation_epoch = Protocol.locked_active!()
        token = Ecto.UUID.generate()
        set_local!("maraithon.runtime_leader_action", token)

        leader =
          SQL.query!(
            Repo,
            "SELECT state, leader_epoch, lease_expires_at, node_incarnation_id FROM public.runtime_leader_authorities WHERE role = 'partition_planner' FOR UPDATE",
            []
          ).rows

        _ = lock_node!(session)

        case leader do
          [[state, _epoch, expires_at, node_id]]
          when state in ["preparing", "ready"] and not is_nil(expires_at) ->
            cond do
              db_future?(expires_at) ->
                Repo.rollback(:leader_held)

              state == "ready" and node_id == Ecto.UUID.dump!(session.id) ->
                Repo.rollback(:leader_incarnation_expired)

              true ->
                take_leader!(session, activation_epoch, token, ttl_ms)
            end

          [[_state, _epoch, _expires_at, _node_id]] ->
            take_leader!(session, activation_epoch, token, ttl_ms)
        end
      end)
    end
  end

  def mark_leader_ready(leader) when is_map(leader) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      set_local!("maraithon.runtime_leader_action", leader.action_token)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_leader_authorities
          SET state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
              draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
          WHERE role = 'partition_planner' AND state = 'preparing'
            AND activation_epoch = $1::uuid AND leader_epoch = $2
            AND node_incarnation_id = $3::uuid AND action_token = $4::uuid
            AND lease_expires_at > timezone('UTC', clock_timestamp())
          RETURNING activation_epoch, leader_epoch, node_incarnation_id, action_token,
                    state, lease_expires_at, ready_at
          """,
          leader_params(leader)
        )

      load_leader!(result)
    end)
  end

  def renew_leader(leader, ttl_ms) when is_map(leader) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        _ = Protocol.locked_active!()
        set_local!("maraithon.runtime_leader_action", leader.action_token)

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_leader_authorities
            SET lease_expires_at = timezone('UTC', clock_timestamp()) +
                  ($5::bigint * interval '1 millisecond'),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE role = 'partition_planner' AND state = 'ready'
              AND activation_epoch = $1::uuid AND leader_epoch = $2
              AND node_incarnation_id = $3::uuid AND action_token = $4::uuid
              AND lease_expires_at > timezone('UTC', clock_timestamp())
            RETURNING activation_epoch, leader_epoch, node_incarnation_id, action_token,
                      state, lease_expires_at, ready_at
            """,
            leader_params(leader) ++ [ttl_ms]
          )

        load_leader!(result)
      end)
    end
  end

  def assign_partition(leader, %NodeIncarnation{} = target, partition_id, opts \\ [])
      when is_map(leader) and is_integer(partition_id) and is_list(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, 30_000)
    kind = Keyword.get(opts, :kind, "assign")

    with :ok <- valid_ttl(ttl_ms), true <- kind in ~w(assign rebalance steal lease_expired) do
      Repo.transaction(fn ->
        activation_epoch = fence_leader!(leader)
        _ = lock_node!(target)
        transition_id = Ecto.UUID.generate()
        set_local!("maraithon.runtime_leader_action", leader.action_token)

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_partitions
            SET activation_epoch = $2::uuid, ownership_epoch = ownership_epoch + 1,
                owner_node_incarnation_id = $3::uuid, transition_id = $4::uuid,
                state = 'preparing', lease_expires_at = timezone('UTC', clock_timestamp()) +
                  ($5::bigint * interval '1 millisecond'),
                ready_at = NULL, draining_at = NULL,
                last_moved_at = timezone('UTC', clock_timestamp()),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE partition_id = $1 AND state = 'unassigned'
            RETURNING partition_id, activation_epoch, ownership_epoch,
                      owner_node_incarnation_id, transition_id, state, lease_expires_at,
                      ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
            """,
            [
              partition_id,
              Ecto.UUID.dump!(activation_epoch),
              Ecto.UUID.dump!(target.id),
              Ecto.UUID.dump!(transition_id),
              ttl_ms
            ]
          )

        partition = load!(Partition, result, :partition_not_assignable)

        SQL.query!(
          Repo,
          """
          INSERT INTO public.runtime_partition_transitions
            (id, activation_epoch, partition_id, partition_epoch,
             from_node_incarnation_id, to_node_incarnation_id, kind, state,
             leader_node_incarnation_id, leader_epoch, leader_action_token,
             requested_at, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, $3, $4, NULL, $5::uuid, $6, 'preparing',
                  $7::uuid, $8, $9::uuid, timezone('UTC', clock_timestamp()),
                  timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
          """,
          [
            Ecto.UUID.dump!(transition_id),
            Ecto.UUID.dump!(activation_epoch),
            partition_id,
            partition.ownership_epoch,
            Ecto.UUID.dump!(target.id),
            kind,
            Ecto.UUID.dump!(leader.node_incarnation_id),
            leader.leader_epoch,
            Ecto.UUID.dump!(leader.action_token)
          ]
        )

        partition
      end)
    else
      false -> {:error, :invalid_partition_transition_kind}
      {:error, _} = error -> error
    end
  end

  def mark_partition_ready(%NodeIncarnation{} = session, partition_id)
      when is_integer(partition_id) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      _ = lock_node!(session)
      set_local!("maraithon.runtime_node_action", session.id)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_partitions
          SET state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
              draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
          WHERE partition_id = $1 AND state = 'preparing'
            AND owner_node_incarnation_id = $2::uuid
            AND lease_expires_at > timezone('UTC', clock_timestamp())
          RETURNING partition_id, activation_epoch, ownership_epoch,
                    owner_node_incarnation_id, transition_id, state, lease_expires_at,
                    ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
          """,
          [partition_id, Ecto.UUID.dump!(session.id)]
        )

      partition = load!(Partition, result, :partition_authority_lost)

      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_partition_transitions
        SET state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND state = 'preparing'
        """,
        [Ecto.UUID.dump!(partition.transition_id)]
      )

      partition
    end)
  end

  def renew_partitions(%NodeIncarnation{} = session, ttl_ms) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        _ = Protocol.locked_active!()
        _ = lock_node!(session)
        set_local!("maraithon.runtime_node_action", session.id)

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_partitions
            SET lease_expires_at = timezone('UTC', clock_timestamp()) +
                  ($2::bigint * interval '1 millisecond'),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE owner_node_incarnation_id = $1::uuid
              AND state IN ('preparing', 'ready', 'draining')
              AND lease_expires_at > timezone('UTC', clock_timestamp())
            RETURNING partition_id, activation_epoch, ownership_epoch,
                      owner_node_incarnation_id, transition_id, state, lease_expires_at,
                      ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
            """,
            [Ecto.UUID.dump!(session.id), ttl_ms]
          )

        load_many(Partition, result)
      end)
    end
  end

  def begin_partition_drain(leader, partition_id, opts \\ []) when is_map(leader) do
    kind = Keyword.get(opts, :kind, "rebalance")
    target_id = Keyword.get(opts, :target_node_incarnation_id)
    blocked? = Keyword.get(opts, :blocked?, false)

    with true <- kind in ~w(rebalance steal shutdown lease_expired),
         {:ok, target_dump} <- optional_uuid_dump(target_id) do
      case Repo.transaction(fn ->
             # Commit the monotone topology fence before touching leases,
             # Effects, or assignments. Admission takes node/partition SHARE
             # locks, so this phase also serializes every exact work INSERT.
             activation_epoch = lock_active_effect_pair!()
             leader_epoch = fence_leader!(leader)

             if leader_epoch != activation_epoch,
               do: Repo.rollback(:leader_authority_lost)

             set_local!("maraithon.runtime_leader_action", leader.action_token)

             [[from_node, ownership_epoch, current_state, current_transition_dump]] =
               SQL.query!(
                 Repo,
                 """
                 SELECT owner_node_incarnation_id, ownership_epoch, state, transition_id
                 FROM public.runtime_partitions
                 WHERE partition_id = $1 AND activation_epoch = $2::uuid
                   AND state IN ('preparing', 'ready')
                 FOR UPDATE
                 """,
                 [partition_id, Ecto.UUID.dump!(activation_epoch)]
               ).rows

             transition_id =
               if current_state == "preparing" do
                 Ecto.UUID.load!(current_transition_dump)
               else
                 Ecto.UUID.generate()
               end

             transition_dump = Ecto.UUID.dump!(transition_id)
             state = if blocked?, do: "blocked", else: "draining"
             reason = if blocked?, do: "physical_task_termination_proof_required", else: nil

             if current_state == "preparing" do
               SQL.query!(
                 Repo,
                 """
                 UPDATE public.runtime_partition_transitions
                 SET state = $2, blocked_reason = $3,
                     updated_at = timezone('UTC', clock_timestamp())
                 WHERE id = $1::uuid AND state = 'preparing'
                 """,
                 [transition_dump, state, reason]
               )
             else
               SQL.query!(
                 Repo,
                 """
                 INSERT INTO public.runtime_partition_transitions
                   (id, activation_epoch, partition_id, partition_epoch,
                    from_node_incarnation_id, to_node_incarnation_id, kind, state,
                    leader_node_incarnation_id, leader_epoch, leader_action_token,
                    requested_at, blocked_reason, inserted_at, updated_at)
                 VALUES ($1::uuid, $2::uuid, $3, $4, $5::uuid, $6::uuid, $7, $8,
                         $9::uuid, $10, $11::uuid, timezone('UTC', clock_timestamp()), $12,
                         timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
                 """,
                 [
                   transition_dump,
                   Ecto.UUID.dump!(activation_epoch),
                   partition_id,
                   ownership_epoch,
                   from_node,
                   target_dump,
                   kind,
                   state,
                   Ecto.UUID.dump!(leader.node_incarnation_id),
                   leader.leader_epoch,
                   Ecto.UUID.dump!(leader.action_token),
                   reason
                 ]
               )
             end

             result =
               SQL.query!(
                 Repo,
                 """
                 UPDATE public.runtime_partitions
                 SET transition_id = $2::uuid, state = $3, ready_at = NULL,
                     draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
                     updated_at = timezone('UTC', clock_timestamp())
                 WHERE partition_id = $1 AND activation_epoch = $4::uuid
                   AND ownership_epoch = $5
                 RETURNING partition_id, activation_epoch, ownership_epoch,
                           owner_node_incarnation_id, transition_id, state, lease_expires_at,
                           ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
                 """,
                 [
                   partition_id,
                   transition_dump,
                   state,
                   Ecto.UUID.dump!(activation_epoch),
                   ownership_epoch
                 ]
               )

             partition = load!(Partition, result, :partition_authority_lost)

             session = %NodeIncarnation{
               id: Ecto.UUID.load!(from_node),
               activation_epoch: activation_epoch
             }

             {partition, session, ownership_epoch}
           end) do
        {:ok, {partition, session, ownership_epoch}} ->
          case revoke_partition_workload_in_epoch(
                 session,
                 partition_id,
                 ownership_epoch,
                 "coordination_partition_draining"
               ) do
            {:ok, :revoked} -> {:ok, partition}
            {:error, _reason} = error -> error
          end

        {:error, _reason} = error ->
          error
      end
    else
      false -> {:error, :invalid_partition_transition_kind}
      {:error, _} = error -> error
    end
  end

  def revoke_partition_workload(%NodeIncarnation{} = session, partition_id) do
    # This read takes no topology lock. The partition is already durably fenced
    # by begin_partition_drain/3 or begin_node_drain/1; every later phase uses
    # that monotone fence and revalidates before topology-dependent mutations.
    case SQL.query!(
           Repo,
           """
           SELECT ownership_epoch FROM public.runtime_partitions
           WHERE partition_id = $1 AND activation_epoch = $2::uuid
             AND owner_node_incarnation_id = $3::uuid
             AND state IN ('draining', 'blocked')
           """,
           [
             partition_id,
             Ecto.UUID.dump!(session.activation_epoch),
             Ecto.UUID.dump!(session.id)
           ]
         ).rows do
      [[ownership_epoch]] ->
        revoke_partition_workload_in_epoch(
          session,
          partition_id,
          ownership_epoch,
          "coordination_partition_draining"
        )

      [] ->
        {:error, :partition_authority_lost}
    end
  end

  defp revoke_node_workload_after_fence(session, partitions) do
    with {:ok, :leases_revoked} <- revoke_node_agent_leases(session),
         :ok <-
           run_partition_phase(partitions, fn {partition_id, ownership_epoch} ->
             request_partition_effect_cancellation(
               session,
               partition_id,
               ownership_epoch,
               "coordination_node_draining"
             )
           end),
         :ok <-
           run_partition_phase(partitions, fn {partition_id, ownership_epoch} ->
             request_partition_non_effect_termination(
               session,
               partition_id,
               ownership_epoch
             )
           end) do
      {:ok, :draining}
    end
  end

  defp revoke_partition_workload_in_epoch(
         %NodeIncarnation{} = session,
         partition_id,
         ownership_epoch,
         reason
       ) do
    with {:ok, :leases_revoked} <-
           revoke_partition_agent_leases(session, partition_id, ownership_epoch),
         {:ok, :effects_cancelled} <-
           request_partition_effect_cancellation(
             session,
             partition_id,
             ownership_epoch,
             reason
           ),
         {:ok, :tasks_requested} <-
           request_partition_non_effect_termination(
             session,
             partition_id,
             ownership_epoch
           ) do
      {:ok, :revoked}
    end
  end

  # Provider entry takes an Agent lease before topology. These phases therefore
  # hold no node or partition lock while waiting for the exact lease rows.
  defp revoke_node_agent_leases(%NodeIncarnation{} = session) do
    Repo.transaction(fn ->
      _ = lock_active_effect_pair!()
      set_local!("maraithon.runtime_node_action", session.id)

      node_id = Ecto.UUID.dump!(session.id)

      # Node-wide and partition-specific drains overlap. Establish the same
      # deterministic lease row order before either bulk UPDATE can plan freely.
      SQL.query!(
        Repo,
        """
        SELECT agent_id FROM public.agent_runtime_leases
        WHERE coordination_node_incarnation_id = $1::uuid
          AND lease_until > timezone('UTC', clock_timestamp())
        ORDER BY agent_id FOR UPDATE
        """,
        [node_id]
      )

      SQL.query!(
        Repo,
        """
        UPDATE public.agent_runtime_leases
        SET ready_at = NULL,
            draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE coordination_node_incarnation_id = $1::uuid
          AND lease_until > timezone('UTC', clock_timestamp())
        """,
        [node_id]
      )

      :leases_revoked
    end)
  end

  defp revoke_partition_agent_leases(session, partition_id, ownership_epoch) do
    Repo.transaction(fn ->
      _ = lock_active_effect_pair!()
      set_local!("maraithon.runtime_node_action", session.id)

      params = [partition_id, ownership_epoch, Ecto.UUID.dump!(session.id)]

      # Match the node-wide lease order so overlapping drains cannot invert.
      SQL.query!(
        Repo,
        """
        SELECT agent_id FROM public.agent_runtime_leases
        WHERE coordination_partition_id = $1 AND coordination_partition_epoch = $2
          AND coordination_node_incarnation_id = $3::uuid
          AND lease_until > timezone('UTC', clock_timestamp())
        ORDER BY agent_id FOR UPDATE
        """,
        params
      )

      SQL.query!(
        Repo,
        """
        UPDATE public.agent_runtime_leases
        SET ready_at = NULL,
            draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE coordination_partition_id = $1 AND coordination_partition_epoch = $2
          AND coordination_node_incarnation_id = $3::uuid
          AND lease_until > timezone('UTC', clock_timestamp())
        """,
        params
      )

      :leases_revoked
    end)
  end

  defp request_partition_effect_cancellation(
         session,
         partition_id,
         ownership_epoch,
         reason
       ) do
    Repo.transaction(fn ->
      pair_lock = lock_active_effect_pair_capability!()

      _ =
        Maraithon.Effects.Cancellation.request_coordination_drain_after_pair_lock_in_transaction!(
          pair_lock,
          session.id,
          partition_id,
          ownership_epoch,
          reason,
          fn ->
            # Guardian persistence locks the Effect first, then these exact
            # topology rows, then its assignment. The helper verifies the
            # transaction-local pair capability and expected epoch before this
            # callback rather than fully reattesting the already-held pair.
            lock_partition_for_settlement!(session, partition_id, ownership_epoch)
          end
        )

      mark_partition_effects_drained!(session, partition_id, ownership_epoch)
      :effects_cancelled
    end)
  end

  defp request_partition_non_effect_termination(session, partition_id, ownership_epoch) do
    Repo.transaction(fn ->
      _ = lock_active_effect_pair!()
      lock_partition_for_settlement!(session, partition_id, ownership_epoch)
      request_task_termination_for_partition!(session.id, partition_id, ownership_epoch)
      :tasks_requested
    end)
  end

  defp lock_partition_for_settlement!(session, partition_id, ownership_epoch) do
    _ = lock_node_for_settlement!(session)
    set_local!("maraithon.runtime_node_action", session.id)

    # Take the final lock mode before Cancellation mutates any Effect rows. The
    # drain marker is published later in this transaction without a lock upgrade.
    case SQL.query!(
           Repo,
           """
           SELECT ownership_epoch FROM public.runtime_partitions
           WHERE partition_id = $1 AND activation_epoch = $2::uuid
             AND ownership_epoch = $3 AND owner_node_incarnation_id = $4::uuid
             AND state IN ('draining', 'blocked') FOR UPDATE
           """,
           [
             partition_id,
             Ecto.UUID.dump!(session.activation_epoch),
             ownership_epoch,
             Ecto.UUID.dump!(session.id)
           ]
         ).rows do
      [[^ownership_epoch]] -> :ok
      [] -> Repo.rollback(:partition_authority_lost)
    end
  end

  defp mark_partition_effects_drained!(session, partition_id, ownership_epoch) do
    # An expired owner may finish already-fenced Effect cancellation but cannot
    # mint the durable marker. Put the same live-owner predicate in the UPDATE so
    # an expired incarnation matches zero rows instead of aborting this outer
    # transaction. A live leader later rechecks the Effect barrier before
    # backfilling the marker on release.
    params = [
      partition_id,
      Ecto.UUID.dump!(session.activation_epoch),
      ownership_epoch,
      Ecto.UUID.dump!(session.id)
    ]

    case SQL.query!(
           Repo,
           """
           UPDATE public.runtime_partitions AS partition
           SET effects_drained_epoch = $3,
               updated_at = timezone('UTC', clock_timestamp())
           WHERE partition.partition_id = $1
             AND partition.activation_epoch = $2::uuid
             AND partition.ownership_epoch = $3
             AND partition.owner_node_incarnation_id = $4::uuid
             AND partition.state IN ('draining', 'blocked')
             AND (partition.effects_drained_epoch IS NULL OR
                  partition.effects_drained_epoch = $3)
             AND EXISTS (
               SELECT 1
               FROM public.runtime_node_incarnations AS node
               WHERE node.id = $4::uuid AND node.activation_epoch = $2::uuid
                 AND node.state IN ('ready', 'draining')
                 AND node.id::text =
                       current_setting('maraithon.runtime_node_action', true)
                 AND node.lease_expires_at > timezone('UTC', clock_timestamp())
             )
           RETURNING partition.effects_drained_epoch
           """,
           params
         ).rows do
      [[^ownership_epoch]] ->
        :ok

      [] ->
        if expired_marker_owner?(params) do
          :marker_deferred
        else
          Repo.rollback(:partition_authority_lost)
        end
    end
  end

  defp expired_marker_owner?(params) do
    case SQL.query!(
           Repo,
           """
           SELECT 1
           FROM public.runtime_partitions AS partition
           JOIN public.runtime_node_incarnations AS node
             ON node.id = $4::uuid AND node.activation_epoch = $2::uuid
            AND node.state IN ('ready', 'draining')
            AND node.lease_expires_at <= timezone('UTC', clock_timestamp())
           WHERE partition.partition_id = $1
             AND partition.activation_epoch = $2::uuid
             AND partition.ownership_epoch = $3
             AND partition.owner_node_incarnation_id = $4::uuid
             AND partition.state IN ('draining', 'blocked')
             AND (partition.effects_drained_epoch IS NULL OR
                  partition.effects_drained_epoch = $3)
           """,
           params
         ).rows do
      [[1]] -> true
      _ -> false
    end
  end

  defp run_partition_phase(partitions, fun) do
    Enum.reduce_while(partitions, :ok, fn partition, :ok ->
      case fun.(partition) do
        {:ok, _phase} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp lock_partition_effect_release_barrier!(activation_epoch, partition_id) do
    case SQL.query!(
           Repo,
           """
           SELECT id FROM public.effects
           WHERE coordination_activation_epoch = $1::uuid
             AND coordination_partition_id = $2
             AND status IN ('pending', 'claimed', 'executing', 'cancelling')
           ORDER BY id FOR UPDATE
           """,
           [Ecto.UUID.dump!(activation_epoch), partition_id]
         ).rows do
      [] -> :ok
      _active_effects -> Repo.rollback(:partition_effects_active)
    end
  end

  def release_drained_partition(leader, partition_id) when is_map(leader) do
    Repo.transaction(
      fn ->
        # A stale partition must not hold the planner past its own lease window.
        # Timeout rolls back the exact release transaction; it never weakens a fence.
        SQL.query!(
          Repo,
          "SELECT set_config('lock_timeout', '1s', true), set_config('statement_timeout', '5s', true)",
          []
        )

        activation_epoch = lock_active_effect_pair!()
        leader_epoch = fence_leader!(leader)

        if leader_epoch != activation_epoch,
          do: Repo.rollback(:leader_authority_lost)

        set_local!("maraithon.runtime_leader_action", leader.action_token)

        # The topology fence prevents new exact work admission. Lock the remaining
        # active Effects before the partition so release serializes with the
        # Effect-first drain phase even if its Agent lease was already proof-deleted.
        lock_partition_effect_release_barrier!(activation_epoch, partition_id)

        {transition, ownership_epoch, effects_drained_epoch} =
          case SQL.query!(
                 Repo,
                 """
                 SELECT transition_id, ownership_epoch, effects_drained_epoch
                 FROM public.runtime_partitions
                 WHERE partition_id = $1 AND activation_epoch = $2::uuid
                   AND state IN ('draining', 'blocked')
                 FOR UPDATE
                 """,
                 [partition_id, Ecto.UUID.dump!(activation_epoch)]
               ).rows do
            [[transition, ownership_epoch, effects_drained_epoch]] ->
              {transition, ownership_epoch, effects_drained_epoch}

            [] ->
              Repo.rollback(:partition_not_drained)
          end

        if effects_drained_epoch not in [nil, ownership_epoch],
          do: Repo.rollback(:partition_not_drained)

        if is_nil(effects_drained_epoch) do
          marker_result =
            SQL.query!(
              Repo,
              """
              UPDATE public.runtime_partitions
              SET effects_drained_epoch = ownership_epoch,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE partition_id = $1 AND activation_epoch = $2::uuid
                AND ownership_epoch = $3 AND effects_drained_epoch IS NULL
                AND state IN ('draining', 'blocked')
              RETURNING partition_id
              """,
              [partition_id, Ecto.UUID.dump!(activation_epoch), ownership_epoch]
            )

          if marker_result.num_rows != 1, do: Repo.rollback(:partition_not_drained)
        end

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_partitions
            SET activation_epoch = NULL, owner_node_incarnation_id = NULL,
                transition_id = NULL, state = 'unassigned', lease_expires_at = NULL,
                ready_at = NULL, draining_at = NULL, effects_drained_epoch = NULL,
                updated_at = timezone('UTC', clock_timestamp())
            WHERE partition_id = $1 AND activation_epoch = $2::uuid
              AND ownership_epoch = $3 AND effects_drained_epoch = $3
              AND state IN ('draining', 'blocked')
            RETURNING partition_id
            """,
            [partition_id, Ecto.UUID.dump!(activation_epoch), ownership_epoch]
          )

        if result.num_rows != 1, do: Repo.rollback(:partition_not_drained)

        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_partition_transitions
          SET state = 'completed', completed_at = timezone('UTC', clock_timestamp()),
              updated_at = timezone('UTC', clock_timestamp())
          WHERE id = $1::uuid AND state IN ('draining', 'blocked')
          """,
          [transition]
        )

        :released
      end,
      timeout: 6_000
    )
  end

  def owned_partitions(%NodeIncarnation{} = session, states \\ ["ready"]) do
    Repo.all(
      from p in Partition,
        where: p.owner_node_incarnation_id == ^session.id,
        where: p.activation_epoch == ^session.activation_epoch,
        where: p.state in ^states,
        where: p.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        order_by: p.partition_id
    )
  end

  # Cleanup scope only: exact local ownership without a lease-time predicate.
  # Never use this query for admission, provider entry, or renewal.
  def locally_owned_revoked_partitions(%NodeIncarnation{} = session) do
    Repo.all(
      from p in Partition,
        where: p.owner_node_incarnation_id == ^session.id,
        where: p.activation_epoch == ^session.activation_epoch,
        where: p.state in ["draining", "blocked"],
        order_by: p.partition_id
    )
  end

  def active_nodes do
    Repo.all(
      from n in NodeIncarnation,
        where: n.state == "ready" and not is_nil(n.ready_at),
        where: n.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        order_by: n.id
    )
  end

  def fence_partition!(%NodeIncarnation{} = session, partition_id, epoch, mode \\ :ready)
      when mode in [:ready, :owner] do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "partition fence requires transaction")

    _ = Protocol.locked_active!()
    states = if mode == :ready, do: ["ready"], else: ["ready", "draining"]

    case SQL.query!(
           Repo,
           """
           SELECT id FROM public.runtime_node_incarnations
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND state = ANY($3::text[])
             AND ($4::boolean = false OR ready_at IS NOT NULL)
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR SHARE
           """,
           [
             Ecto.UUID.dump!(session.id),
             Ecto.UUID.dump!(session.activation_epoch),
             states,
             mode == :ready
           ]
         ).rows do
      [[_id]] -> :ok
      [] -> Repo.rollback(:node_authority_lost)
    end

    case SQL.query!(
           Repo,
           """
           SELECT partition_id FROM public.runtime_partitions
           WHERE partition_id = $1 AND activation_epoch = $2::uuid AND ownership_epoch = $3
             AND owner_node_incarnation_id = $4::uuid AND state = ANY($5::text[])
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR SHARE
           """,
           [
             partition_id,
             Ecto.UUID.dump!(session.activation_epoch),
             epoch,
             Ecto.UUID.dump!(session.id),
             states
           ]
         ).rows do
      [[^partition_id]] -> :ok
      [] -> Repo.rollback(:partition_authority_lost)
    end
  end

  @doc """
  Fences every partition in one statement with the same predicates as
  `fence_partition!/4`: the node once, then all `{partition_id, ownership_epoch}`
  pairs `FOR SHARE`. Fair runners fence their whole owned set on every poll;
  one round trip instead of two per partition keeps the node row's lock queue
  short for the Session's renewals.
  """
  def fence_partitions!(%NodeIncarnation{} = session, partitions, mode \\ :ready)
      when is_list(partitions) and mode in [:ready, :owner] do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "partition fence requires transaction")

    _ = Protocol.locked_active!()
    states = if mode == :ready, do: ["ready"], else: ["ready", "draining"]

    case SQL.query!(
           Repo,
           """
           SELECT id FROM public.runtime_node_incarnations
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND state = ANY($3::text[])
             AND ($4::boolean = false OR ready_at IS NOT NULL)
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR SHARE
           """,
           [
             Ecto.UUID.dump!(session.id),
             Ecto.UUID.dump!(session.activation_epoch),
             states,
             mode == :ready
           ]
         ).rows do
      [[_id]] -> :ok
      [] -> Repo.rollback(:node_authority_lost)
    end

    ids = Enum.map(partitions, & &1.partition_id)
    epochs = Enum.map(partitions, & &1.ownership_epoch)

    fenced =
      SQL.query!(
        Repo,
        """
        SELECT partition.partition_id
        FROM public.runtime_partitions AS partition
        JOIN unnest($1::smallint[], $2::bigint[]) AS expected(partition_id, ownership_epoch)
          ON expected.partition_id = partition.partition_id
         AND expected.ownership_epoch = partition.ownership_epoch
        WHERE partition.activation_epoch = $3::uuid
          AND partition.owner_node_incarnation_id = $4::uuid
          AND partition.state = ANY($5::text[])
          AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
        ORDER BY partition.partition_id
        FOR SHARE OF partition
        """,
        [
          ids,
          epochs,
          Ecto.UUID.dump!(session.activation_epoch),
          Ecto.UUID.dump!(session.id),
          states
        ]
      ).rows
      |> List.flatten()

    if Enum.sort(fenced) == Enum.sort(ids),
      do: :ok,
      else: Repo.rollback(:partition_authority_lost)
  end

  # Drain transactions compose with exact Effect cancellation. Take the complete
  # protocol prefix before leader, node, or partition locks; the cancellation
  # helper later revalidates the pair while these locks are already held.
  defp lock_active_effect_pair! do
    case Protocol.lock_effect_pair!() do
      {:active, epoch} -> epoch
      :legacy -> Protocol.locked_active!()
    end
  end

  defp lock_active_effect_pair_capability! do
    case Protocol.lock_effect_pair_with_capability!() do
      :legacy -> Protocol.locked_active!()
      capability -> capability
    end
  end

  defp take_leader!(session, activation_epoch, token, ttl_ms) do
    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_leader_authorities
        SET activation_epoch = $1::uuid, leader_epoch = leader_epoch + 1,
            node_incarnation_id = $2::uuid, action_token = $3::uuid,
            state = 'preparing', lease_expires_at = timezone('UTC', clock_timestamp()) +
              ($4::bigint * interval '1 millisecond'),
            ready_at = NULL, draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
        WHERE role = 'partition_planner'
        RETURNING activation_epoch, leader_epoch, node_incarnation_id, action_token,
                  state, lease_expires_at, ready_at
        """,
        [
          Ecto.UUID.dump!(activation_epoch),
          Ecto.UUID.dump!(session.id),
          Ecto.UUID.dump!(token),
          ttl_ms
        ]
      )

    load_leader!(result)
  end

  defp fence_leader!(leader) do
    set_local!("maraithon.runtime_leader_action", leader.action_token)

    case SQL.query!(
           Repo,
           """
           SELECT activation_epoch FROM public.runtime_leader_authorities
           WHERE role = 'partition_planner' AND state = 'ready'
             AND activation_epoch = $1::uuid AND leader_epoch = $2
             AND node_incarnation_id = $3::uuid AND action_token = $4::uuid
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR SHARE
           """,
           leader_params(leader)
         ).rows do
      [[epoch]] -> Ecto.UUID.load!(epoch)
      [] -> Repo.rollback(:leader_authority_lost)
    end
  end

  defp revoke_owned_leader!(session) do
    case SQL.query!(
           Repo,
           """
           SELECT action_token FROM public.runtime_leader_authorities
           WHERE role = 'partition_planner' AND node_incarnation_id = $1::uuid
             AND state IN ('preparing', 'ready')
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(session.id)]
         ).rows do
      [[token]] ->
        token = Ecto.UUID.load!(token)
        set_local!("maraithon.runtime_leader_action", token)

        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_leader_authorities
          SET state = 'draining', ready_at = NULL,
              draining_at = timezone('UTC', clock_timestamp()),
              updated_at = timezone('UTC', clock_timestamp())
          WHERE role = 'partition_planner' AND node_incarnation_id = $1::uuid
            AND action_token = $2::uuid AND state IN ('preparing', 'ready')
            AND lease_expires_at > timezone('UTC', clock_timestamp())
          """,
          [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(token)]
        )

      [] ->
        :ok
    end
  end

  defp request_task_termination_for_partition!(node_id, partition_id, epoch) do
    rows =
      SQL.query!(
        Repo,
        """
        SELECT id FROM public.runtime_task_assignments
        WHERE node_incarnation_id = $1::uuid AND partition_id = $2 AND partition_epoch = $3
          AND state = 'running' AND work_kind <> 'effect'
        ORDER BY inserted_at, id FOR UPDATE
        """,
        [Ecto.UUID.dump!(node_id), partition_id, epoch]
      ).rows

    request_task_rows!(rows)
    length(rows)
  end

  defp request_task_rows!(rows) do
    Enum.each(rows, fn [id] ->
      assignment_id = Ecto.UUID.load!(id)
      set_local!("maraithon.runtime_task_action", assignment_id)

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
        """,
        [id]
      )
    end)
  end

  defp update_node!(session, set_sql, extra_where) do
    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_node_incarnations SET #{set_sql}
        WHERE id = $1::uuid AND activation_epoch = $2::uuid AND #{extra_where}
        RETURNING id, activation_epoch, node_name, revision, state, lease_expires_at,
                  ready_at, draining_at, revoked_at, metadata, inserted_at, updated_at
        """,
        [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
      )

    load!(NodeIncarnation, result, :node_incarnation_lost)
  end

  defp lock_node!(session) do
    case SQL.query!(
           Repo,
           """
           SELECT id, activation_epoch, node_name, revision, state, lease_expires_at,
                  ready_at, draining_at, revoked_at, metadata, inserted_at, updated_at
           FROM public.runtime_node_incarnations
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
         ) do
      %{rows: [_]} = result -> load(NodeIncarnation, result)
      _ -> Repo.rollback(:node_incarnation_lost)
    end
  end

  defp lock_node_for_settlement!(session) do
    case SQL.query!(
           Repo,
           """
           SELECT id, activation_epoch, node_name, revision, state, lease_expires_at,
                  ready_at, draining_at, revoked_at, metadata, inserted_at, updated_at
           FROM public.runtime_node_incarnations
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND state IN ('ready', 'draining')
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
         ) do
      %{rows: [_]} = result -> load(NodeIncarnation, result)
      _ -> Repo.rollback(:node_incarnation_lost)
    end
  end

  defp load(schema, %{columns: columns, rows: [row]}) do
    row = decode_json(columns, row)
    Repo.load(schema, {columns, row})
  end

  defp load!(_schema, %{rows: []}, reason), do: Repo.rollback(reason)
  defp load!(schema, result, _reason), do: load(schema, result)

  defp load_many(schema, %{columns: columns, rows: rows}),
    do: Enum.map(rows, &Repo.load(schema, {columns, decode_json(columns, &1)}))

  defp load_leader!(%{rows: []}), do: Repo.rollback(:leader_authority_lost)

  defp load_leader!(%{columns: columns, rows: [row]}) do
    data = Map.new(Enum.zip(columns, row))

    %{
      activation_epoch: Ecto.UUID.load!(data["activation_epoch"]),
      leader_epoch: data["leader_epoch"],
      node_incarnation_id: Ecto.UUID.load!(data["node_incarnation_id"]),
      action_token: Ecto.UUID.load!(data["action_token"]),
      state: data["state"],
      lease_expires_at: data["lease_expires_at"],
      ready_at: data["ready_at"]
    }
  end

  defp leader_params(leader),
    do: [
      Ecto.UUID.dump!(leader.activation_epoch),
      leader.leader_epoch,
      Ecto.UUID.dump!(leader.node_incarnation_id),
      Ecto.UUID.dump!(leader.action_token)
    ]

  defp decode_json(columns, row) do
    case Enum.find_index(columns, &(&1 == "metadata")) do
      nil ->
        row

      index ->
        case Enum.at(row, index) do
          value when is_binary(value) -> List.replace_at(row, index, Jason.decode!(value))
          _ -> row
        end
    end
  end

  defp lock_deployment_protocol! do
    case SQL.query!(
           Repo,
           """
           SELECT activation_epoch, exact_revision
           FROM public.runtime_coordination_protocols
           WHERE name = 'runtime' AND mode = 'partition_fenced_v1'
           FOR UPDATE
           """,
           []
         ).rows do
      [[activation_epoch, exact_revision]]
      when not is_nil(activation_epoch) and is_binary(exact_revision) ->
        {activation_epoch, exact_revision}

      _ ->
        Repo.rollback(:runtime_coordination_protocol_not_active)
    end
  end

  defp latest_deployment_gate! do
    case SQL.query!(
           Repo,
           """
           SELECT metadata
           FROM public.runtime_node_incarnations
           WHERE node_name = $1 AND metadata ->> 'kind' = 'deployment_gate'
           ORDER BY (metadata ->> 'sequence')::bigint DESC
           LIMIT 1
           """,
           [@deployment_gate_node_name]
         ).rows do
      [[metadata]] when is_map(metadata) -> metadata
      [[metadata]] when is_binary(metadata) -> Jason.decode!(metadata)
      [] -> nil
    end
  end

  defp prove_deployment_handoff_quiescent! do
    [checks] =
      SQL.query!(
        Repo,
        """
        SELECT
          NOT EXISTS (
            SELECT 1 FROM public.runtime_node_incarnations
            WHERE state IN ('joining', 'ready')
              AND lease_expires_at > timezone('UTC', clock_timestamp())
          ),
          NOT EXISTS (
            SELECT 1 FROM public.runtime_leader_authorities
            WHERE state IN ('preparing', 'ready')
              AND lease_expires_at > timezone('UTC', clock_timestamp())
          ),
          NOT EXISTS (
            SELECT 1 FROM public.runtime_partitions
            WHERE state IN ('preparing', 'ready')
              AND (
                lease_expires_at IS NULL OR
                lease_expires_at > timezone('UTC', clock_timestamp())
              )
          ),
          NOT EXISTS (
            SELECT 1 FROM public.runtime_task_assignments
            WHERE state IN ('reserved', 'running', 'termination_requested', 'termination_proven')
          ),
          NOT EXISTS (SELECT 1 FROM public.agent_runtime_leases)
        """,
        []
      ).rows

    if Enum.all?(checks, &(&1 == true)) do
      :ok
    else
      keys =
        ~w(no_live_nodes no_live_leader no_admitting_partitions no_unresolved_tasks no_agent_leases)

      Repo.rollback({:deployment_handoff_not_quiescent, Map.new(Enum.zip(keys, checks))})
    end
  end

  defp require_deployment_generation_ready!(
         target_generation,
         activation_epoch,
         exact_revision
       ) do
    unless SQL.query!(
             Repo,
             """
             WITH protocol AS (
               SELECT partition_count
               FROM public.runtime_coordination_protocols
               WHERE name = 'runtime'
                 AND mode = 'partition_fenced_v1'
                 AND activation_epoch = $2::uuid
                 AND exact_revision = $3
             ),
             live_nodes AS (
               SELECT node.id, node.state, node.ready_at, node.draining_at,
                      node.revoked_at, node.activation_epoch, node.revision, node.metadata
               FROM public.runtime_node_incarnations AS node
               WHERE node.node_name <> $1
                 AND node.state IN ('joining', 'ready')
                 AND node.lease_expires_at > timezone('UTC', clock_timestamp())
             ),
             target_nodes AS (
               SELECT node.id
               FROM live_nodes AS node
               WHERE node.state = 'ready'
                 AND node.ready_at IS NOT NULL
                 AND node.draining_at IS NULL
                 AND node.revoked_at IS NULL
                 AND node.activation_epoch = $2::uuid
                 AND node.revision = $3
                 AND COALESCE(
                   NULLIF(node.metadata ->> 'deployment_generation', ''), 'legacy'
                 ) = $4
             )
             SELECT
               (SELECT count(*) FROM live_nodes) = 1 AND
               (SELECT count(*) FROM target_nodes) = 1 AND
               (SELECT count(*) FROM public.runtime_partitions) =
                 (SELECT partition_count FROM protocol) AND
               NOT EXISTS (
                 SELECT 1
                 FROM public.runtime_partitions AS partition
                 WHERE partition.activation_epoch IS DISTINCT FROM $2::uuid
                   OR partition.state <> 'ready'
                   OR partition.ready_at IS NULL
                   OR partition.draining_at IS NOT NULL
                   OR partition.lease_expires_at IS NULL
                   OR partition.lease_expires_at <= timezone('UTC', clock_timestamp())
                   OR NOT EXISTS (
                     SELECT 1 FROM target_nodes
                     WHERE target_nodes.id = partition.owner_node_incarnation_id
                   )
               )
             """,
             [
               @deployment_gate_node_name,
               activation_epoch,
               exact_revision,
               target_generation
             ]
           ).rows == [[true]] do
      Repo.rollback(:deployment_generation_not_ready)
    end

    :ok
  end

  defp append_deployment_gate!(
         activation_epoch,
         exact_revision,
         latest,
         state,
         target_generation,
         stable_generation,
         image_digest,
         previous_generation \\ nil
       ) do
    sequence = if is_nil(latest), do: 1, else: Map.fetch!(latest, "sequence") + 1
    id = Ecto.UUID.generate()
    previous_generation = previous_generation || stable_generation

    metadata = %{
      "kind" => "deployment_gate",
      "sequence" => sequence,
      "state" => state,
      "target_generation" => target_generation,
      "stable_generation" => stable_generation,
      "previous_generation" => previous_generation,
      "image_digest" => image_digest
    }

    set_local!("maraithon.runtime_deployment_action", id)

    SQL.query!(
      Repo,
      """
      INSERT INTO public.runtime_node_incarnations
        (id, activation_epoch, node_name, revision, state, lease_expires_at,
         revoked_at, metadata, inserted_at, updated_at)
      VALUES
        ($1::uuid, $2::uuid, $3, $4, 'revoked',
         timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
         $5::jsonb, timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
      """,
      [
        Ecto.UUID.dump!(id),
        activation_epoch,
        @deployment_gate_node_name,
        exact_revision,
        metadata
      ]
    )

    metadata
  end

  defp reject_reused_deployment_generation!(target_generation) do
    if SQL.query!(
         Repo,
         """
         SELECT EXISTS (
           SELECT 1
           FROM public.runtime_node_incarnations
           WHERE node_name = $1
             AND metadata ->> 'kind' = 'deployment_gate'
             AND $2 IN (
               metadata ->> 'target_generation',
               metadata ->> 'stable_generation',
               metadata ->> 'previous_generation'
             )
         )
         """,
         [@deployment_gate_node_name, target_generation]
       ).rows == [[true]] do
      Repo.rollback(:deployment_generation_already_used)
    end

    :ok
  end

  defp deployment_gate_predecessor_matches?(sequence, target_generation, image_digest)
       when is_integer(sequence) and sequence > 1 do
    SQL.query!(
      Repo,
      """
      SELECT EXISTS (
        SELECT 1
        FROM public.runtime_node_incarnations
        WHERE node_name = $1
          AND metadata ->> 'kind' = 'deployment_gate'
          AND (metadata ->> 'sequence')::bigint = $2::bigint - 1
          AND metadata ->> 'state' IN ('deploying', 'activating')
          AND metadata ->> 'target_generation' = $3
          AND metadata ->> 'image_digest' = $4
      )
      """,
      [@deployment_gate_node_name, sequence, target_generation, image_digest]
    ).rows == [[true]]
  end

  defp deployment_gate_predecessor_matches?(_sequence, _target_generation, _image_digest),
    do: false

  defp require_deployment_gate_installed! do
    unless SQL.query!(
             Repo,
             "SELECT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = $1)",
             [@deployment_gate_migration]
           ).rows == [[true]] do
      Repo.rollback(:deployment_gate_not_installed)
    end

    :ok
  end

  # Admission and gate transitions hold the same protocol-row lock, so this
  # check cannot go stale before the node write commits. The trigger repeats
  # it as the non-bypassable database authority; this early check merely turns
  # an expected handoff state into a normal fail-closed result for Session.
  defp require_deployment_generation_admitted!(metadata) when is_map(metadata) do
    generation =
      Map.get(metadata, "deployment_generation") ||
        Map.get(metadata, :deployment_generation) ||
        @legacy_deployment_generation

    if valid_deployment_generation(generation) != :ok do
      Repo.rollback(:invalid_deployment_generation)
    end

    case latest_deployment_gate!() do
      nil when generation == @legacy_deployment_generation ->
        :ok

      %{"state" => state, "stable_generation" => ^generation}
      when state in ["stable", "aborted"] ->
        :ok

      %{"state" => "activating", "target_generation" => ^generation} ->
        :ok

      _closed_or_mismatched ->
        Repo.rollback(:deployment_admission_closed)
    end
  end

  defp require_read_committed! do
    unless Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED", [])
    end

    case SQL.query!(Repo, "SELECT current_setting('transaction_isolation')", []).rows do
      [["read committed"]] -> :ok
      _ -> Repo.rollback(:deployment_gate_requires_read_committed)
    end
  end

  defp set_local!(key, value) do
    SQL.query!(Repo, "SELECT set_config($1, $2, true)", [key, to_string(value)])
    :ok
  end

  defp db_future?(%NaiveDateTime{} = expires_at),
    do: NaiveDateTime.compare(expires_at, db_now!()) == :gt

  defp db_future?(%DateTime{} = expires_at),
    do: DateTime.compare(expires_at, DateTime.from_naive!(db_now!(), "Etc/UTC")) == :gt

  defp db_now!,
    do: SQL.query!(Repo, "SELECT timezone('UTC', clock_timestamp())", []).rows |> hd() |> hd()

  defp optional_uuid_dump(nil), do: {:ok, nil}

  defp optional_uuid_dump(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, Ecto.UUID.dump!(uuid)}
      :error -> {:error, :invalid_target_incarnation}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_incarnation_id}
    end
  end

  defp valid_text(value) when is_binary(value) and byte_size(value) in 1..255, do: :ok
  defp valid_text(_), do: {:error, :invalid_incarnation_text}

  defp valid_deployment_generation(value)
       when is_binary(value) and byte_size(value) in 1..63 do
    if Regex.match?(@deployment_generation_pattern, value),
      do: :ok,
      else: {:error, :invalid_deployment_generation}
  end

  defp valid_deployment_generation(_value), do: {:error, :invalid_deployment_generation}

  defp valid_image_digest(value) when is_binary(value) do
    if Regex.match?(@image_digest_pattern, value),
      do: :ok,
      else: {:error, :invalid_image_digest}
  end

  defp valid_image_digest(_value), do: {:error, :invalid_image_digest}

  defp valid_ttl(value) when is_integer(value) and value in 1_000..@max_ttl_ms, do: :ok
  defp valid_ttl(_), do: {:error, :invalid_coordination_ttl}
end
