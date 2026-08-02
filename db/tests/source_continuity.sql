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

-- Two acquisitions of one mint produce two snapshots on the same source, at
-- the same slot, under different signatures. Refusing the second as a
-- sequence regression wedged capture closed: the tick failed, the cursor
-- never advanced, and every later sweep failed identically.
DO $$
DECLARE
  v_base jsonb := jsonb_build_object(
    'schemaVersion', 1,
    'eventType', 'SolanaCandidateSnapshot',
    'source', 'solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ',
    'sourceSlot', '4000',
    'rawPayloadHash', repeat('c', 64)
  );
BEGIN
  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES
    ('resnap-first', 1, 'SolanaCandidateSnapshot',
     'solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ',
     700000, 4000, 'signature-one', 'resnap-first', repeat('c', 64), v_base),
    -- Same mint, same slot, a second buy in a different transaction.
    ('resnap-second', 1, 'SolanaCandidateSnapshot',
     'solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ',
     700000, 4000, 'signature-two', 'resnap-second', repeat('c', 64), v_base),
    -- And a re-quote of the first, later, at a slot the provider moved on.
    ('resnap-third', 1, 'SolanaCandidateSnapshot',
     'solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ',
     760000, 3999, 'signature-one', 'resnap-third', repeat('c', 64), v_base);

  IF (SELECT count(*) FROM normalized_events
      WHERE source = 'solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ') <> 3 THEN
    RAISE EXCEPTION 'a re-snapshot of one mint was refused as a sequence regression';
  END IF;

  -- Time still has to move forward.
  BEGIN
    INSERT INTO normalized_events (
      id, schema_version, event_type, source, observed_at_ms, source_slot,
      source_sequence, idempotency_key, raw_payload_hash, canonical_payload
    ) VALUES (
      'resnap-backwards', 1, 'SolanaCandidateSnapshot',
      'solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ',
      600000, 4000, 'signature-one', 'resnap-backwards', repeat('c', 64), v_base);
    RAISE EXCEPTION 'a snapshot observed before the previous one was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'source sequence gap or regression%' THEN
      RAISE;
    END IF;
  END;
END;
$$;

ROLLBACK;
