\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'funding-test-build', 'test', 'test', 6, repeat('0', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'funding-test-run', 'paper', repeat('0', 64),
  'funding-test-build', 42, 'xorshift64star-v1'
);
INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, state, state_version,
  initial_capital_usd_micros
) VALUES
  ('funding-test-sol', 'funding-test-run', 'sol_control', 'paper', 'hedged', 4, 1000000000),
  ('funding-test-jito', 'funding-test-run', 'jitosol_carry', 'paper', 'hedged', 4, 1000000000),
  ('funding-test-sync-sol', 'funding-test-run', 'sol_control', 'paper', 'hedged', 4, 1000000000),
  ('funding-test-sync-jito', 'funding-test-run', 'jitosol_carry', 'paper', 'hedged', 4, 1000000000);

INSERT INTO execution_intents (
  id, portfolio_run_id, execution_mode, variant, state_version,
  operation, leg, intent_json, intent_hash
)
SELECT
  id || ':intent',
  id,
  'paper',
  variant,
  4,
  'OPEN',
  'PERP',
  jsonb_build_object('side', 'SELL'),
  repeat(substr(md5(id), 1, 32), 2)
FROM portfolio_runs
WHERE strategy_run_id = 'funding-test-run';
INSERT INTO orders (
  id, intent_id, portfolio_run_id, execution_mode, variant, status,
  requested_quantity_atoms, filled_quantity_atoms
)
SELECT
  id || ':order',
  id || ':intent',
  id,
  'paper',
  variant,
  'filled',
  '1000000000',
  '1000000000'
FROM portfolio_runs
WHERE strategy_run_id = 'funding-test-run';
INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'funding-test-position-event', 1, 'MarketSnapshot', 'funding-position-test',
  1, 1, '1', 'funding-position-test:1', repeat('f', 64), '{}'::jsonb
);
INSERT INTO fills (
  id, order_id, portfolio_run_id, execution_mode, variant,
  quantity_atoms, price_atoms, fee_atoms, source_snapshot_id, explanation
)
SELECT
  id || ':fill',
  id || ':order',
  id,
  'paper',
  variant,
  '1000000000',
  '150000000',
  '0',
  'funding-test-position-event',
  '{}'::jsonb
FROM portfolio_runs
WHERE strategy_run_id = 'funding-test-run';

DO $$
DECLARE
  v_event jsonb := '{
    "schemaVersion": 1,
    "eventId": "funding-test-event",
    "eventType": "FundingSettlement",
    "source": "funding-test",
    "observedAtMs": "1785024000000",
    "sourceSlot": "320000012",
    "sourceSequence": "12",
    "idempotencyKey": "funding-test:12",
    "rawPayloadHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "payload": {
      "venuePaymentId": "payment-12",
      "effectiveAtMs": "1785024000000",
      "realizedShortRatePpm": "250",
      "solPriceUsdMicros": "150000000"
    }
  }'::jsonb;
  v_payments jsonb := '[
    {
      "enabled": true,
      "portfolioRunId": "funding-test-sol",
      "stateVersion": "4",
      "positionQuantityAtoms": "1000000000",
      "amountUsdMicros": "37500"
    },
    {
      "enabled": true,
      "portfolioRunId": "funding-test-jito",
      "stateVersion": "4",
      "positionQuantityAtoms": "1000000000",
      "amountUsdMicros": "-30000"
    },
    {
      "enabled": true,
      "portfolioRunId": "funding-test-sync-sol",
      "stateVersion": "4",
      "positionQuantityAtoms": "1000000000",
      "amountUsdMicros": "37500"
    },
    {
      "enabled": true,
      "portfolioRunId": "funding-test-sync-jito",
      "stateVersion": "4",
      "positionQuantityAtoms": "1000000000",
      "amountUsdMicros": "37500"
    }
  ]'::jsonb;
  v_result jsonb;
BEGIN
  v_result := apply_funding_settlements(v_event, v_payments);
  IF (v_result->>'insertedEvent')::boolean = false
     OR (v_result->>'payments')::integer <> 4 THEN
    RAISE EXCEPTION 'expected an event and four funding payments, got %', v_result;
  END IF;
  v_result := apply_funding_settlements(v_event, v_payments);
  IF (v_result->>'insertedEvent')::boolean
     OR (v_result->>'payments')::integer <> 0 THEN
    RAISE EXCEPTION 'exact funding retry was not a no-op';
  END IF;
END;
$$;

DO $$
BEGIN
  PERFORM apply_funding_settlements(
    jsonb_set(
      (SELECT canonical_payload FROM normalized_events WHERE id = 'funding-test-event'),
      '{rawPayloadHash}',
      '"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
    ),
    '[]'::jsonb
  );
  RAISE EXCEPTION 'conflicting duplicate was accepted';
EXCEPTION
  WHEN raise_exception THEN
    IF SQLERRM <> 'idempotency key reused for a different event' THEN
      RAISE;
    END IF;
END;
$$;

DO $$
DECLARE
  v_event jsonb := jsonb_set(
    jsonb_set(
      jsonb_set(
        (SELECT canonical_payload FROM normalized_events WHERE id = 'funding-test-event'),
        '{eventId}',
        '"funding-test-race"'
      ),
      '{idempotencyKey}',
      '"funding-test:race"'
    ),
    '{sourceSequence}',
    '"13"'
  );
BEGIN
  PERFORM apply_funding_settlements(
    v_event,
    '[{
      "enabled": true,
      "portfolioRunId": "funding-test-sol",
      "stateVersion": "3",
      "positionQuantityAtoms": "1000000000",
      "amountUsdMicros": "37500"
    }]'::jsonb
  );
  RAISE EXCEPTION 'stale funding position was accepted';
EXCEPTION
  WHEN raise_exception THEN
    IF SQLERRM <> 'paper portfolio state or funding quantity changed' THEN
      RAISE;
    END IF;
END;
$$;

DO $$
BEGIN
  IF (SELECT count(*) FROM funding_payments WHERE source_event_id = 'funding-test-event') <> 4 THEN
    RAISE EXCEPTION 'funding payments were not idempotent';
  END IF;
  IF (
    SELECT count(*)
    FROM ledger_batches lb
    JOIN funding_payments fp ON fp.id = lb.event_id
    WHERE lb.event_type = 'funding'
      AND fp.source_event_id = 'funding-test-event'
  ) <> 4 THEN
    RAISE EXCEPTION 'funding ledger batches are incomplete';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM ledger_entries le
    JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
    WHERE lb.portfolio_run_id = 'funding-test-sol'
      AND le.account_debit = 'paper_cash'
      AND le.account_credit = 'funding_income'
      AND le.usd_value_atoms = '37500'
  ) THEN
    RAISE EXCEPTION 'received funding ledger direction is wrong';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM ledger_entries le
    JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
    WHERE lb.portfolio_run_id = 'funding-test-jito'
      AND le.account_debit = 'funding_expense'
      AND le.account_credit = 'paper_cash'
      AND le.usd_value_atoms = '30000'
  ) THEN
    RAISE EXCEPTION 'paid funding ledger direction is wrong';
  END IF;
  IF EXISTS (SELECT 1 FROM normalized_events WHERE id = 'funding-test-race') THEN
    RAISE EXCEPTION 'stale funding event was partially committed';
  END IF;
END;
$$;

ROLLBACK;
