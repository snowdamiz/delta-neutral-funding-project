\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'reconciliation-build', 'test', 'test', 13, repeat('0', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'local-paper-run', 'paper', repeat('0', 64),
  'reconciliation-build', 42, 'xorshift64star-v1'
);
INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, state, state_version,
  initial_capital_usd_micros
) VALUES
  ('local-sol-control', 'local-paper-run', 'sol_control', 'paper', 'hedged', 4, 1000000000),
  ('local-jitosol-carry', 'local-paper-run', 'jitosol_carry', 'paper', 'idle', 0, 1000000000),
  ('local-cross-asset-funding', 'local-paper-run', 'cross_asset_funding', 'paper', 'hedged', 1, 1000000000);
INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'reconciliation-cross-asset', 1, 'FundingObservation',
  'reconciliation-test', 1, 1, '1', 'reconciliation-cross-asset',
  repeat('c', 64), '{}'::jsonb
);
INSERT INTO cross_asset_paper_positions (
  id, portfolio_run_id, venue, asset, instrument, status,
  quantity_atoms, entry_spot_price_usd_micros,
  entry_perp_price_usd_micros, opened_at_ms,
  opened_source_event_id, latest_source_event_id
) VALUES (
  'reconciliation-cross-asset-position', 'local-cross-asset-funding',
  'hyperliquid', 'PURR', 'PURR-PERP', 'open', 1000000000,
  1000000, 1000000, 1,
  'reconciliation-cross-asset', 'reconciliation-cross-asset'
);

DO $$
DECLARE
  v_initial_control_version bigint;
  v_result jsonb;
BEGIN
  SELECT version INTO v_initial_control_version
  FROM control_state
  WHERE singleton;

  v_result := record_paper_reconciliation(
    'reconciliation:startup:1',
    'collector_startup'
  );
  IF v_result->>'result' <> 'recovery_required'
     OR NOT (SELECT pause_entries AND NOT pause_all
             FROM control_state WHERE singleton)
     OR NOT EXISTS (
       SELECT 1
       FROM portfolio_runs
       WHERE id = 'local-sol-control'
         AND state = 'emergency_flatten'
         AND state_version = 5
     )
     OR NOT EXISTS (
       SELECT 1
       FROM portfolio_runs
       WHERE id = 'local-cross-asset-funding'
         AND state = 'hedged'
         AND state_version = 1
     )
     OR NOT EXISTS (
       SELECT 1
       FROM state_transitions
       WHERE id = 'reconciliation:startup:1:local-sol-control:state'
         AND from_state = 'hedged'
         AND to_state = 'emergency_flatten'
         AND state_version = 5
     ) THEN
    RAISE EXCEPTION 'startup reconciliation did not fail the invalid hedge into recovery: %', v_result;
  END IF;

  v_result := record_paper_reconciliation(
    'reconciliation:startup:1',
    'collector_startup'
  );
  IF NOT (v_result->>'duplicate')::boolean
     OR (SELECT count(*) FROM state_transitions
         WHERE portfolio_run_id = 'local-sol-control') <> 1 THEN
    RAISE EXCEPTION 'exact reconciliation retry was not idempotent: %', v_result;
  END IF;

  INSERT INTO execution_intents (
    id, portfolio_run_id, execution_mode, variant, state_version,
    operation, leg, intent_json, intent_hash
  ) VALUES (
    'reconciliation-bad-intent',
    'local-sol-control',
    'paper',
    'sol_control',
    5,
    'CLOSE',
    'SPOT',
    '{"side":"SELL"}'::jsonb,
    repeat('a', 64)
  );
  INSERT INTO orders (
    id, intent_id, portfolio_run_id, execution_mode, variant, status,
    requested_quantity_atoms, filled_quantity_atoms
  ) VALUES (
    'reconciliation-bad-order',
    'reconciliation-bad-intent',
    'local-sol-control',
    'paper',
    'sol_control',
    'filled',
    '1',
    '1'
  );
  INSERT INTO outbox_commands (
    id, portfolio_run_id, intent_id, command_type, payload,
    status, attempts, processed_at
  ) VALUES (
    'reconciliation-bad-command',
    'local-sol-control',
    'reconciliation-bad-intent',
    'paper_order',
    '{}'::jsonb,
    'processed',
    1,
    now()
  );

  v_result := record_paper_reconciliation(
    'reconciliation:startup:2',
    'collector_restart'
  );
  IF v_result->>'result' <> 'mismatch'
     OR jsonb_array_length(v_result->'differences') = 0
     OR NOT (SELECT pause_entries AND pause_all
             FROM control_state WHERE singleton)
     OR NOT EXISTS (
       SELECT 1
       FROM risk_events
       WHERE id = 'reconciliation:startup:2:risk'
         AND code = 'paper_reconciliation_mismatch'
         AND resolved_at IS NULL
     ) THEN
    RAISE EXCEPTION 'accounting mismatch did not block startup: %', v_result;
  END IF;

  v_result := apply_reconciled_operator_command(
    'resume',
    '',
    'reconciliation-test:blocked-resume',
    'operator reviewed the paper state',
    repeat('b', 64)
  );
  IF v_result->>'status' <> 'blocked'
     OR v_result->>'reconciliationResult' <> 'mismatch'
     OR NOT (SELECT pause_entries AND pause_all
             FROM control_state WHERE singleton)
     OR NOT EXISTS (
       SELECT 1
       FROM operator_commands
       WHERE id = v_result->>'commandId'
         AND action = 'resume'
     ) THEN
    RAISE EXCEPTION 'resume bypassed a reconciliation mismatch: %', v_result;
  END IF;

  IF (SELECT count(*) FROM reconciliations) <> 3
     OR (SELECT count(*) FROM risk_events
         WHERE code IN ('paper_recovery_required', 'paper_reconciliation_mismatch')) <> 3
     OR (SELECT version FROM control_state WHERE singleton)
        <> v_initial_control_version + 2 THEN
    RAISE EXCEPTION 'reconciliation audit or fail-closed controls are incomplete';
  END IF;
END;
$$;

ROLLBACK;
