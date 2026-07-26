\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'risk-build', 'test', 'test', 11, repeat('0', 64)
);

INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'risk-run', 'paper', repeat('0', 64), 'risk-build', 42, 'xorshift64star-v1'
);

INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros
) VALUES (
  'risk-portfolio', 'risk-run', 'sol_control', 'paper', 1000000000
);

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'risk-event', 1, 'MarketSnapshot', 'risk-test', 1, 1,
  '1', 'risk-test:1', repeat('a', 64), '{}'::jsonb
);

INSERT INTO opportunity_decisions (
  id, source_event_id, variant, observed_at_ms, nav_lamports, hedge_lamports,
  expected_funding_usd_micros, nav_reward_usd_micros,
  net_carry_usd_micros, eligible, reason_code, config_hash
) VALUES (
  'risk-event:sol', 'risk-event', 'sol_control', 1, '1', '1',
  '1', '0', '1', true, 'positive_net_carry', repeat('0', 64)
);

SELECT record_paper_risk_decision(
  'risk-portfolio',
  'risk-event',
  0,
  false,
  'margin_ratio_below_minimum',
  'skip',
  '{"minimumMarginRatioPpm":"1500000"}'::jsonb,
  '{"marginRatioPpm":"1400000"}'::jsonb
);

SELECT record_paper_risk_decision(
  'risk-portfolio',
  'risk-event',
  1,
  true,
  'duplicate_must_not_replace',
  'entry',
  '{}'::jsonb,
  '{}'::jsonb
);

DO $$
BEGIN
  IF (SELECT count(*) FROM risk_decisions) <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM risk_decisions
       WHERE portfolio_run_id = 'risk-portfolio'
         AND opportunity_decision_id = 'risk-event:sol'
         AND state_version = 0
         AND approved = false
         AND reason_code = 'margin_ratio_below_minimum'
         AND action = 'skip'
         AND limits_snapshot->>'minimumMarginRatioPpm' = '1500000'
         AND health_snapshot->>'marginRatioPpm' = '1400000'
     ) THEN
    RAISE EXCEPTION 'risk decision was not recorded idempotently';
  END IF;
END;
$$;

ROLLBACK;
