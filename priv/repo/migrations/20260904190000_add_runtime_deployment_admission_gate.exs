defmodule Maraithon.Repo.Migrations.AddRuntimeDeploymentAdmissionGate do
  use Ecto.Migration

  @migration_version 202_609_041_900_00

  def up do
    # The protocol row is the global serialization point. Take it before the
    # node and partition ledgers so this catalog change has the same lock order
    # as admission and cannot race calls through either replaced trigger.
    execute("LOCK TABLE public.runtime_coordination_protocols IN ACCESS EXCLUSIVE MODE")
    execute("LOCK TABLE public.runtime_node_incarnations IN ACCESS EXCLUSIVE MODE")
    execute("LOCK TABLE public.runtime_partitions IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $deployment_gate_preflight$
    DECLARE
      protocol_mode text;
      stored_digest bytea;
      computed_digest bytea;
    BEGIN
      SELECT protocol.mode, protocol.manifest_digest,
             public.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
               'constraints', manifest.constraint_fingerprints,
               'functions', manifest.function_fingerprints,
               'triggers', manifest.trigger_fingerprints,
               'indexes', manifest.index_fingerprints,
               'catalogs', manifest.catalog_fingerprints
             )::text, 'UTF8'), 'sha256')
      INTO STRICT protocol_mode, stored_digest, computed_digest
      FROM public.runtime_coordination_protocols AS protocol
      JOIN public.runtime_coordination_manifests AS manifest
        ON manifest.name = protocol.name
      WHERE protocol.name = 'runtime';

      IF stored_digest IS DISTINCT FROM computed_digest THEN
        RAISE EXCEPTION 'Runtime protocol manifest digest is stale before deployment gate install'
          USING ERRCODE = 'check_violation';
      END IF;

      IF protocol_mode = 'partition_fenced_v1' AND
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Active runtime catalog is not exact before deployment gate install'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.runtime_node_incarnations
        WHERE node_name = '__maraithon_deployment_gate__'
      ) THEN
        RAISE EXCEPTION 'Reserved deployment gate identity is already in use'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $deployment_gate_preflight$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_node_incarnation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      requested_id uuid;
      requested_deployment_id uuid;
      leader_authorized boolean;
      unresolved_tasks bigint;
      live_leases bigint;
      owned_partitions bigint;
      protocol_activation_epoch uuid;
      protocol_exact_revision text;
      protocol_partition_count integer;
      latest_gate jsonb;
      node_generation text;
      admission_write boolean := false;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime node incarnation history is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND
         (OLD.node_name = '__maraithon_deployment_gate__' OR
          NEW.node_name = '__maraithon_deployment_gate__') THEN
        RAISE EXCEPTION 'runtime deployment gate history is append-only'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'INSERT' AND NEW.node_name = '__maraithon_deployment_gate__' THEN
        IF current_user IS DISTINCT FROM 'maraithon_migrator' THEN
          RAISE EXCEPTION 'runtime deployment gate mutation requires migrator role'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        IF current_setting('transaction_isolation') IS DISTINCT FROM 'read committed' THEN
          RAISE EXCEPTION 'runtime deployment gate requires READ COMMITTED isolation'
            USING ERRCODE = 'check_violation';
        END IF;

        BEGIN
          requested_deployment_id :=
            nullif(current_setting('maraithon.runtime_deployment_action', true), '')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
          requested_deployment_id := NULL;
        END;

        IF requested_deployment_id IS DISTINCT FROM NEW.id THEN
          RAISE EXCEPTION 'runtime deployment gate requires its exact action token'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT protocol.activation_epoch, protocol.exact_revision, protocol.partition_count
        INTO STRICT protocol_activation_epoch, protocol_exact_revision,
                    protocol_partition_count
        FROM public.runtime_coordination_protocols AS protocol
        WHERE protocol.name = 'runtime'
          AND protocol.mode = 'partition_fenced_v1'
        FOR UPDATE;

        IF NEW.activation_epoch IS DISTINCT FROM protocol_activation_epoch OR
           NEW.revision IS DISTINCT FROM protocol_exact_revision OR
           NEW.state IS DISTINCT FROM 'revoked' OR
           NEW.ready_at IS NOT NULL OR NEW.draining_at IS NOT NULL OR
           NEW.revoked_at IS NULL OR
           NEW.lease_expires_at > timezone('UTC', clock_timestamp()) OR
           pg_catalog.jsonb_typeof(NEW.metadata) IS DISTINCT FROM 'object' OR
           (SELECT count(*) FROM pg_catalog.jsonb_object_keys(NEW.metadata)) <> 7 OR
           NOT (NEW.metadata ?& ARRAY[
             'kind', 'sequence', 'state', 'target_generation',
             'stable_generation', 'previous_generation', 'image_digest'
           ]) OR
           NEW.metadata ->> 'kind' IS DISTINCT FROM 'deployment_gate' OR
           pg_catalog.jsonb_typeof(NEW.metadata -> 'sequence') IS DISTINCT FROM 'number' OR
           (NEW.metadata ->> 'sequence') !~ '^[1-9][0-9]*$' OR
           pg_catalog.jsonb_typeof(NEW.metadata -> 'state') IS DISTINCT FROM 'string' OR
           NEW.metadata ->> 'state' NOT IN (
             'handoff', 'deploying', 'activating', 'stable', 'aborted'
           ) OR
           pg_catalog.jsonb_typeof(NEW.metadata -> 'target_generation')
             IS DISTINCT FROM 'string' OR
           pg_catalog.jsonb_typeof(NEW.metadata -> 'stable_generation')
             IS DISTINCT FROM 'string' OR
           pg_catalog.jsonb_typeof(NEW.metadata -> 'previous_generation')
             IS DISTINCT FROM 'string' OR
           pg_catalog.jsonb_typeof(NEW.metadata -> 'image_digest')
             IS DISTINCT FROM 'string' OR
           NEW.metadata ->> 'target_generation'
             !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' OR
           NEW.metadata ->> 'stable_generation'
             !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' OR
           NEW.metadata ->> 'previous_generation'
             !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' OR
           NEW.metadata ->> 'image_digest' !~ '^sha256:[0-9a-f]{64}$' THEN
          RAISE EXCEPTION 'runtime deployment gate marker is malformed'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT marker.metadata
        INTO latest_gate
        FROM public.runtime_node_incarnations AS marker
        WHERE marker.node_name = '__maraithon_deployment_gate__'
          AND marker.metadata ->> 'kind' = 'deployment_gate'
        ORDER BY (marker.metadata ->> 'sequence')::bigint DESC
        LIMIT 1;

        IF latest_gate IS NULL THEN
          IF (NEW.metadata ->> 'sequence')::bigint <> 1 OR
             NEW.metadata ->> 'state' <> 'handoff' OR
             NEW.metadata ->> 'stable_generation' <> 'legacy' OR
             NEW.metadata ->> 'previous_generation' <> 'legacy' OR
             NEW.metadata ->> 'target_generation' = 'legacy' THEN
            RAISE EXCEPTION 'first runtime deployment gate transition is invalid'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSE
          IF (NEW.metadata ->> 'sequence')::bigint <>
               (latest_gate ->> 'sequence')::bigint + 1 THEN
            RAISE EXCEPTION 'runtime deployment gate sequence is not monotone'
              USING ERRCODE = 'check_violation';
          END IF;

          IF latest_gate ->> 'state' IN ('stable', 'aborted') THEN
            IF NEW.metadata ->> 'state' <> 'handoff' OR
               NEW.metadata ->> 'stable_generation' IS DISTINCT FROM
                 latest_gate ->> 'stable_generation' OR
               NEW.metadata ->> 'previous_generation' IS DISTINCT FROM
                 latest_gate ->> 'stable_generation' OR
               NEW.metadata ->> 'target_generation' =
                 latest_gate ->> 'stable_generation' OR
               EXISTS (
                 SELECT 1
                 FROM public.runtime_node_incarnations AS used_marker
                 WHERE used_marker.node_name = '__maraithon_deployment_gate__'
                   AND used_marker.metadata ->> 'kind' = 'deployment_gate'
                   AND NEW.metadata ->> 'target_generation' IN (
                     used_marker.metadata ->> 'target_generation',
                     used_marker.metadata ->> 'stable_generation',
                     used_marker.metadata ->> 'previous_generation'
                   )
               ) THEN
              RAISE EXCEPTION 'runtime deployment generation is stale or reused'
                USING ERRCODE = 'check_violation';
            END IF;
          ELSIF latest_gate ->> 'state' = 'handoff' THEN
            IF NEW.metadata ->> 'image_digest' IS DISTINCT FROM
                 latest_gate ->> 'image_digest' OR
               NOT (
                 (NEW.metadata ->> 'state' = 'deploying' AND
                  NEW.metadata ->> 'target_generation' IS NOT DISTINCT FROM
                    latest_gate ->> 'target_generation' AND
                  NEW.metadata ->> 'stable_generation' IS NOT DISTINCT FROM
                    latest_gate ->> 'stable_generation' AND
                  NEW.metadata ->> 'previous_generation' IS NOT DISTINCT FROM
                    latest_gate ->> 'previous_generation') OR
                 (NEW.metadata ->> 'state' = 'aborted' AND
                  NEW.metadata ->> 'target_generation' IS NOT DISTINCT FROM
                    latest_gate ->> 'target_generation' AND
                  NEW.metadata ->> 'stable_generation' IS NOT DISTINCT FROM
                    latest_gate ->> 'stable_generation' AND
                  NEW.metadata ->> 'previous_generation' IS NOT DISTINCT FROM
                    latest_gate ->> 'previous_generation')
               ) THEN
              RAISE EXCEPTION 'runtime deployment handoff transition is invalid'
                USING ERRCODE = 'check_violation';
            END IF;

            IF NEW.metadata ->> 'state' = 'deploying' AND (
                 EXISTS (
                   SELECT 1 FROM public.runtime_node_incarnations
                   WHERE state IN ('joining', 'ready')
                     AND lease_expires_at > timezone('UTC', clock_timestamp())
                 ) OR
                 EXISTS (
                   SELECT 1 FROM public.runtime_leader_authorities
                   WHERE state IN ('preparing', 'ready')
                     AND lease_expires_at > timezone('UTC', clock_timestamp())
                 ) OR
                 EXISTS (
                   SELECT 1 FROM public.runtime_partitions
                   WHERE state IN ('preparing', 'ready')
                     AND (
                       lease_expires_at IS NULL OR
                       lease_expires_at > timezone('UTC', clock_timestamp())
                     )
                 ) OR
                 EXISTS (
                   SELECT 1 FROM public.runtime_task_assignments
                   WHERE state IN (
                     'reserved', 'running', 'termination_requested', 'termination_proven'
                   )
                 ) OR
                 EXISTS (SELECT 1 FROM public.agent_runtime_leases)
               ) THEN
              RAISE EXCEPTION 'runtime deployment handoff is not quiescent'
                USING ERRCODE = 'check_violation';
            END IF;
          ELSIF latest_gate ->> 'state' IN ('deploying', 'activating') THEN
            IF NEW.metadata ->> 'state' = 'activating' THEN
              IF latest_gate ->> 'state' <> 'deploying' OR
                 NEW.metadata ->> 'image_digest' IS DISTINCT FROM
                   latest_gate ->> 'image_digest' OR
                 NEW.metadata ->> 'target_generation' IS DISTINCT FROM
                   latest_gate ->> 'target_generation' OR
                 NEW.metadata ->> 'stable_generation' IS DISTINCT FROM
                   latest_gate ->> 'stable_generation' OR
                 NEW.metadata ->> 'previous_generation' IS DISTINCT FROM
                   latest_gate ->> 'previous_generation' THEN
                RAISE EXCEPTION 'runtime deployment activation transition is invalid'
                  USING ERRCODE = 'check_violation';
              END IF;
            ELSIF NEW.metadata ->> 'state' = 'stable' THEN
              IF latest_gate ->> 'state' <> 'activating' OR
                 NEW.metadata ->> 'image_digest' IS DISTINCT FROM
                   latest_gate ->> 'image_digest' OR
                 NEW.metadata ->> 'target_generation' IS DISTINCT FROM
                   latest_gate ->> 'target_generation' OR
                 NEW.metadata ->> 'stable_generation' IS DISTINCT FROM
                   latest_gate ->> 'target_generation' OR
                 NEW.metadata ->> 'previous_generation' IS DISTINCT FROM
                   latest_gate ->> 'stable_generation' THEN
                RAISE EXCEPTION 'runtime deployment completion transition is invalid'
                  USING ERRCODE = 'check_violation';
              END IF;

              WITH live_nodes AS (
                SELECT node.id, node.state, node.ready_at, node.draining_at,
                       node.revoked_at, node.activation_epoch, node.revision, node.metadata
                FROM public.runtime_node_incarnations AS node
                WHERE node.node_name <> '__maraithon_deployment_gate__'
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
                  AND node.activation_epoch = protocol_activation_epoch
                  AND node.revision = protocol_exact_revision
                  AND COALESCE(
                    NULLIF(node.metadata ->> 'deployment_generation', ''), 'legacy'
                  ) = latest_gate ->> 'target_generation'
              )
              SELECT
                (SELECT count(*) FROM live_nodes) = 1 AND
                (SELECT count(*) FROM target_nodes) = 1 AND
                (SELECT count(*) FROM public.runtime_partitions) =
                  protocol_partition_count AND
                NOT EXISTS (
                  SELECT 1
                  FROM public.runtime_partitions AS partition
                  WHERE partition.activation_epoch IS DISTINCT FROM
                          protocol_activation_epoch
                    OR partition.state <> 'ready'
                    OR partition.ready_at IS NULL
                    OR partition.draining_at IS NOT NULL
                    OR partition.lease_expires_at IS NULL
                    OR partition.lease_expires_at <=
                         timezone('UTC', clock_timestamp())
                    OR NOT EXISTS (
                      SELECT 1 FROM target_nodes
                      WHERE target_nodes.id = partition.owner_node_incarnation_id
                    )
                )
              INTO admission_write;

              IF admission_write IS DISTINCT FROM true THEN
                RAISE EXCEPTION 'runtime deployment target is not ready'
                  USING ERRCODE = 'check_violation';
              END IF;
            ELSIF NEW.metadata ->> 'state' = 'deploying' THEN
              IF NEW.metadata ->> 'target_generation' = 'legacy' OR
                 NEW.metadata ->> 'target_generation' IS NOT DISTINCT FROM
                   latest_gate ->> 'target_generation' OR
                 NEW.metadata ->> 'stable_generation' IS DISTINCT FROM
                   latest_gate ->> 'stable_generation' OR
                 NEW.metadata ->> 'previous_generation' IS DISTINCT FROM
                   latest_gate ->> 'stable_generation' OR
                 EXISTS (
                   SELECT 1
                   FROM public.runtime_node_incarnations AS used_marker
                   WHERE used_marker.node_name = '__maraithon_deployment_gate__'
                     AND used_marker.metadata ->> 'kind' = 'deployment_gate'
                     AND NEW.metadata ->> 'target_generation' IN (
                       used_marker.metadata ->> 'target_generation',
                       used_marker.metadata ->> 'stable_generation',
                       used_marker.metadata ->> 'previous_generation'
                     )
                 ) THEN
                RAISE EXCEPTION 'runtime deployment retarget is stale or reused'
                  USING ERRCODE = 'check_violation';
              END IF;

              IF EXISTS (
                   SELECT 1 FROM public.runtime_node_incarnations
                   WHERE state IN ('joining', 'ready')
                     AND lease_expires_at > timezone('UTC', clock_timestamp())
                 ) OR
                 EXISTS (
                   SELECT 1 FROM public.runtime_leader_authorities
                   WHERE state IN ('preparing', 'ready')
                     AND lease_expires_at > timezone('UTC', clock_timestamp())
                 ) OR
                 EXISTS (
                   SELECT 1 FROM public.runtime_partitions
                   WHERE state IN ('preparing', 'ready')
                     AND (
                       lease_expires_at IS NULL OR
                       lease_expires_at > timezone('UTC', clock_timestamp())
                     )
                 ) OR
                 EXISTS (
                   SELECT 1 FROM public.runtime_task_assignments
                   WHERE state IN (
                     'reserved', 'running', 'termination_requested', 'termination_proven'
                   )
                 ) OR
                 EXISTS (SELECT 1 FROM public.agent_runtime_leases) THEN
                RAISE EXCEPTION 'runtime deployment retarget is not quiescent'
                  USING ERRCODE = 'check_violation';
              END IF;
            ELSE
              RAISE EXCEPTION 'runtime deployment transition after proof is invalid'
                USING ERRCODE = 'check_violation';
            END IF;
          ELSE
            RAISE EXCEPTION 'runtime deployment gate has an invalid durable state'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        RETURN NEW;
      END IF;

      IF current_user IS DISTINCT FROM 'maraithon_runtime' THEN
        RAISE EXCEPTION 'runtime coordination mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF NEW.node_name = '__maraithon_deployment_gate__' THEN
        RAISE EXCEPTION 'reserved runtime deployment gate identity cannot join'
          USING ERRCODE = 'check_violation';
      END IF;

      BEGIN
        requested_id := nullif(current_setting('maraithon.runtime_node_action', true), '')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        requested_id := NULL;
      END;

      SELECT EXISTS (
        SELECT 1 FROM public.runtime_leader_authorities AS leader
        WHERE leader.role = 'partition_planner' AND leader.state = 'ready'
          AND leader.action_token::text =
                current_setting('maraithon.runtime_leader_action', true)
          AND leader.lease_expires_at > timezone('UTC', clock_timestamp())
      ) INTO leader_authorized;

      IF requested_id IS DISTINCT FROM NEW.id AND NOT leader_authorized THEN
        RAISE EXCEPTION 'runtime node mutation requires its exact incarnation token'
          USING ERRCODE = 'check_violation';
      END IF;

      admission_write := TG_OP = 'INSERT';
      IF TG_OP = 'UPDATE' THEN
        admission_write := OLD.state <> 'ready' AND NEW.state = 'ready';
      END IF;

      IF admission_write THEN
        IF current_setting('transaction_isolation') IS DISTINCT FROM 'read committed' THEN
          RAISE EXCEPTION 'runtime node admission requires READ COMMITTED isolation'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM public.schema_migrations
          WHERE version = #{@migration_version}
        ) THEN
          RAISE EXCEPTION 'runtime deployment gate migration is not installed'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT protocol.activation_epoch, protocol.exact_revision
        INTO STRICT protocol_activation_epoch, protocol_exact_revision
        FROM public.runtime_coordination_protocols AS protocol
        WHERE protocol.name = 'runtime'
          AND protocol.mode = 'partition_fenced_v1'
        FOR SHARE;

        IF NEW.activation_epoch IS DISTINCT FROM protocol_activation_epoch OR
           NEW.revision IS DISTINCT FROM protocol_exact_revision THEN
          RAISE EXCEPTION 'runtime node cannot join an inactive protocol'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.metadata ? 'deployment_generation' AND
           pg_catalog.jsonb_typeof(NEW.metadata -> 'deployment_generation')
             IS DISTINCT FROM 'string' THEN
          RAISE EXCEPTION 'runtime node deployment generation is malformed'
            USING ERRCODE = 'check_violation';
        END IF;

        node_generation := COALESCE(
          NULLIF(NEW.metadata ->> 'deployment_generation', ''), 'legacy'
        );

        IF node_generation !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' THEN
          RAISE EXCEPTION 'runtime node deployment generation is malformed'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT marker.metadata
        INTO latest_gate
        FROM public.runtime_node_incarnations AS marker
        WHERE marker.node_name = '__maraithon_deployment_gate__'
          AND marker.metadata ->> 'kind' = 'deployment_gate'
        ORDER BY (marker.metadata ->> 'sequence')::bigint DESC
        LIMIT 1;

        IF latest_gate IS NULL THEN
          IF node_generation <> 'legacy' THEN
            RAISE EXCEPTION 'runtime node generation is not the implicit legacy generation'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT (
          (latest_gate ->> 'state' = 'activating' AND
           node_generation IS NOT DISTINCT FROM latest_gate ->> 'target_generation') OR
          (latest_gate ->> 'state' IN ('stable', 'aborted') AND
           node_generation IS NOT DISTINCT FROM latest_gate ->> 'stable_generation')
        ) THEN
          RAISE EXCEPTION 'runtime node admission is closed for this deployment generation'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_OP = 'INSERT' THEN
        RAISE EXCEPTION 'runtime node cannot join an inactive protocol'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF NEW.id IS DISTINCT FROM OLD.id OR
           NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
           NEW.node_name IS DISTINCT FROM OLD.node_name OR
           NEW.revision IS DISTINCT FROM OLD.revision OR
           NEW.metadata IS DISTINCT FROM OLD.metadata OR
           NEW.lease_expires_at < OLD.lease_expires_at OR
           (OLD.state = 'revoked' AND NEW IS DISTINCT FROM OLD) OR
           (OLD.state = 'draining' AND NEW.state NOT IN ('draining', 'revoked')) OR
           (OLD.state = 'ready' AND NEW.state NOT IN ('ready', 'draining', 'revoked')) OR
           (OLD.state = 'joining' AND NEW.state NOT IN ('joining', 'ready', 'draining', 'revoked')) THEN
          RAISE EXCEPTION 'stale or non-monotone runtime node incarnation mutation'
            USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.lease_expires_at <= timezone('UTC', clock_timestamp()) AND
           NEW.lease_expires_at > OLD.lease_expires_at THEN
          RAISE EXCEPTION 'expired runtime node incarnation cannot be revived'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.state = 'revoked' AND OLD.state <> 'revoked' THEN
          SELECT count(*) INTO unresolved_tasks
          FROM public.runtime_task_assignments
          WHERE node_incarnation_id = OLD.id
            AND state IN ('reserved', 'running', 'termination_requested', 'termination_proven');
          SELECT count(*) INTO live_leases
          FROM public.agent_runtime_leases
          WHERE coordination_node_incarnation_id = OLD.id;
          SELECT count(*) INTO owned_partitions
          FROM public.runtime_partitions
          WHERE owner_node_incarnation_id = OLD.id;
          IF unresolved_tasks <> 0 OR live_leases <> 0 OR owned_partitions <> 0 THEN
            RAISE EXCEPTION 'node revocation requires exact task proof, Agent lease drain, and partition release'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    # Expired `preparing` partitions are now recoverable after a deployment
    # handoff. Keep the database authority equivalent to the Authority path:
    # preparing -> draining/blocked is a topology fence and therefore requires
    # the same live leader-or-owner proof as ready -> draining/blocked.
    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_partition_authority()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      leader_valid boolean;
      node_valid boolean;
      effect_scope_drained boolean;
      unresolved_tasks bigint;
      live_agents bigint;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' THEN
        RAISE EXCEPTION 'runtime coordination mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime partition authority is irreversible'
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.partition_id IS DISTINCT FROM OLD.partition_id OR
         NEW.ownership_epoch < OLD.ownership_epoch OR NEW.fair_sequence < OLD.fair_sequence THEN
        RAISE EXCEPTION 'runtime partition epochs are monotone'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT EXISTS (
        SELECT 1 FROM public.runtime_leader_authorities AS leader
        WHERE leader.role = 'partition_planner' AND leader.state = 'ready'
          AND leader.action_token::text = current_setting('maraithon.runtime_leader_action', true)
          AND leader.lease_expires_at > timezone('UTC', clock_timestamp())
      ) INTO leader_valid;

      SELECT EXISTS (
        SELECT 1 FROM public.runtime_node_incarnations AS node
        WHERE node.id = COALESCE(NEW.owner_node_incarnation_id, OLD.owner_node_incarnation_id)
          AND node.state IN ('ready', 'draining')
          AND node.id::text = current_setting('maraithon.runtime_node_action', true)
          AND node.lease_expires_at > timezone('UTC', clock_timestamp())
      ) INTO node_valid;

      IF NEW.effects_drained_epoch IS DISTINCT FROM OLD.effects_drained_epoch THEN
        IF OLD.effects_drained_epoch IS NULL AND
           NEW.effects_drained_epoch = OLD.ownership_epoch AND
           NEW.ownership_epoch = OLD.ownership_epoch AND
           OLD.state IN ('draining', 'blocked') AND
           NEW.state IN ('draining', 'blocked') THEN
          IF current_setting('transaction_isolation') IS DISTINCT FROM 'read committed' THEN
            RAISE EXCEPTION 'partition Effect drain marker requires read committed isolation'
              USING ERRCODE = 'check_violation';
          END IF;

          IF NOT (leader_valid OR node_valid) THEN
            RAISE EXCEPTION 'partition Effect drain marker requires exact leader or owner incarnation'
              USING ERRCODE = 'check_violation';
          END IF;

          -- This is deliberately a plain MVCC observation with no Effect row
          -- locks. The already-established topology fence prevents new admission;
          -- taking Effect locks here would invert the canonical Effect-first
          -- settlement order. Cancelling Effects are guarded by the unresolved
          -- assignment gate during release.
          SELECT NOT EXISTS (
            SELECT 1
            FROM public.effects AS effect
            WHERE effect.coordination_activation_epoch = OLD.activation_epoch
              AND effect.coordination_partition_id = OLD.partition_id
              AND effect.coordination_partition_epoch = OLD.ownership_epoch
              AND effect.coordination_node_incarnation_id = OLD.owner_node_incarnation_id
              AND effect.status IN ('pending', 'claimed', 'executing')
          ) INTO effect_scope_drained;

          IF NOT effect_scope_drained THEN
            RAISE EXCEPTION 'partition Effect drain marker requires an empty active Effect scope'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF OLD.state IN ('draining', 'blocked') AND
              NEW.state = 'unassigned' AND
              OLD.effects_drained_epoch = OLD.ownership_epoch AND
              NEW.effects_drained_epoch IS NULL AND
              NEW.ownership_epoch = OLD.ownership_epoch THEN
          NULL;
        ELSE
          RAISE EXCEPTION 'partition Effect drain marker is epoch-bound and monotone'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      IF OLD.state = 'unassigned' AND NEW.state = 'preparing' THEN
        IF NOT leader_valid OR NEW.ownership_epoch <> OLD.ownership_epoch + 1 THEN
          RAISE EXCEPTION 'partition assignment requires exact ready leader epoch'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF OLD.state = 'preparing' AND NEW.state = 'ready' THEN
        IF NOT node_valid OR NEW.ownership_epoch <> OLD.ownership_epoch THEN
          RAISE EXCEPTION 'partition readiness must be published by its target incarnation last'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF OLD.state IN ('preparing', 'ready') AND NEW.state IN ('draining', 'blocked') THEN
        IF NOT (leader_valid OR node_valid) THEN
          RAISE EXCEPTION 'partition drain requires exact leader or owner incarnation'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF OLD.state IN ('draining', 'blocked') AND NEW.state = 'unassigned' THEN
        IF NOT leader_valid THEN
          RAISE EXCEPTION 'partition release requires exact ready leader'
            USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.effects_drained_epoch IS DISTINCT FROM OLD.ownership_epoch OR
           NEW.effects_drained_epoch IS NOT NULL THEN
          RAISE EXCEPTION 'partition release requires the current Effect drain marker to be cleared'
            USING ERRCODE = 'check_violation';
        END IF;
        SELECT count(*) INTO unresolved_tasks
        FROM public.runtime_task_assignments AS assignment
        WHERE assignment.partition_id = OLD.partition_id
          AND assignment.partition_epoch = OLD.ownership_epoch
          AND assignment.state IN ('reserved', 'running', 'termination_requested', 'termination_proven');
        SELECT count(*) INTO live_agents
        FROM public.agent_runtime_leases AS lease
        WHERE lease.coordination_partition_id = OLD.partition_id
          AND lease.coordination_partition_epoch = OLD.ownership_epoch;
        IF unresolved_tasks <> 0 OR live_agents <> 0 THEN
          RAISE EXCEPTION 'partition cannot move before exact task proof and Agent lease drain'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF NEW.owner_node_incarnation_id IS DISTINCT FROM OLD.owner_node_incarnation_id OR
            NEW.ownership_epoch IS DISTINCT FROM OLD.ownership_epoch OR
            NEW.transition_id IS DISTINCT FROM OLD.transition_id OR
            NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch THEN
        RAISE EXCEPTION 'partition ownership can change only through a serialized transition'
          USING ERRCODE = 'check_violation';
      ELSIF NEW.lease_expires_at > OLD.lease_expires_at AND NOT node_valid THEN
        RAISE EXCEPTION 'partition renewal requires exact owner incarnation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.lease_expires_at IS NOT NULL AND
         OLD.lease_expires_at <= timezone('UTC', clock_timestamp()) AND
         NEW.lease_expires_at > OLD.lease_expires_at AND NEW.state <> 'unassigned' THEN
        RAISE EXCEPTION 'expired partition epoch cannot be revived'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_manifests
      DISABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger
    """)

    execute("""
    UPDATE public.runtime_coordination_manifests AS manifest
    SET function_fingerprints = pg_catalog.jsonb_set(
          pg_catalog.jsonb_set(
            manifest.function_fingerprints,
            '{enforce_runtime_node_incarnation}',
            pg_catalog.to_jsonb(pg_catalog.encode(public.digest(pg_catalog.convert_to(
              pg_catalog.jsonb_build_object(
                'definition', pg_catalog.pg_get_functiondef(node_function.oid),
                'owner', node_owner.rolname,
                'acl', node_function.proacl
              )::text, 'UTF8'), 'sha256'), 'hex')),
            false
          ),
          '{enforce_runtime_partition_authority}',
          pg_catalog.to_jsonb(pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_functiondef(partition_function.oid),
              'owner', partition_owner.rolname,
              'acl', partition_function.proacl
            )::text, 'UTF8'), 'sha256'), 'hex')),
          false
        ),
        updated_at = timezone('UTC', clock_timestamp())
    FROM pg_catalog.pg_proc AS node_function
    JOIN pg_catalog.pg_roles AS node_owner ON node_owner.oid = node_function.proowner
    CROSS JOIN pg_catalog.pg_proc AS partition_function
    JOIN pg_catalog.pg_roles AS partition_owner
      ON partition_owner.oid = partition_function.proowner
    WHERE manifest.name = 'runtime'
      AND node_function.oid =
            'public.enforce_runtime_node_incarnation()'::regprocedure
      AND partition_function.oid =
            'public.enforce_runtime_partition_authority()'::regprocedure
      AND manifest.function_fingerprints ? 'enforce_runtime_node_incarnation'
      AND manifest.function_fingerprints ? 'enforce_runtime_partition_authority'
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_manifests
      ENABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_protocols
      DISABLE TRIGGER enforce_runtime_coordination_protocol_trigger
    """)

    execute("""
    UPDATE public.runtime_coordination_protocols AS protocol
    SET manifest_digest = public.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
          'constraints', manifest.constraint_fingerprints,
          'functions', manifest.function_fingerprints,
          'triggers', manifest.trigger_fingerprints,
          'indexes', manifest.index_fingerprints,
          'catalogs', manifest.catalog_fingerprints
        )::text, 'UTF8'), 'sha256'),
        updated_at = timezone('UTC', clock_timestamp())
    FROM public.runtime_coordination_manifests AS manifest
    WHERE protocol.name = 'runtime' AND manifest.name = protocol.name
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_protocols
      ENABLE TRIGGER enforce_runtime_coordination_protocol_trigger
    """)

    execute("""
    DO $deployment_gate_verify$
    DECLARE
      protocol_mode text;
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc AS function_row
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
        JOIN public.runtime_coordination_manifests AS manifest
          ON manifest.name = 'runtime'
        WHERE function_row.oid =
                'public.enforce_runtime_node_incarnation()'::regprocedure
          AND manifest.function_fingerprints ->> 'enforce_runtime_node_incarnation' =
              pg_catalog.encode(public.digest(pg_catalog.convert_to(
                pg_catalog.jsonb_build_object(
                  'definition', pg_catalog.pg_get_functiondef(function_row.oid),
                  'owner', owner_row.rolname,
                  'acl', function_row.proacl
                )::text, 'UTF8'), 'sha256'), 'hex')
      ) THEN
        RAISE EXCEPTION 'Runtime deployment gate function is not attested'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc AS function_row
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
        JOIN public.runtime_coordination_manifests AS manifest
          ON manifest.name = 'runtime'
        WHERE function_row.oid =
                'public.enforce_runtime_partition_authority()'::regprocedure
          AND manifest.function_fingerprints ->> 'enforce_runtime_partition_authority' =
              pg_catalog.encode(public.digest(pg_catalog.convert_to(
                pg_catalog.jsonb_build_object(
                  'definition', pg_catalog.pg_get_functiondef(function_row.oid),
                  'owner', owner_row.rolname,
                  'acl', function_row.proacl
                )::text, 'UTF8'), 'sha256'), 'hex')
      ) THEN
        RAISE EXCEPTION 'Runtime partition authority function is not attested'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM public.runtime_coordination_protocols AS protocol
        JOIN public.runtime_coordination_manifests AS manifest
          ON manifest.name = protocol.name
        WHERE protocol.name = 'runtime'
          AND protocol.manifest_digest = public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'constraints', manifest.constraint_fingerprints,
              'functions', manifest.function_fingerprints,
              'triggers', manifest.trigger_fingerprints,
              'indexes', manifest.index_fingerprints,
              'catalogs', manifest.catalog_fingerprints
            )::text, 'UTF8'), 'sha256')
      ) THEN
        RAISE EXCEPTION 'Runtime protocol digest does not attest deployment gate'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT mode INTO STRICT protocol_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime';

      IF protocol_mode = 'partition_fenced_v1' AND
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Active runtime catalog is not exact after deployment gate install'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $deployment_gate_verify$;
    """)
  end

  def down do
    raise "runtime deployment admission history cannot be safely removed"
  end
end
