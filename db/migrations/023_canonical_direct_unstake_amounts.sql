BEGIN;

UPDATE direct_unstake_counterfactuals
SET cooldown_funding_usd_micros = '0'
WHERE cooldown_funding_usd_micros = '-0';
UPDATE direct_unstake_counterfactuals
SET net_usd_micros = '0'
WHERE net_usd_micros = '-0';
UPDATE direct_unstake_ledger_entries
SET usd_value_micros = '0'
WHERE usd_value_micros = '-0';

ALTER TABLE direct_unstake_counterfactuals
  DROP CONSTRAINT direct_unstake_counterfactual_cooldown_funding_usd_micros_check,
  DROP CONSTRAINT direct_unstake_counterfactuals_net_usd_micros_check,
  ADD CHECK (
    cooldown_funding_usd_micros ~ '^(0|-?[1-9][0-9]*)$'
  ),
  ADD CHECK (
    net_usd_micros ~ '^(0|-?[1-9][0-9]*)$'
  );
ALTER TABLE direct_unstake_ledger_entries
  DROP CONSTRAINT direct_unstake_ledger_entries_usd_value_micros_check,
  ADD CHECK (
    usd_value_micros ~ '^(0|-?[1-9][0-9]*)$'
  );

CREATE FUNCTION canonicalize_direct_unstake_ledger_zero()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.usd_value_micros = '-0' THEN
    NEW.usd_value_micros := '0';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER direct_unstake_ledger_canonical_zero
  BEFORE INSERT OR UPDATE OF usd_value_micros
  ON direct_unstake_ledger_entries
  FOR EACH ROW
  EXECUTE FUNCTION canonicalize_direct_unstake_ledger_zero();

CREATE OR REPLACE FUNCTION record_direct_unstake_funding(
  p_event jsonb,
  p_payments jsonb
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_expected integer;
  v_valid integer;
  v_inserted integer;
BEGIN
  IF jsonb_typeof(p_payments) <> 'array'
     OR jsonb_array_length(p_payments) > 16
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_payments)
       WHERE jsonb_typeof(value) <> 'object'
     ) THEN
    RAISE EXCEPTION 'invalid direct unstake funding collection';
  END IF;
  SELECT count(*) INTO v_expected FROM jsonb_array_elements(p_payments);
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_payments) payment
    GROUP BY payment->>'counterfactualId'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'duplicate direct unstake funding identity';
  END IF;

  PERFORM 1
  FROM direct_unstake_counterfactuals c
  JOIN jsonb_array_elements(p_payments) payment
    ON payment->>'counterfactualId' = c.id
  ORDER BY c.id
  FOR UPDATE OF c;

  SELECT count(*)
  INTO v_valid
  FROM jsonb_array_elements(p_payments) payment
  JOIN direct_unstake_counterfactuals c
    ON c.id = payment->>'counterfactualId'
   AND c.state NOT IN ('withdrawn', 'failed')
   AND c.hedge_quantity_atoms = payment->>'positionQuantityAtoms'
  WHERE payment->>'amountUsdMicros' ~ '^(0|-?[1-9][0-9]*)$';
  IF v_valid <> v_expected THEN
    RAISE EXCEPTION 'direct unstake hedge changed before funding settlement';
  END IF;

  WITH inserted AS (
    INSERT INTO direct_unstake_ledger_entries (
      id, counterfactual_id, source_event_id, component, usd_value_micros
    )
    SELECT
      (payment->>'counterfactualId') || ':' || (p_event->>'eventId')
        || ':funding',
      payment->>'counterfactualId',
      p_event->>'eventId',
      'cooldown_funding',
      payment->>'amountUsdMicros'
    FROM jsonb_array_elements(p_payments) payment
    ON CONFLICT (counterfactual_id, source_event_id, component) DO NOTHING
    RETURNING counterfactual_id, usd_value_micros
  ),
  updated AS (
    UPDATE direct_unstake_counterfactuals c
    SET cooldown_funding_usd_micros = (
          c.cooldown_funding_usd_micros::numeric
          + inserted.usd_value_micros::numeric
        )::text,
        net_usd_micros = (
          c.net_usd_micros::numeric
          + inserted.usd_value_micros::numeric
        )::text,
        updated_at = now()
    FROM inserted
    WHERE c.id = inserted.counterfactual_id
    RETURNING c.id
  )
  SELECT count(*) INTO v_inserted FROM updated;
  RETURN v_inserted;
END;
$$;

INSERT INTO schema_meta(version) VALUES (23);

COMMIT;
