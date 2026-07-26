\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'restart-build', 'test', 'test', 24, repeat('0', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'local-paper-run', 'paper', repeat('0', 64),
  'restart-build', 42, 'xorshift64star-v1'
);
INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, state, state_version,
  initial_capital_usd_micros
) VALUES
  ('restart-bootstrapping', 'local-paper-run', 'sol_control', 'paper', 'bootstrapping', 1, 1000000000),
  ('restart-candidate', 'local-paper-run', 'jitosol_carry', 'paper', 'candidate', 1, 1000000000),
  ('restart-opening-spot', 'local-paper-run', 'sol_control', 'paper', 'opening_spot', 1, 1000000000),
  ('restart-opening-perp', 'local-paper-run', 'jitosol_carry', 'paper', 'opening_perp', 1, 1000000000),
  ('restart-rebalancing', 'local-paper-run', 'sol_control', 'paper', 'rebalancing', 1, 1000000000),
  ('restart-exiting-perp', 'local-paper-run', 'jitosol_carry', 'paper', 'exiting_perp', 1, 1000000000),
  ('restart-exiting-spot', 'local-paper-run', 'sol_control', 'paper', 'exiting_spot', 1, 1000000000),
  ('restart-reconciling', 'local-paper-run', 'jitosol_carry', 'paper', 'reconciling', 1, 1000000000),
  ('restart-emergency', 'local-paper-run', 'sol_control', 'paper', 'emergency_flatten', 1, 1000000000);

DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := record_paper_reconciliation(
    'reconciliation:transitional-restarts',
    'transitional_restart_test'
  );
  IF v_result->>'result' <> 'recovery_required'
     OR jsonb_array_length(v_result->'differences') <> 0
     OR (SELECT count(*) FROM portfolio_runs
         WHERE id IN (
           'restart-bootstrapping', 'restart-candidate',
           'restart-reconciling'
         ) AND state = 'idle') <> 3
     OR (SELECT count(*) FROM portfolio_runs
         WHERE id IN (
           'restart-opening-spot', 'restart-opening-perp',
           'restart-rebalancing', 'restart-exiting-perp',
           'restart-exiting-spot', 'restart-emergency'
         ) AND state = 'emergency_flatten') <> 6
     OR (SELECT count(*) FROM state_transitions
         WHERE id LIKE 'reconciliation:transitional-restarts:%:state') <> 8
     OR NOT (SELECT pause_entries AND NOT pause_all
             FROM control_state WHERE singleton) THEN
    RAISE EXCEPTION 'transitional restart recovery is incomplete: %', v_result;
  END IF;

  v_result := record_paper_reconciliation(
    'reconciliation:transitional-restarts',
    'transitional_restart_test'
  );
  IF NOT (v_result->>'duplicate')::boolean
     OR (SELECT count(*) FROM state_transitions
         WHERE id LIKE 'reconciliation:transitional-restarts:%:state') <> 8 THEN
    RAISE EXCEPTION 'transitional restart replay is not idempotent: %', v_result;
  END IF;
END;
$$;

ROLLBACK;
