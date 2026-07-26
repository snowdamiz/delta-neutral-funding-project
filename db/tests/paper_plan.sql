\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'test-paper-build', 'test', 'test', 4, repeat('0', 64)
);

INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'test-paper-run', 'paper', repeat('0', 64), 'test-paper-build', 42, 'xorshift64star-v1'
);

INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros
) VALUES (
  'test-paper-portfolio', 'test-paper-run', 'sol_control', 'paper', 1000000000
);

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'test-paper-event', 1, 'MarketSnapshot', 'sql-test', 1, 1,
  '1', 'sql-test:1', repeat('a', 64), '{}'::jsonb
);

SELECT apply_paper_plan(
  'test-paper-portfolio',
  0,
  'test-paper-event',
  '{
    "variant":"sol_control",
    "outcome":"hedged",
    "reason":"paper_entry_hedged",
    "nextState":"hedged",
    "nextRandomState":"99",
    "spotPlaced":true,
    "spotStatus":"filled",
    "spotAsset":"SOL",
    "spotRequestedQuantityAtoms":"1000000000",
    "spotFilledQuantityAtoms":"1000000000",
    "spotPriceAtoms":"150100000",
    "spotGrossUsdAtoms":"150100000",
    "spotFeeUsdAtoms":"75050",
    "perpPlaced":true,
    "perpStatus":"filled",
    "perpRequestedQuantityAtoms":"1000000000",
    "perpFilledQuantityAtoms":"1000000000",
    "perpPriceAtoms":"149900000",
    "perpGrossUsdAtoms":"149900000",
    "perpFeeUsdAtoms":"59960"
  }'::jsonb,
  '{"leg":"SPOT"}'::jsonb,
  repeat('b', 64),
  '{"leg":"PERP"}'::jsonb,
  repeat('c', 64)
);

INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros
) VALUES (
  'test-paper-emergency', 'test-paper-run', 'jitosol_carry', 'paper', 1000000000
);

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'test-paper-emergency-event', 1, 'MarketSnapshot', 'sql-test', 2, 2,
  '2', 'sql-test:2', repeat('d', 64), '{}'::jsonb
);

SELECT apply_paper_plan(
  'test-paper-emergency',
  0,
  'test-paper-emergency-event',
  '{
    "variant":"jitosol_carry",
    "outcome":"rejected",
    "reason":"paper_spot_rejected",
    "nextState":"emergency_flatten",
    "nextRandomState":"100",
    "spotPlaced":false,
    "spotStatus":"rejected",
    "spotAsset":"JitoSOL",
    "spotRequestedQuantityAtoms":"1000000000",
    "spotFilledQuantityAtoms":"0",
    "spotPriceAtoms":"0",
    "spotGrossUsdAtoms":"0",
    "spotFeeUsdAtoms":"0",
    "perpPlaced":false,
    "perpStatus":"rejected",
    "perpRequestedQuantityAtoms":"1000000000",
    "perpFilledQuantityAtoms":"0",
    "perpPriceAtoms":"0",
    "perpGrossUsdAtoms":"0",
    "perpFeeUsdAtoms":"0"
  }'::jsonb,
  '{"leg":"SPOT"}'::jsonb,
  repeat('e', 64),
  '{"leg":"PERP"}'::jsonb,
  repeat('f', 64)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM portfolio_runs
    WHERE id = 'test-paper-portfolio'
      AND state = 'hedged'
      AND state_version = 4
      AND random_state = 99
  ) THEN
    RAISE EXCEPTION 'paper portfolio did not reach the reconciled hedged state';
  END IF;

  IF (SELECT count(*) FROM state_transitions WHERE portfolio_run_id = 'test-paper-portfolio') <> 4 THEN
    RAISE EXCEPTION 'paper state transition count is wrong';
  END IF;

  IF (SELECT count(*) FROM orders WHERE portfolio_run_id = 'test-paper-portfolio') <> 2
     OR (SELECT count(*) FROM fills WHERE portfolio_run_id = 'test-paper-portfolio') <> 2 THEN
    RAISE EXCEPTION 'paper orders and fills were not persisted';
  END IF;

  IF (SELECT count(*) FROM ledger_entries le
      JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
      WHERE lb.portfolio_run_id = 'test-paper-portfolio') <> 4 THEN
    RAISE EXCEPTION 'paper ledger entries were not persisted';
  END IF;

  IF (SELECT count(*) FROM outbox_commands
      WHERE portfolio_run_id = 'test-paper-portfolio'
        AND status = 'processed'
        AND processed_at IS NOT NULL) <> 2 THEN
    RAISE EXCEPTION 'paper outbox commands were not marked processed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM portfolio_runs
    WHERE id = 'test-paper-emergency'
      AND state = 'emergency_flatten'
      AND state_version = 3
      AND random_state = 100
  ) OR (SELECT count(*) FROM orders
        WHERE portfolio_run_id = 'test-paper-emergency') <> 0
     OR (SELECT count(*) FROM risk_events
        WHERE portfolio_run_id = 'test-paper-emergency'
          AND severity = 'critical') <> 1 THEN
    RAISE EXCEPTION 'paper rejection did not fail closed';
  END IF;
END;
$$;

ROLLBACK;
