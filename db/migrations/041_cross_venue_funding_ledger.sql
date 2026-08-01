\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION record_cross_venue_funding_ledger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.venue_payment_id NOT LIKE 'cross-venue:%'
     OR NEW.amount_atoms::numeric = 0 THEN
    RETURN NEW;
  END IF;

  INSERT INTO ledger_batches (
    id, portfolio_run_id, event_type, event_id, batch_hash
  )
  SELECT
    NEW.id || ':ledger', NEW.portfolio_run_id, 'funding', NEW.id,
    raw_payload_hash
  FROM normalized_events
  WHERE id = NEW.source_event_id;

  INSERT INTO ledger_entries (
    ledger_batch_id, account_debit, account_credit, asset,
    amount_atoms, usd_value_atoms, price_reference_id
  ) VALUES (
    NEW.id || ':ledger',
    CASE WHEN NEW.amount_atoms::numeric > 0
      THEN 'paper_cash' ELSE 'funding_expense' END,
    CASE WHEN NEW.amount_atoms::numeric > 0
      THEN 'funding_income' ELSE 'paper_cash' END,
    'USDC',
    abs(NEW.amount_atoms::numeric)::text,
    abs(NEW.usd_value_atoms::numeric)::text,
    NEW.source_event_id
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER record_cross_venue_funding_ledger
AFTER INSERT ON funding_payments
FOR EACH ROW
EXECUTE FUNCTION record_cross_venue_funding_ledger();

INSERT INTO ledger_batches (
  id, portfolio_run_id, event_type, event_id, batch_hash
)
SELECT
  fp.id || ':ledger', fp.portfolio_run_id, 'funding', fp.id,
  ne.raw_payload_hash
FROM funding_payments fp
JOIN normalized_events ne ON ne.id = fp.source_event_id
WHERE fp.venue_payment_id LIKE 'cross-venue:%'
  AND fp.amount_atoms::numeric <> 0
ON CONFLICT (id) DO NOTHING;

INSERT INTO ledger_entries (
  ledger_batch_id, account_debit, account_credit, asset,
  amount_atoms, usd_value_atoms, price_reference_id
)
SELECT
  fp.id || ':ledger',
  CASE WHEN fp.amount_atoms::numeric > 0
    THEN 'paper_cash' ELSE 'funding_expense' END,
  CASE WHEN fp.amount_atoms::numeric > 0
    THEN 'funding_income' ELSE 'paper_cash' END,
  'USDC',
  abs(fp.amount_atoms::numeric)::text,
  abs(fp.usd_value_atoms::numeric)::text,
  fp.source_event_id
FROM funding_payments fp
JOIN ledger_batches lb ON lb.id = fp.id || ':ledger'
WHERE fp.venue_payment_id LIKE 'cross-venue:%'
  AND fp.amount_atoms::numeric <> 0
  AND NOT EXISTS (
    SELECT 1
    FROM ledger_entries le
    WHERE le.ledger_batch_id = lb.id
  );

INSERT INTO schema_meta(version) VALUES (41);

COMMIT;
