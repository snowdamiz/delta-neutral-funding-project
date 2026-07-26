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

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'test-paper-rebalance-event', 1, 'MarketSnapshot', 'sql-test', 2, 2,
  '2', 'sql-test:2', repeat('d', 64), '{}'::jsonb
);

SELECT apply_paper_position_plan(
  'test-paper-portfolio',
  4,
  'test-paper-rebalance-event',
  '{
    "variant":"sol_control",
    "action":"rebalance_perp",
    "reason":"paper_delta_rebalanced",
    "nextState":"hedged",
    "nextRandomState":"101",
    "observedAtMs":"2",
    "spotAsset":"SOL",
    "currentSpotQuantityAtoms":"1000000000",
    "nextSpotQuantityAtoms":"1000000000",
    "nextPerpShortQuantityAtoms":"1100000000",
    "protocolNavLamports":"1000000000",
    "marketRateLamports":"1000000000",
    "spotEquivalentLamports":"1100000000",
    "deltaLamports":"100000000",
    "deltaBps":"909",
    "rewardSolLamports":"0",
    "basisSolLamports":"0",
    "rewardUsdMicros":"0",
    "basisUsdMicros":"0",
    "spotPlaced":false,
    "spotStatus":"rejected",
    "spotRequestedQuantityAtoms":"0",
    "spotFilledQuantityAtoms":"0",
    "spotPriceAtoms":"0",
    "spotGrossUsdAtoms":"0",
    "spotFeeUsdAtoms":"0",
    "perpPlaced":true,
    "perpSide":"SELL",
    "perpStatus":"filled",
    "perpRequestedQuantityAtoms":"100000000",
    "perpFilledQuantityAtoms":"100000000",
    "perpPriceAtoms":"149900000",
    "perpGrossUsdAtoms":"14990000",
    "perpFeeUsdAtoms":"5996"
  }'::jsonb,
  '{}'::jsonb,
  repeat('e', 64),
  '{"leg":"PERP","side":"SELL"}'::jsonb,
  repeat('f', 64)
);

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'test-paper-exit-event', 1, 'MarketSnapshot', 'sql-test', 3, 3,
  '3', 'sql-test:3', repeat('1', 64), '{}'::jsonb
);

SELECT apply_paper_position_plan(
  'test-paper-portfolio',
  6,
  'test-paper-exit-event',
  '{
    "variant":"sol_control",
    "action":"exit",
    "reason":"carry_non_positive",
    "nextState":"idle",
    "nextRandomState":"102",
    "observedAtMs":"3",
    "spotAsset":"SOL",
    "currentSpotQuantityAtoms":"1000000000",
    "nextSpotQuantityAtoms":"0",
    "nextPerpShortQuantityAtoms":"0",
    "protocolNavLamports":"1000000000",
    "marketRateLamports":"1000000000",
    "spotEquivalentLamports":"1000000000",
    "deltaLamports":"-100000000",
    "deltaBps":"1000",
    "rewardSolLamports":"0",
    "basisSolLamports":"0",
    "rewardUsdMicros":"0",
    "basisUsdMicros":"0",
    "spotPlaced":true,
    "spotStatus":"filled",
    "spotRequestedQuantityAtoms":"1000000000",
    "spotFilledQuantityAtoms":"1000000000",
    "spotPriceAtoms":"149900000",
    "spotGrossUsdAtoms":"149900000",
    "spotFeeUsdAtoms":"74950",
    "perpPlaced":true,
    "perpSide":"BUY",
    "perpStatus":"filled",
    "perpRequestedQuantityAtoms":"1100000000",
    "perpFilledQuantityAtoms":"1100000000",
    "perpPriceAtoms":"150100000",
    "perpGrossUsdAtoms":"165110000",
    "perpFeeUsdAtoms":"66044"
  }'::jsonb,
  '{"leg":"SPOT","side":"SELL"}'::jsonb,
  repeat('2', 64),
  '{"leg":"PERP","side":"BUY"}'::jsonb,
  repeat('3', 64)
);

SELECT apply_paper_position_plan(
  'test-paper-portfolio',
  6,
  'test-paper-exit-event',
  '{"variant":"sol_control","action":"exit"}'::jsonb,
  '{}'::jsonb,
  repeat('2', 64),
  '{}'::jsonb,
  repeat('3', 64)
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
  'test-paper-emergency-event', 1, 'MarketSnapshot', 'sql-test', 4, 4,
  '4', 'sql-test:4', repeat('4', 64), '{}'::jsonb
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
  repeat('5', 64),
  '{"leg":"PERP"}'::jsonb,
  repeat('6', 64)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM portfolio_runs
    WHERE id = 'test-paper-portfolio'
      AND state = 'idle'
      AND state_version = 9
      AND random_state = 102
  ) THEN
    RAISE EXCEPTION 'paper portfolio did not reach the reconciled hedged state';
  END IF;

  IF (SELECT count(*) FROM state_transitions WHERE portfolio_run_id = 'test-paper-portfolio') <> 9 THEN
    RAISE EXCEPTION 'paper state transition count is wrong';
  END IF;

  IF (SELECT count(*) FROM orders WHERE portfolio_run_id = 'test-paper-portfolio') <> 5
     OR (SELECT count(*) FROM fills WHERE portfolio_run_id = 'test-paper-portfolio') <> 5 THEN
    RAISE EXCEPTION 'paper orders and fills were not persisted';
  END IF;

  IF (SELECT count(*) FROM ledger_entries le
      JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
      WHERE lb.portfolio_run_id = 'test-paper-portfolio') <> 10 THEN
    RAISE EXCEPTION 'paper ledger entries were not persisted';
  END IF;

  IF (SELECT count(*) FROM outbox_commands
      WHERE portfolio_run_id = 'test-paper-portfolio'
        AND status = 'processed'
        AND processed_at IS NOT NULL) <> 5 THEN
    RAISE EXCEPTION 'paper outbox commands were not marked processed';
  END IF;

  IF (SELECT count(*) FROM valuation_events
      WHERE portfolio_run_id = 'test-paper-portfolio') <> 2
     OR (SELECT count(*) FROM position_snapshots
      WHERE portfolio_run_id = 'test-paper-portfolio') <> 2
     OR (SELECT count(*) FROM paper_event_applications
      WHERE portfolio_run_id = 'test-paper-portfolio') <> 3 THEN
    RAISE EXCEPTION 'paper lifecycle events were not idempotently persisted';
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
