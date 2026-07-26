BEGIN;

CREATE FUNCTION apply_funding_settlements(
  p_event jsonb,
  p_payments jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_event_inserted integer;
  v_expected_payments integer;
  v_valid_payments integer;
  v_inserted_payments integer;
  v_event_matches boolean;
BEGIN
  IF p_event->>'eventType' <> 'FundingSettlement'
     OR (p_event->>'schemaVersion')::integer <> 1 THEN
    RAISE EXCEPTION 'invalid funding event contract';
  END IF;
  IF jsonb_typeof(p_payments) <> 'array'
     OR jsonb_array_length(p_payments) > 16
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_payments)
       WHERE jsonb_typeof(value) <> 'object'
     ) THEN
    RAISE EXCEPTION 'invalid funding payment collection';
  END IF;

  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    p_event->>'eventId',
    1,
    'FundingSettlement',
    p_event->>'source',
    (p_event->>'observedAtMs')::bigint,
    (p_event->>'sourceSlot')::bigint,
    p_event->>'sourceSequence',
    p_event->>'idempotencyKey',
    p_event->>'rawPayloadHash',
    p_event
  )
  ON CONFLICT (idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_event_inserted = ROW_COUNT;

  IF v_event_inserted = 0 THEN
    SELECT id = p_event->>'eventId'
      AND raw_payload_hash = p_event->>'rawPayloadHash'
      AND canonical_payload = p_event
    INTO v_event_matches
    FROM normalized_events
    WHERE idempotency_key = p_event->>'idempotencyKey';

    IF COALESCE(v_event_matches, false) = false THEN
      RAISE EXCEPTION 'idempotency key reused for a different event';
    END IF;
    RETURN jsonb_build_object('insertedEvent', false, 'payments', 0);
  END IF;

  WITH payments AS (
    SELECT value AS payment
    FROM jsonb_array_elements(p_payments)
    WHERE (value->>'enabled')::boolean
  )
  SELECT count(*) INTO v_expected_payments FROM payments;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_payments) payment
    WHERE (payment->>'enabled')::boolean
    GROUP BY payment->>'portfolioRunId'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'duplicate funding portfolio';
  END IF;

  PERFORM 1
  FROM portfolio_runs p
  JOIN jsonb_array_elements(p_payments) payment
    ON payment->>'portfolioRunId' = p.id
   AND (payment->>'enabled')::boolean
  ORDER BY p.id
  FOR UPDATE OF p;

  WITH payments AS (
    SELECT value AS payment
    FROM jsonb_array_elements(p_payments)
    WHERE (value->>'enabled')::boolean
  ),
  balances AS (
    SELECT
      p.id,
      p.state,
      p.state_version,
      p.execution_mode,
      COALESCE(sum(CASE
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL'
          THEN f.quantity_atoms::numeric
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY'
          THEN -f.quantity_atoms::numeric
        ELSE 0
      END), 0) AS perp
    FROM portfolio_runs p
    LEFT JOIN fills f ON f.portfolio_run_id = p.id
    LEFT JOIN orders o ON o.id = f.order_id
    LEFT JOIN execution_intents ei ON ei.id = o.intent_id
    JOIN payments ON payments.payment->>'portfolioRunId' = p.id
    GROUP BY p.id, p.state, p.state_version, p.execution_mode
  )
  SELECT count(*)
  INTO v_valid_payments
  FROM payments
  JOIN balances
    ON balances.id = payments.payment->>'portfolioRunId'
   AND balances.execution_mode = 'paper'
   AND balances.state = 'hedged'
   AND balances.state_version = (payments.payment->>'stateVersion')::bigint
   AND balances.perp = (payments.payment->>'positionQuantityAtoms')::numeric
   AND balances.perp > 0;

  IF v_valid_payments <> v_expected_payments THEN
    RAISE EXCEPTION 'paper portfolio state or funding quantity changed';
  END IF;

  WITH payments AS (
    SELECT value AS payment
    FROM jsonb_array_elements(p_payments)
    WHERE (value->>'enabled')::boolean
  )
  INSERT INTO funding_payments (
    id, portfolio_run_id, venue_payment_id, effective_at_ms,
    position_quantity_atoms, raw_rate_atoms, normalized_rate_atoms,
    amount_atoms, usd_value_atoms, realization_status, source_event_id
  )
  SELECT
    (p_event->>'eventId') || ':' || (payment->>'portfolioRunId'),
    payment->>'portfolioRunId',
    p_event#>>'{payload,venuePaymentId}',
    (p_event#>>'{payload,effectiveAtMs}')::bigint,
    payment->>'positionQuantityAtoms',
    p_event#>>'{payload,realizedShortRatePpm}',
    p_event#>>'{payload,realizedShortRatePpm}',
    payment->>'amountUsdMicros',
    payment->>'amountUsdMicros',
    'realized',
    p_event->>'eventId'
  FROM payments;
  GET DIAGNOSTICS v_inserted_payments = ROW_COUNT;

  INSERT INTO ledger_batches (
    id, portfolio_run_id, event_type, event_id, batch_hash
  )
  SELECT
    fp.id || ':ledger',
    fp.portfolio_run_id,
    'funding',
    fp.id,
    p_event->>'rawPayloadHash'
  FROM funding_payments fp
  WHERE fp.source_event_id = p_event->>'eventId'
    AND (fp.amount_atoms)::numeric <> 0;

  INSERT INTO ledger_entries (
    ledger_batch_id, account_debit, account_credit, asset,
    amount_atoms, usd_value_atoms, price_reference_id
  )
  SELECT
    fp.id || ':ledger',
    CASE WHEN (fp.amount_atoms)::numeric > 0
      THEN 'paper_cash' ELSE 'funding_expense' END,
    CASE WHEN (fp.amount_atoms)::numeric > 0
      THEN 'funding_income' ELSE 'paper_cash' END,
    'USDC',
    abs((fp.amount_atoms)::numeric)::text,
    abs((fp.usd_value_atoms)::numeric)::text,
    fp.source_event_id
  FROM funding_payments fp
  WHERE fp.source_event_id = p_event->>'eventId'
    AND (fp.amount_atoms)::numeric <> 0;

  RETURN jsonb_build_object(
    'insertedEvent', true,
    'payments', v_inserted_payments
  );
END;
$$;

INSERT INTO schema_meta(version) VALUES (19);

COMMIT;
