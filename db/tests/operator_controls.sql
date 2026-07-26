\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'local-paper-build', 'test', 'test', 9, repeat('0', 64)
) ON CONFLICT (id) DO NOTHING;
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'local-paper-run', 'paper', repeat('0', 64), 'local-paper-build', 42, 'test'
) ON CONFLICT (id) DO NOTHING;
INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros
) VALUES (
  'local-sol-control', 'local-paper-run', 'sol_control', 'paper', 1000000000
), (
  'local-jitosol-carry', 'local-paper-run', 'jitosol_carry', 'paper', 1000000000
) ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
  v_initial_version bigint;
  v_result jsonb;
BEGIN
  SELECT version INTO v_initial_version FROM control_state WHERE singleton;

  v_result := apply_operator_command(
    'pause_entries',
    '',
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
    '',
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
      '',
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
    '',
    'operator-test:pause-all',
    'dependency incident',
    repeat('c', 64)
  );
  IF NOT (SELECT pause_entries AND pause_all FROM control_state WHERE singleton) THEN
    RAISE EXCEPTION 'pause-all did not persist';
  END IF;

  v_result := apply_operator_command(
    'resume',
    '',
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
    '',
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

  UPDATE portfolio_runs
  SET state = 'hedged'
  WHERE id = 'local-sol-control';
  v_result := apply_operator_command(
    'exit_position',
    'local-sol-control',
    'operator-test:exit',
    'operator requested paper exit',
    repeat('f', 64)
  );
  IF v_result->>'status' <> 'accepted'
     OR (SELECT count(*) FROM operator_portfolio_actions
         WHERE command_id = v_result->>'commandId' AND status = 'pending') <> 1 THEN
    RAISE EXCEPTION 'paper exit was not queued: %', v_result;
  END IF;
  UPDATE portfolio_runs
  SET state = 'idle'
  WHERE id = 'local-sol-control';
  IF (SELECT status FROM operator_portfolio_actions
      WHERE command_id = v_result->>'commandId') <> 'applied' THEN
    RAISE EXCEPTION 'paper exit completion was not tracked';
  END IF;

  UPDATE portfolio_runs
  SET state = 'hedged'
  WHERE id = 'local-jitosol-carry';
  v_result := apply_operator_command(
    'emergency_flatten',
    '*',
    'operator-test:flatten',
    'operator emergency paper flatten',
    repeat('1', 64)
  );
  IF v_result->>'status' <> 'accepted'
     OR NOT (SELECT pause_entries AND pause_all FROM control_state WHERE singleton)
     OR (SELECT count(*) FROM operator_portfolio_actions
         WHERE command_id = v_result->>'commandId' AND status = 'pending') <> 1 THEN
    RAISE EXCEPTION 'emergency flatten was not queued fail-closed: %', v_result;
  END IF;

  v_result := apply_operator_command(
    'alerts_test',
    '',
    'operator-test:alert',
    'operator alert path check',
    repeat('2', 64)
  );
  IF v_result->>'status' <> 'applied'
     OR NOT EXISTS (
       SELECT 1 FROM risk_events
       WHERE id = 'operator:operator-test:alert:risk'
         AND code = 'operator_alert_test'
         AND resolved_at IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'operator alert test was not recorded: %', v_result;
  END IF;
END;
$$;

ROLLBACK;
