\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_initial_version bigint;
  v_result jsonb;
BEGIN
  SELECT version INTO v_initial_version FROM control_state WHERE singleton;

  v_result := apply_operator_command(
    'pause_entries',
    'operator-test:pause-entries',
    'review funding source',
    repeat('a', 64)
  );
  IF v_result->>'status' <> 'applied'
     OR (v_result->>'controlVersion')::bigint <> v_initial_version + 1 THEN
    RAISE EXCEPTION 'pause-entries result is invalid: %', v_result;
  END IF;
  IF NOT (SELECT pause_entries AND NOT pause_all FROM control_state WHERE singleton) THEN
    RAISE EXCEPTION 'pause-entries did not persist';
  END IF;

  v_result := apply_operator_command(
    'pause_entries',
    'operator-test:pause-entries',
    'review funding source',
    repeat('a', 64)
  );
  IF NOT (v_result->>'duplicate')::boolean
     OR (SELECT version FROM control_state WHERE singleton) <> v_initial_version + 1 THEN
    RAISE EXCEPTION 'exact operator retry was not a no-op';
  END IF;

  BEGIN
    PERFORM apply_operator_command(
      'pause_entries',
      'operator-test:pause-entries',
      'different request',
      repeat('b', 64)
    );
    RAISE EXCEPTION 'conflicting operator duplicate was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'idempotency key reused for a different operator command' THEN
        RAISE;
      END IF;
  END;

  PERFORM apply_operator_command(
    'pause_all',
    'operator-test:pause-all',
    'dependency incident',
    repeat('c', 64)
  );
  IF NOT (SELECT pause_entries AND pause_all FROM control_state WHERE singleton) THEN
    RAISE EXCEPTION 'pause-all did not persist';
  END IF;

  v_result := apply_operator_command(
    'resume',
    'operator-test:resume',
    'paper state reviewed',
    repeat('d', 64)
  );
  IF (SELECT pause_entries OR pause_all FROM control_state WHERE singleton) THEN
    RAISE EXCEPTION 'resume did not clear controls';
  END IF;
  IF v_result->>'reconciliationId' = ''
     OR NOT EXISTS (
       SELECT 1
       FROM reconciliations
       WHERE id = v_result->>'reconciliationId'
         AND result = 'matched'
         AND completed_at IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'resume skipped reconciliation';
  END IF;

  v_result := apply_operator_command(
    'reconcile',
    'operator-test:reconcile',
    'scheduled paper check',
    repeat('e', 64)
  );
  IF v_result->>'reconciliationId' = ''
     OR (SELECT version FROM control_state WHERE singleton) <> v_initial_version + 3 THEN
    RAISE EXCEPTION 'standalone reconciliation changed control state';
  END IF;

  IF (
    SELECT count(*)
    FROM operator_commands
    WHERE idempotency_key LIKE 'operator-test:%'
  ) <> 4 THEN
    RAISE EXCEPTION 'operator audit log is incomplete';
  END IF;
END;
$$;

ROLLBACK;
