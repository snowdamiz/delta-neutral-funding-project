BEGIN;

CREATE TABLE direct_unstake_counterfactuals (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  state text NOT NULL CHECK (
    state IN (
      'requested', 'deactivating', 'waiting_for_epoch',
      'withdrawable', 'withdrawn', 'failed'
    )
  ),
  requested_epoch bigint NOT NULL CHECK (requested_epoch >= 0),
  available_epoch bigint NOT NULL CHECK (available_epoch = requested_epoch + 1),
  jitosol_quantity_atoms text NOT NULL CHECK (
    jitosol_quantity_atoms ~ '^[1-9][0-9]*$'
  ),
  hedge_quantity_atoms text NOT NULL CHECK (
    hedge_quantity_atoms ~ '^[1-9][0-9]*$'
  ),
  protocol_redemption_lamports text NOT NULL CHECK (
    protocol_redemption_lamports ~ '^[1-9][0-9]*$'
  ),
  withdrawal_fee_lamports text NOT NULL CHECK (
    withdrawal_fee_lamports ~ '^(0|[1-9][0-9]*)$'
  ),
  net_redemption_lamports text NOT NULL CHECK (
    net_redemption_lamports ~ '^[1-9][0-9]*$'
  ),
  protocol_redemption_usd_micros text NOT NULL CHECK (
    protocol_redemption_usd_micros ~ '^[1-9][0-9]*$'
  ),
  withdrawal_fee_usd_micros text NOT NULL CHECK (
    withdrawal_fee_usd_micros ~ '^(0|[1-9][0-9]*)$'
  ),
  cooldown_funding_usd_micros text NOT NULL CHECK (
    cooldown_funding_usd_micros ~ '^-?(0|[1-9][0-9]*)$'
  ),
  chain_fees_usd_micros text NOT NULL CHECK (
    chain_fees_usd_micros ~ '^(0|[1-9][0-9]*)$'
  ),
  hedge_cost_usd_micros text NOT NULL CHECK (
    hedge_cost_usd_micros ~ '^(0|[1-9][0-9]*)$'
  ),
  capital_delay_haircut_usd_micros text NOT NULL CHECK (
    capital_delay_haircut_usd_micros ~ '^(0|[1-9][0-9]*)$'
  ),
  final_hedge_close_cost_usd_micros text NOT NULL CHECK (
    final_hedge_close_cost_usd_micros ~ '^(0|[1-9][0-9]*)$'
  ),
  net_usd_micros text NOT NULL CHECK (
    net_usd_micros ~ '^-?(0|[1-9][0-9]*)$'
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (portfolio_run_id, source_event_id)
);
CREATE INDEX direct_unstake_active
  ON direct_unstake_counterfactuals(state, available_epoch)
  WHERE state NOT IN ('withdrawn', 'failed');

CREATE TABLE direct_unstake_events (
  id text PRIMARY KEY,
  counterfactual_id text NOT NULL
    REFERENCES direct_unstake_counterfactuals(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  state text NOT NULL CHECK (
    state IN (
      'requested', 'deactivating', 'waiting_for_epoch',
      'withdrawable', 'withdrawn', 'failed'
    )
  ),
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (counterfactual_id, source_event_id)
);

CREATE TABLE direct_unstake_ledger_entries (
  id text PRIMARY KEY,
  counterfactual_id text NOT NULL
    REFERENCES direct_unstake_counterfactuals(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  component text NOT NULL CHECK (
    component IN (
      'protocol_redemption', 'withdrawal_fee', 'chain_fees',
      'hedge_cost', 'capital_delay_haircut', 'final_hedge_close_cost',
      'cooldown_funding'
    )
  ),
  usd_value_micros text NOT NULL CHECK (
    usd_value_micros ~ '^-?(0|[1-9][0-9]*)$'
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (counterfactual_id, source_event_id, component)
);

CREATE FUNCTION record_direct_unstake_exit(
  p_portfolio_id text,
  p_source_event_id text,
  p_plan jsonb
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_model jsonb := (p_plan->>'directUnstake')::jsonb;
  v_id text := p_source_event_id || ':' || p_portfolio_id || ':direct-unstake';
  v_inserted integer;
BEGIN
  IF p_plan->>'action' <> 'exit'
     OR p_plan->>'variant' <> 'jitosol_carry' THEN
    RETURN '';
  END IF;
  IF jsonb_typeof(v_model) <> 'object'
     OR COALESCE((v_model->>'enabled')::boolean, false) = false
     OR v_model->>'state' <> 'requested' THEN
    RAISE EXCEPTION 'JitoSOL exit requires a direct unstake model';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM portfolio_runs
    WHERE id = p_portfolio_id
      AND variant = 'jitosol_carry'
      AND execution_mode = 'paper'
  ) OR NOT EXISTS (
    SELECT 1 FROM normalized_events WHERE id = p_source_event_id
  ) THEN
    RAISE EXCEPTION 'direct unstake portfolio or source event is invalid';
  END IF;
  IF (v_model->>'availableEpoch')::bigint
       <> (v_model->>'requestedEpoch')::bigint + 1
     OR (v_model->>'jitosolQuantityAtoms')::numeric <= 0
     OR (v_model->>'hedgeQuantityAtoms')::numeric <= 0
     OR (v_model->>'netRedemptionLamports')::numeric
       <> (v_model->>'protocolRedemptionLamports')::numeric
          - (v_model->>'withdrawalFeeLamports')::numeric
     OR (v_model->>'netUsdMicros')::numeric
       <> (v_model->>'protocolRedemptionUsdMicros')::numeric
          - (v_model->>'withdrawalFeeUsdMicros')::numeric
          + (v_model->>'cooldownFundingUsdMicros')::numeric
          - (v_model->>'chainFeesUsdMicros')::numeric
          - (v_model->>'hedgeCostUsdMicros')::numeric
          - (v_model->>'capitalDelayHaircutUsdMicros')::numeric
          - (v_model->>'finalHedgeCloseCostUsdMicros')::numeric THEN
    RAISE EXCEPTION 'direct unstake projection is inconsistent';
  END IF;

  INSERT INTO direct_unstake_counterfactuals (
    id, portfolio_run_id, source_event_id, state,
    requested_epoch, available_epoch, jitosol_quantity_atoms,
    hedge_quantity_atoms, protocol_redemption_lamports,
    withdrawal_fee_lamports, net_redemption_lamports,
    protocol_redemption_usd_micros, withdrawal_fee_usd_micros,
    cooldown_funding_usd_micros, chain_fees_usd_micros,
    hedge_cost_usd_micros, capital_delay_haircut_usd_micros,
    final_hedge_close_cost_usd_micros, net_usd_micros
  ) VALUES (
    v_id, p_portfolio_id, p_source_event_id, 'requested',
    (v_model->>'requestedEpoch')::bigint,
    (v_model->>'availableEpoch')::bigint,
    v_model->>'jitosolQuantityAtoms',
    v_model->>'hedgeQuantityAtoms',
    v_model->>'protocolRedemptionLamports',
    v_model->>'withdrawalFeeLamports',
    v_model->>'netRedemptionLamports',
    v_model->>'protocolRedemptionUsdMicros',
    v_model->>'withdrawalFeeUsdMicros',
    v_model->>'cooldownFundingUsdMicros',
    v_model->>'chainFeesUsdMicros',
    v_model->>'hedgeCostUsdMicros',
    v_model->>'capitalDelayHaircutUsdMicros',
    v_model->>'finalHedgeCloseCostUsdMicros',
    v_model->>'netUsdMicros'
  )
  ON CONFLICT (id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 AND NOT EXISTS (
    SELECT 1
    FROM direct_unstake_counterfactuals
    WHERE id = v_id
      AND portfolio_run_id = p_portfolio_id
      AND source_event_id = p_source_event_id
      AND jitosol_quantity_atoms = v_model->>'jitosolQuantityAtoms'
      AND hedge_quantity_atoms = v_model->>'hedgeQuantityAtoms'
      AND net_usd_micros = v_model->>'netUsdMicros'
  ) THEN
    RAISE EXCEPTION 'direct unstake identity reused for another projection';
  END IF;

  INSERT INTO direct_unstake_events (
    id, counterfactual_id, source_event_id, state, reason
  ) VALUES (
    v_id || ':requested', v_id, p_source_event_id,
    'requested', 'instant_exit_counterfactual_started'
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO direct_unstake_ledger_entries (
    id, counterfactual_id, source_event_id, component, usd_value_micros
  )
  SELECT
    v_id || ':' || component,
    v_id,
    p_source_event_id,
    component,
    value
  FROM (VALUES
    ('protocol_redemption', v_model->>'protocolRedemptionUsdMicros'),
    ('withdrawal_fee', '-' || (v_model->>'withdrawalFeeUsdMicros')),
    ('chain_fees', '-' || (v_model->>'chainFeesUsdMicros')),
    ('hedge_cost', '-' || (v_model->>'hedgeCostUsdMicros')),
    ('capital_delay_haircut',
      '-' || (v_model->>'capitalDelayHaircutUsdMicros')),
    ('final_hedge_close_cost',
      '-' || (v_model->>'finalHedgeCloseCostUsdMicros'))
  ) AS components(component, value)
  ON CONFLICT (id) DO NOTHING;

  RETURN v_id;
END;
$$;

CREATE FUNCTION advance_direct_unstake_counterfactuals(
  p_source_event_id text,
  p_epoch bigint,
  p_outcome text
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_item record;
  v_next text;
  v_reason text;
  v_inserted integer;
  v_applied integer := 0;
BEGIN
  IF p_epoch < 0
     OR p_outcome NOT IN ('withdraw', 'miss', 'fail')
     OR NOT EXISTS (
       SELECT 1 FROM normalized_events
       WHERE id = p_source_event_id AND event_type = 'MarketSnapshot'
     ) THEN
    RAISE EXCEPTION 'invalid direct unstake advancement';
  END IF;

  FOR v_item IN
    SELECT id, state, available_epoch
    FROM direct_unstake_counterfactuals
    WHERE state NOT IN ('withdrawn', 'failed')
    ORDER BY id
    FOR UPDATE
  LOOP
    v_next := v_item.state;
    v_reason := '';
    IF v_item.state = 'requested' THEN
      v_next := 'deactivating';
      v_reason := 'deactivation_submitted';
    ELSIF v_item.state = 'deactivating' THEN
      v_next := 'waiting_for_epoch';
      v_reason := 'deactivation_confirmed';
    ELSIF v_item.state = 'waiting_for_epoch'
          AND p_epoch >= v_item.available_epoch THEN
      v_next := 'withdrawable';
      v_reason := 'epoch_boundary_crossed';
    ELSIF v_item.state = 'withdrawable' AND p_outcome = 'withdraw' THEN
      v_next := 'withdrawn';
      v_reason := 'withdrawal_completed';
    ELSIF v_item.state = 'withdrawable' AND p_outcome = 'fail' THEN
      v_next := 'failed';
      v_reason := 'withdrawal_failed';
    ELSIF v_item.state = 'withdrawable' AND p_outcome = 'miss'
          AND NOT EXISTS (
            SELECT 1
            FROM direct_unstake_events
            WHERE counterfactual_id = v_item.id
              AND reason = 'missed_withdrawal'
          ) THEN
      v_reason := 'missed_withdrawal';
    END IF;

    IF v_reason <> '' THEN
      INSERT INTO direct_unstake_events (
        id, counterfactual_id, source_event_id, state, reason
      ) VALUES (
        v_item.id || ':' || p_source_event_id,
        v_item.id,
        p_source_event_id,
        v_next,
        v_reason
      )
      ON CONFLICT (counterfactual_id, source_event_id) DO NOTHING;
      GET DIAGNOSTICS v_inserted = ROW_COUNT;
      IF v_inserted = 1 THEN
        UPDATE direct_unstake_counterfactuals
        SET state = v_next,
            updated_at = now()
        WHERE id = v_item.id;
        v_applied := v_applied + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN v_applied;
END;
$$;

CREATE FUNCTION record_direct_unstake_funding(
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
  WHERE payment->>'amountUsdMicros' ~ '^-?(0|[1-9][0-9]*)$';
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

ALTER FUNCTION apply_paper_position_plan(
  text, bigint, text, jsonb, jsonb, character, jsonb, character
) RENAME TO apply_paper_position_plan_v21;

CREATE FUNCTION apply_paper_position_plan(
  p_portfolio_id text,
  p_expected_state_version bigint,
  p_source_event_id text,
  p_plan jsonb,
  p_spot_intent jsonb,
  p_spot_intent_hash char(64),
  p_perp_intent jsonb,
  p_perp_intent_hash char(64)
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_applied boolean;
BEGIN
  v_applied := apply_paper_position_plan_v21(
    p_portfolio_id,
    p_expected_state_version,
    p_source_event_id,
    p_plan,
    p_spot_intent,
    p_spot_intent_hash,
    p_perp_intent,
    p_perp_intent_hash
  );
  IF v_applied THEN
    PERFORM record_direct_unstake_exit(
      p_portfolio_id,
      p_source_event_id,
      p_plan
    );
  END IF;
  RETURN v_applied;
END;
$$;

ALTER FUNCTION apply_funding_settlements(jsonb, jsonb)
  RENAME TO apply_funding_settlements_v21;

CREATE FUNCTION apply_funding_settlements(
  p_event jsonb,
  p_payments jsonb,
  p_direct_unstake_payments jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_result jsonb;
  v_direct integer;
BEGIN
  v_result := apply_funding_settlements_v21(p_event, p_payments);
  v_direct := record_direct_unstake_funding(
    p_event,
    p_direct_unstake_payments
  );
  RETURN v_result || jsonb_build_object(
    'counterfactualPayments',
    v_direct
  );
END;
$$;

CREATE FUNCTION apply_funding_settlements(
  p_event jsonb,
  p_payments jsonb
) RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT apply_funding_settlements(p_event, p_payments, '[]'::jsonb);
$$;

INSERT INTO schema_meta(version) VALUES (22);

COMMIT;
