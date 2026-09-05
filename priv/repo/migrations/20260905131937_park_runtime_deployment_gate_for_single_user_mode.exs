defmodule Maraithon.Repo.Migrations.ParkRuntimeDeploymentGateForSingleUserMode do
  use Ecto.Migration

  def up do
    # A previous staged rollout may have left the deployment-only gate in a
    # pending phase. The fast single-service path deliberately reuses the last
    # admitted generation and lets the ordinary PostgreSQL leases coordinate
    # the brief rolling overlap. Park any pending rollout at that generation
    # once so future deploys do not require controller recovery metadata.
    # Keep the canonical protocol-before-ledger lock order while closing the
    # old controller state so this cannot race a final staged transition.
    execute("LOCK TABLE public.runtime_coordination_protocols IN ACCESS EXCLUSIVE MODE")
    execute("LOCK TABLE public.runtime_node_incarnations IN ACCESS EXCLUSIVE MODE")

    execute("""
    ALTER TABLE public.runtime_node_incarnations
      DISABLE TRIGGER enforce_runtime_node_incarnation_trigger
    """)

    execute("""
    DO $park_deployment_gate$
    DECLARE
      latest_gate jsonb;
      activation_epoch uuid;
      exact_revision text;
      marker_id uuid;
      stable_generation text;
    BEGIN
      SELECT marker.metadata
      INTO latest_gate
      FROM public.runtime_node_incarnations AS marker
      WHERE marker.node_name = '__maraithon_deployment_gate__'
        AND marker.metadata ->> 'kind' = 'deployment_gate'
      ORDER BY (marker.metadata ->> 'sequence')::bigint DESC
      LIMIT 1;

      IF latest_gate ->> 'state' IN ('handoff', 'deploying', 'activating') THEN
        SELECT protocol.activation_epoch, protocol.exact_revision
        INTO STRICT activation_epoch, exact_revision
        FROM public.runtime_coordination_protocols AS protocol
        WHERE protocol.name = 'runtime';

        marker_id := public.gen_random_uuid();
        stable_generation := latest_gate ->> 'stable_generation';

        INSERT INTO public.runtime_node_incarnations
          (id, activation_epoch, node_name, revision, state, lease_expires_at,
           revoked_at, metadata, inserted_at, updated_at)
        VALUES
          (marker_id, activation_epoch, '__maraithon_deployment_gate__', exact_revision,
           'revoked', timezone('UTC', clock_timestamp()),
           timezone('UTC', clock_timestamp()),
           pg_catalog.jsonb_build_object(
             'kind', 'deployment_gate',
             'sequence', (latest_gate ->> 'sequence')::bigint + 1,
             'state', 'aborted',
             'target_generation', latest_gate ->> 'target_generation',
             'stable_generation', stable_generation,
             'previous_generation', stable_generation,
             'image_digest', latest_gate ->> 'image_digest'
           ),
           timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()));
      END IF;
    END;
    $park_deployment_gate$;
    """)

    execute("""
    ALTER TABLE public.runtime_node_incarnations
      ENABLE TRIGGER enforce_runtime_node_incarnation_trigger
    """)
  end

  def down do
    raise "single-user deployment gate parking is intentionally irreversible"
  end
end
