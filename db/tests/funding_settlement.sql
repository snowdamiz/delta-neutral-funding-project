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
  ('funding-test-jito', 'funding-test-run', 'jitosol_carry', 'paper', 'hedged', 4, 1000000000);

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
  v_sol jsonb := '{
    "enabled": true,
    "portfolioRunId": "funding-test-sol",
    "stateVersion": "4",
    "positionQuantityAtoms": "2000000000",
    "amountUsdMicros": "75000"
  }'::jsonb;
  v_jito jsonb := '{
    "enabled": true,
    "portfolioRunId": "funding-test-jito",
    "stateVersion": "4",
    "positionQuantityAtoms": "1000000000",
    "amountUsdMicros": "-30000"
  }'::jsonb;
  v_result jsonb;
BEGIN
  v_result := apply_funding_settlement(v_event, v_sol, v_jito);
  IF (v_result->>'insertedEvent')::boolean = false
     OR (v_result->>'payments')::integer <> 2 THEN
    RAISE EXCEPTION 'expected an event and two funding payments, got %', v_result;
  END IF;
  v_result := apply_funding_settlement(v_event, v_sol, v_jito);
  IF (v_result->>'insertedEvent')::boolean
     OR (v_result->>'payments')::integer <> 0 THEN
    RAISE EXCEPTION 'exact funding retry was not a no-op';
  END IF;
END;
$$;

DO $$
BEGIN
  PERFORM apply_funding_settlement(
    jsonb_set(
      (SELECT canonical_payload FROM normalized_events WHERE id = 'funding-test-event'),
      '{rawPayloadHash}',
      '"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
    ),
    '{"enabled": false}'::jsonb,
    '{"enabled": false}'::jsonb
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
  PERFORM apply_funding_settlement(
    v_event,
    '{
      "enabled": true,
      "portfolioRunId": "funding-test-sol",
      "stateVersion": "3",
      "positionQuantityAtoms": "2000000000",
      "amountUsdMicros": "75000"
    }'::jsonb,
    '{"enabled": false}'::jsonb
  );
  RAISE EXCEPTION 'stale funding position was accepted';
EXCEPTION
  WHEN raise_exception THEN
    IF SQLERRM <> 'paper portfolio state changed before funding settlement' THEN
      RAISE;
    END IF;
END;
$$;

DO $$
BEGIN
  IF (SELECT count(*) FROM funding_payments WHERE source_event_id = 'funding-test-event') <> 2 THEN
    RAISE EXCEPTION 'funding payments were not idempotent';
  END IF;
  IF (
    SELECT count(*)
    FROM ledger_batches lb
    JOIN funding_payments fp ON fp.id = lb.event_id
    WHERE lb.event_type = 'funding'
      AND fp.source_event_id = 'funding-test-event'
  ) <> 2 THEN
    RAISE EXCEPTION 'funding ledger batches are incomplete';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM ledger_entries le
    JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
    WHERE lb.portfolio_run_id = 'funding-test-sol'
      AND le.account_debit = 'paper_cash'
      AND le.account_credit = 'funding_income'
      AND le.usd_value_atoms = '75000'
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
