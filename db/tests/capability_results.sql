BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'capability-test-build',
  'code-test',
  'mesh-test',
  27,
  repeat('0', 64)
);

INSERT INTO language_capability_results (
  build_manifest_id, capability_id, status, evidence
) VALUES (
  'capability-test-build',
  'MESH-FIN-001',
  'implemented',
  'checked arithmetic probe'
);

DO $$
BEGIN
  IF (
    SELECT count(*)
    FROM language_capability_results
    WHERE build_manifest_id = 'capability-test-build'
      AND capability_id = 'MESH-FIN-001'
      AND status = 'implemented'
      AND evidence = 'checked arithmetic probe'
  ) <> 1 THEN
    RAISE EXCEPTION 'capability evidence was not attached to its build';
  END IF;
END;
$$;

ROLLBACK;
