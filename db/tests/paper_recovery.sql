\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'recovery-build', 'test', 'test', 12, repeat('0', 64)
);

INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'recovery-run', 'paper', repeat('0', 64), 'recovery-build', 42, 'xorshift64star-v1'
);

INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros
) VALUES (
  'recovery-portfolio', 'recovery-run', 'sol_control', 'paper', 1000000000
);

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'recovery-entry-event', 1, 'MarketSnapshot', 'recovery-test', 1, 1,
  '1', 'recovery-test:1', repeat('a', 64), '{}'::jsonb
), (
  'recovery-close-event', 1, 'MarketSnapshot', 'recovery-test', 2, 2,
  '2', 'recovery-test:2', repeat('b', 64), '{}'::jsonb
), (
  'recovery-retry-event', 1, 'MarketSnapshot', 'recovery-test', 3, 3,
  '3', 'recovery-test:3', repeat('c', 64), '{}'::jsonb
);

SELECT apply_paper_plan(
  'recovery-portfolio',
  0,
  'recovery-entry-event',
  '{
    "variant":"sol_control",
    "outcome":"partial",
    "reason":"paper_spot_partial",
    "nextState":"emergency_flatten",
    "nextRandomState":"43",
    "spotPlaced":true,
    "spotStatus":"partial",
    "spotAsset":"SOL",
    "spotRequestedQuantityAtoms":"1000000000",
    "spotFilledQuantityAtoms":"500000000",
    "spotPriceAtoms":"150100000",
    "spotGrossUsdAtoms":"75050000",
    "spotFeeUsdAtoms":"37525",
    "perpPlaced":false,
    "perpStatus":"rejected",
    "perpRequestedQuantityAtoms":"1000000000",
    "perpFilledQuantityAtoms":"0",
    "perpPriceAtoms":"0",
    "perpGrossUsdAtoms":"0",
    "perpFeeUsdAtoms":"0"
  }'::jsonb,
  '{"leg":"SPOT","side":"BUY"}'::jsonb,
  repeat('c', 64),
  '{"leg":"PERP","side":"SELL"}'::jsonb,
  repeat('d', 64)
);

SELECT apply_paper_recovery_plan(
  'recovery-portfolio',
  3,
  'recovery-close-event',
  '{
    "variant":"sol_control",
    "action":"recover",
    "reason":"paper_spot_close_partial",
    "nextState":"emergency_flatten",
    "nextRandomState":"44",
    "observedAtMs":"2",
    "spotAsset":"SOL",
    "currentSpotQuantityAtoms":"500000000",
    "nextSpotQuantityAtoms":"250000000",
    "nextPerpShortQuantityAtoms":"0",
    "protocolNavLamports":"1000000000",
    "marketRateLamports":"1000000000",
    "spotEquivalentLamports":"500000000",
    "deltaLamports":"500000000",
    "deltaBps":"10000",
    "rewardSolLamports":"0",
    "basisSolLamports":"0",
    "rewardUsdMicros":"0",
    "basisUsdMicros":"0",
    "spotPlaced":true,
    "spotStatus":"partial",
    "spotRequestedQuantityAtoms":"500000000",
    "spotFilledQuantityAtoms":"250000000",
    "spotPriceAtoms":"149900000",
    "spotGrossUsdAtoms":"37475000",
    "spotFeeUsdAtoms":"18738",
    "perpPlaced":false,
    "perpSide":"BUY",
    "perpStatus":"rejected",
    "perpRequestedQuantityAtoms":"0",
    "perpFilledQuantityAtoms":"0",
    "perpPriceAtoms":"0",
    "perpGrossUsdAtoms":"0",
    "perpFeeUsdAtoms":"0"
  }'::jsonb,
  '{"leg":"SPOT","side":"SELL"}'::jsonb,
  repeat('e', 64),
  '{"leg":"PERP","side":"BUY"}'::jsonb,
  repeat('f', 64)
);

SELECT apply_paper_recovery_plan(
  'recovery-portfolio',
  4,
  'recovery-retry-event',
  '{
    "variant":"sol_control",
    "action":"recover",
    "reason":"paper_entry_recovered",
    "nextState":"idle",
    "nextRandomState":"45",
    "observedAtMs":"3",
    "spotAsset":"SOL",
    "currentSpotQuantityAtoms":"250000000",
    "nextSpotQuantityAtoms":"0",
    "nextPerpShortQuantityAtoms":"0",
    "protocolNavLamports":"1000000000",
    "marketRateLamports":"1000000000",
    "spotEquivalentLamports":"250000000",
    "deltaLamports":"250000000",
    "deltaBps":"10000",
    "rewardSolLamports":"0",
    "basisSolLamports":"0",
    "rewardUsdMicros":"0",
    "basisUsdMicros":"0",
    "spotPlaced":true,
    "spotStatus":"filled",
    "spotRequestedQuantityAtoms":"250000000",
    "spotFilledQuantityAtoms":"250000000",
    "spotPriceAtoms":"149900000",
    "spotGrossUsdAtoms":"37475000",
    "spotFeeUsdAtoms":"18738",
    "perpPlaced":false,
    "perpSide":"BUY",
    "perpStatus":"rejected",
    "perpRequestedQuantityAtoms":"0",
    "perpFilledQuantityAtoms":"0",
    "perpPriceAtoms":"0",
    "perpGrossUsdAtoms":"0",
    "perpFeeUsdAtoms":"0"
  }'::jsonb,
  '{"leg":"SPOT","side":"SELL"}'::jsonb,
  repeat('1', 64),
  '{"leg":"PERP","side":"BUY"}'::jsonb,
  repeat('2', 64)
);

SELECT apply_paper_recovery_plan(
  'recovery-portfolio',
  4,
  'recovery-retry-event',
  '{"variant":"sol_control","action":"recover"}'::jsonb,
  '{}'::jsonb,
  repeat('1', 64),
  '{}'::jsonb,
  repeat('2', 64)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM portfolio_runs
    WHERE id = 'recovery-portfolio'
      AND state = 'idle'
      AND state_version = 6
      AND random_state = 45
  ) OR (SELECT count(*) FROM state_transitions
        WHERE portfolio_run_id = 'recovery-portfolio') <> 6 THEN
    RAISE EXCEPTION 'partial entry did not reconcile back to idle';
  END IF;

  IF (SELECT count(*) FROM orders
      WHERE portfolio_run_id = 'recovery-portfolio') <> 3
     OR (SELECT count(*) FROM fills
      WHERE portfolio_run_id = 'recovery-portfolio') <> 3
     OR (SELECT count(*) FROM ledger_entries le
      JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
      WHERE lb.portfolio_run_id = 'recovery-portfolio') <> 6 THEN
    RAISE EXCEPTION 'recovery fills or balanced costs were not persisted';
  END IF;

  IF (SELECT count(*) FROM paper_event_applications
      WHERE portfolio_run_id = 'recovery-portfolio') <> 3
     OR EXISTS (
       SELECT 1 FROM risk_events
       WHERE portfolio_run_id = 'recovery-portfolio'
         AND resolved_at IS NULL
     ) THEN
    RAISE EXCEPTION 'recovery was not idempotent or did not resolve the incident';
  END IF;
END;
$$;

ROLLBACK;
