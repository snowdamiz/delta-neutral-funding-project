\set ON_ERROR_STOP on

BEGIN;

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'continuity-1', 1, 'MarketSnapshot', 'continuity-test', 1000, 10,
  '1', 'continuity-test:1', repeat('a', 64), '{}'::jsonb
);

DO $$
BEGIN
  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    'continuity-3', 1, 'MarketSnapshot', 'continuity-test', 3000, 30,
    '3', 'continuity-test:3', repeat('c', 64), '{}'::jsonb
  );
  RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'source gap was accepted';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN NULL;
END;
$$;

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'continuity-2', 1, 'MarketSnapshot', 'continuity-test', 2000, 20,
  '2', 'continuity-test:2', repeat('b', 64), '{}'::jsonb
);

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'continuity-funding-2', 1, 'FundingSettlement', 'continuity-test', 2000, 20,
  '2', 'continuity-test:funding:2', repeat('d', 64), '{}'::jsonb
);

ROLLBACK;
