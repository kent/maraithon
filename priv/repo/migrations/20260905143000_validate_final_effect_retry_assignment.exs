defmodule Maraithon.Repo.Migrations.ValidateFinalEffectRetryAssignment do
  use Ecto.Migration

  def up do
    old_fragment =
      "IF TG_RELID = 'public.runtime_task_assignments'::regclass THEN\n" <>
        "      IF NEW.state NOT IN ('settled', 'outcome_ambiguous') THEN\n" <>
        "        RAISE EXCEPTION 'active Effect assignment must be linked by its Effect'\n" <>
        "          USING ERRCODE = 'check_violation';\n" <>
        "      END IF;\n" <>
        "    END IF;"

    new_fragment =
      "IF TG_RELID = 'public.runtime_task_assignments'::regclass THEN\n" <>
        "      SELECT * INTO assignment_row\n" <>
        "      FROM public.runtime_task_assignments\n" <>
        "      WHERE id = NEW.id;\n" <>
        "\n" <>
        "      IF NOT FOUND OR assignment_row.state NOT IN ('settled', 'outcome_ambiguous') THEN\n" <>
        "        RAISE EXCEPTION 'active Effect assignment must be linked by its Effect'\n" <>
        "          USING ERRCODE = 'check_violation';\n" <>
        "      END IF;\n" <>
        "    END IF;"

    execute("""
    DO $effect_retry_pair_guard$
    DECLARE
      definition text;
      old_fragment text := #{quote_literal(old_fragment)};
      new_fragment text := #{quote_literal(new_fragment)};
    BEGIN
      SELECT pg_catalog.pg_get_functiondef(
        'public.enforce_effect_assignment_final_pair()'::regprocedure
      ) INTO STRICT definition;

      IF pg_catalog.strpos(definition, new_fragment) > 0 THEN
        RETURN;
      END IF;

      IF pg_catalog.strpos(definition, old_fragment) = 0 OR
         pg_catalog.strpos(
           pg_catalog.replace(definition, old_fragment, ''), old_fragment
         ) > 0 THEN
        RAISE EXCEPTION 'Effect assignment final-pair guard does not match the expected definition'
          USING ERRCODE = 'check_violation';
      END IF;

      EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
    END;
    $effect_retry_pair_guard$;
    """)

    refresh_runtime_manifest()
    refresh_privacy_manifest()
    refresh_durable_payload_manifest()
    verify_catalogs()
  end

  def down do
    raise "final Effect retry assignment validation cannot be safely narrowed after use"
  end

  defp refresh_runtime_manifest do
    execute("""
    ALTER TABLE public.runtime_coordination_manifests
      DISABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger
    """)

    execute("""
    UPDATE public.runtime_coordination_manifests AS manifest
    SET function_fingerprints = pg_catalog.jsonb_set(
          manifest.function_fingerprints,
          '{enforce_effect_assignment_final_pair}',
          pg_catalog.to_jsonb(pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_functiondef(function_row.oid),
              'owner', owner_row.rolname,
              'acl', function_row.proacl
            )::text, 'UTF8'), 'sha256'), 'hex')),
          false
        ),
        updated_at = timezone('UTC', clock_timestamp())
    FROM pg_catalog.pg_proc AS function_row
    JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
    WHERE manifest.name = 'runtime'
      AND function_row.oid =
            'public.enforce_effect_assignment_final_pair()'::regprocedure
      AND manifest.function_fingerprints ? 'enforce_effect_assignment_final_pair'
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
  end

  defp refresh_privacy_manifest do
    execute("""
    ALTER TABLE public.privacy_protocol_manifests
      DISABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger
    """)

    execute("""
    DO $privacy_manifest_refresh$
    DECLARE
      function_key text;
      function_fingerprint text;
      functions jsonb;
      triggers jsonb;
      catalogs jsonb;
      digest_value bytea;
    BEGIN
      SELECT
        function_row.oid::regprocedure::text,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_functiondef(function_row.oid),
            'owner', owner_row.rolname,
            'acl', function_row.proacl
          )::text, 'UTF8'), 'sha256'), 'hex')
      INTO STRICT function_key, function_fingerprint
      FROM pg_catalog.pg_proc AS function_row
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
      WHERE function_row.oid =
              'public.enforce_effect_assignment_final_pair()'::regprocedure;

      SELECT
        pg_catalog.jsonb_set(
          manifest.function_fingerprints,
          ARRAY[function_key],
          pg_catalog.to_jsonb(function_fingerprint),
          false
        ),
        manifest.trigger_fingerprints,
        manifest.catalog_fingerprints
      INTO STRICT functions, triggers, catalogs
      FROM public.privacy_protocol_manifests AS manifest
      WHERE manifest.name = 'operational_privacy_140007'
        AND manifest.migration_version = 20260810140007;

      digest_value := public.digest(pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'functions', functions,
          'triggers', triggers,
          'catalogs', catalogs
        )::text, 'UTF8'), 'sha256');

      UPDATE public.privacy_protocol_manifests
      SET function_fingerprints = functions,
          manifest_digest = digest_value,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'operational_privacy_140007'
        AND migration_version = 20260810140007;
    END;
    $privacy_manifest_refresh$;
    """)

    execute("""
    ALTER TABLE public.privacy_protocol_manifests
      ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger
    """)
  end

  defp refresh_durable_payload_manifest do
    execute("""
    DO $durable_payload_manifest_refresh$
    DECLARE
      function_key text;
      prior_snapshot jsonb;
      current_snapshot jsonb;
      reviewed_snapshot jsonb;
    BEGIN
      SELECT function_row.oid::regprocedure::text
      INTO STRICT function_key
      FROM pg_catalog.pg_proc AS function_row
      WHERE function_row.oid =
              'public.enforce_effect_assignment_final_pair()'::regprocedure;

      SELECT manifest.catalog_manifest
      INTO STRICT prior_snapshot
      FROM public.durable_payload_protocol_manifests AS manifest
      WHERE manifest.name = 'durable_payload_140005'
        AND manifest.migration_version = 20260810140005
      FOR UPDATE;

      current_snapshot := public.durable_payload_catalog_manifest_snapshot();

      IF NOT (prior_snapshot -> 'functions' ? function_key) OR
         NOT (current_snapshot -> 'functions' ? function_key) THEN
        RAISE EXCEPTION 'Durable payload manifest does not track the Effect final-pair guard'
          USING ERRCODE = 'check_violation';
      END IF;

      reviewed_snapshot := pg_catalog.jsonb_set(
        prior_snapshot,
        ARRAY['functions', function_key],
        current_snapshot -> 'functions' -> function_key,
        false
      );

      IF reviewed_snapshot IS DISTINCT FROM current_snapshot THEN
        RAISE EXCEPTION 'Effect final-pair repair found unrelated durable payload catalog drift'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM set_config(
        'maraithon.durable_payload_manifest_refresh',
        'MIGRATOR_DARK_REFRESH_V1',
        true
      );

      UPDATE public.durable_payload_protocol_manifests
      SET catalog_manifest = current_snapshot,
          manifest_digest = public.digest(
            pg_catalog.convert_to(current_snapshot::text, 'UTF8'), 'sha256'
          ),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'durable_payload_140005'
        AND migration_version = 20260810140005;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Durable payload manifest authority is missing'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $durable_payload_manifest_refresh$;
    """)
  end

  defp verify_catalogs do
    execute("""
    DO $effect_retry_pair_verify$
    BEGIN
      IF public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Runtime catalog is not exact after Effect final-pair repair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT public.privacy_protocol_catalog_ready() THEN
        RAISE EXCEPTION 'Privacy protocol catalog is not ready after Effect final-pair repair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT public.durable_payload_catalog_ready() THEN
        RAISE EXCEPTION 'Durable payload catalog is not ready after Effect final-pair repair'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $effect_retry_pair_verify$;
    """)
  end

  defp quote_literal(value), do: "$guard$#{value}$guard$"
end
