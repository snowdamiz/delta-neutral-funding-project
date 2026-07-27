BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'capability-test-build',
  'code-test',
  'mesh-test',
  29,
  repeat('0', 64)
);

DO $$
BEGIN
  IF record_language_capability_results('capability-test-build') <> 23 THEN
    RAISE EXCEPTION 'expected all 23 capability results';
  END IF;

  IF (
    SELECT count(*)
    FROM language_capability_results
    WHERE build_manifest_id = 'capability-test-build'
      AND capability_id IN (
        'MESH-BYTES-001',
        'MESH-CODEC-001',
        'MESH-NUM-001',
        'MESH-NATIVE-001',
        'MESH-WS-001',
        'MESH-HTTP-001',
        'MESH-BORSH-001',
        'MESH-ANCHOR-001',
        'MESH-SOL-READ-001'
      )
      AND status = 'implemented'
      AND length(btrim(evidence)) > 0
  ) <> 9 THEN
    RAISE EXCEPTION 'native read capability evidence is incomplete';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM language_capability_results
    WHERE build_manifest_id = 'capability-test-build'
      AND capability_id = 'MESH-SOL-TX-001'
      AND status = 'implemented'
      AND length(btrim(evidence)) > 0
  ) THEN
    RAISE EXCEPTION 'native transaction capability evidence is incomplete';
  END IF;
END;
$$;

ROLLBACK;
