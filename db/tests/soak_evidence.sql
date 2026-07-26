BEGIN;

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES
  ('soak-snapshot-1', 1, 'MarketSnapshot', 'authoritative:soak-test',
   1000, 1, '1', 'soak:snapshot:1', repeat('a', 64),
   '{"payload":{"epoch":"100"}}'),
  ('soak-snapshot-2', 1, 'MarketSnapshot', 'authoritative:soak-test',
   3000, 2, '2', 'soak:snapshot:2', repeat('b', 64),
   '{"payload":{"epoch":"100"}}'),
  ('soak-snapshot-3', 1, 'MarketSnapshot', 'authoritative:soak-test',
   8000, 3, '3', 'soak:snapshot:3', repeat('c', 64),
   '{"payload":{"epoch":"101"}}'),
  ('soak-funding-1', 1, 'FundingSettlement', 'phoenix-funding:SOL',
   8000, 3, 'funding-1', 'soak:funding:1', repeat('d', 64),
   '{"payload":{"venuePaymentId":"soak-funding-1"}}');

INSERT INTO opportunity_decisions (
  id, source_event_id, variant, observed_at_ms, nav_lamports, hedge_lamports,
  expected_funding_usd_micros, nav_reward_usd_micros,
  net_carry_usd_micros, eligible, reason_code, config_hash
)
SELECT
  event.id || ':' || variant.name,
  event.id,
  variant.name::strategy_variant,
  event.observed_at_ms,
  '1', '1', '1', '1', '1', true, 'eligible', repeat('0', 64)
FROM normalized_events event
CROSS JOIN (VALUES ('sol_control'), ('jitosol_carry')) AS variant(name)
WHERE event.source = 'authoritative:soak-test';

DO $$
DECLARE
  evidence jsonb := paper_soak_evidence(9000, 6000);
BEGIN
  IF evidence->>'status' <> 'collecting'
     OR evidence->>'authoritativeSnapshots' <> '3'
     OR evidence->>'pairedDecisionSnapshots' <> '3'
     OR evidence->>'fundingIntervals' <> '1'
     OR evidence->>'epochsObserved' <> '2'
     OR evidence->>'epochTransitions' <> '1'
     OR evidence->>'sourceSessions' <> '1'
     OR evidence->>'firstObservedAtMs' <> '1000'
     OR evidence->>'lastObservedAtMs' <> '8000'
     OR evidence->>'elapsedMs' <> '7000'
     OR evidence->>'maximumGapMs' <> '5000'
     OR evidence->>'staleForMs' <> '1000'
     OR evidence->>'continuous' <> 'true'
     OR evidence->>'complete' <> 'false' THEN
    RAISE EXCEPTION 'unexpected soak evidence: %', evidence;
  END IF;
END;
$$;

ROLLBACK;
