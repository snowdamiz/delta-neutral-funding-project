BEGIN;

CREATE TABLE paper_event_applications (
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  action text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (portfolio_run_id, source_event_id)
);

CREATE TABLE position_snapshots (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  spot_asset text NOT NULL CHECK (spot_asset IN ('SOL', 'JitoSOL')),
  spot_quantity_atoms text NOT NULL CHECK (spot_quantity_atoms ~ '^(0|[1-9][0-9]*)$'),
  spot_equivalent_sol_atoms text NOT NULL CHECK (spot_equivalent_sol_atoms ~ '^(0|[1-9][0-9]*)$'),
  perp_short_quantity_atoms text NOT NULL CHECK (perp_short_quantity_atoms ~ '^(0|[1-9][0-9]*)$'),
  net_delta_sol_atoms text NOT NULL CHECK (net_delta_sol_atoms ~ '^-?(0|[1-9][0-9]*)$'),
  delta_bps bigint NOT NULL CHECK (delta_bps >= 0),
  protocol_nav_rate_atoms text NOT NULL CHECK (protocol_nav_rate_atoms ~ '^[1-9][0-9]*$'),
  market_sell_rate_atoms text NOT NULL CHECK (market_sell_rate_atoms ~ '^[1-9][0-9]*$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (portfolio_run_id, source_event_id)
);
CREATE INDEX position_snapshots_latest
  ON position_snapshots(portfolio_run_id, observed_at_ms DESC);

ALTER FUNCTION apply_paper_plan(
  text, bigint, text, jsonb, jsonb, character, jsonb, character
) RENAME TO apply_paper_entry_plan;

CREATE FUNCTION apply_paper_plan(
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
  v_claimed integer;
  v_applied boolean;
BEGIN
  INSERT INTO paper_event_applications (
    portfolio_run_id, source_event_id, action
  ) VALUES (
    p_portfolio_id, p_source_event_id, 'entry'
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;

  IF v_claimed = 0 THEN
    RETURN true;
  END IF;

  v_applied := apply_paper_entry_plan(
    p_portfolio_id,
    p_expected_state_version,
    p_source_event_id,
    p_plan,
    p_spot_intent,
    p_spot_intent_hash,
    p_perp_intent,
    p_perp_intent_hash
  );

  IF NOT v_applied THEN
    DELETE FROM paper_event_applications
    WHERE portfolio_run_id = p_portfolio_id
      AND source_event_id = p_source_event_id;
  END IF;

  RETURN v_applied;
END;
$$;

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
  v_variant strategy_variant := (p_plan->>'variant')::strategy_variant;
  v_action text := p_plan->>'action';
  v_reason text := p_plan->>'reason';
  v_next_state portfolio_state := (p_plan->>'nextState')::portfolio_state;
  v_base text := p_source_event_id || ':' || (p_plan->>'variant') || ':' || v_action;
  v_claimed integer;
  v_strategy_run_id text;
  v_final_version bigint := p_expected_state_version;
BEGIN
  INSERT INTO paper_event_applications (
    portfolio_run_id, source_event_id, action
  ) VALUES (
    p_portfolio_id, p_source_event_id, v_action
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;

  IF v_claimed = 0 THEN
    RETURN true;
  END IF;

  SELECT strategy_run_id
  INTO v_strategy_run_id
  FROM portfolio_runs
  WHERE id = p_portfolio_id
    AND variant = v_variant
    AND state = 'hedged'
    AND state_version = p_expected_state_version
  FOR UPDATE;

  IF NOT FOUND THEN
    DELETE FROM paper_event_applications
    WHERE portfolio_run_id = p_portfolio_id
      AND source_event_id = p_source_event_id;
    RETURN false;
  END IF;

  IF v_action NOT IN ('hold', 'rebalance_perp', 'exit', 'emergency') THEN
    RAISE EXCEPTION 'unsupported paper position action %', v_action;
  END IF;
  IF v_action = 'hold' AND v_next_state <> 'hedged' THEN
    RAISE EXCEPTION 'hold must remain hedged';
  END IF;
  IF v_action = 'rebalance_perp'
     AND NOT ((p_plan->>'perpPlaced')::boolean
              AND p_plan->>'perpStatus' = 'filled'
              AND v_next_state = 'hedged') THEN
    RAISE EXCEPTION 'rebalance requires a full perp fill';
  END IF;
  IF v_action = 'exit'
     AND NOT ((p_plan->>'perpPlaced')::boolean
              AND p_plan->>'perpStatus' = 'filled'
              AND (p_plan->>'spotPlaced')::boolean
              AND p_plan->>'spotStatus' = 'filled'
              AND v_next_state = 'idle') THEN
    RAISE EXCEPTION 'exit requires full perp and spot fills';
  END IF;
  IF v_action = 'emergency' AND v_next_state <> 'emergency_flatten' THEN
    RAISE EXCEPTION 'emergency action must fail closed';
  END IF;

  INSERT INTO valuation_events (
    id, portfolio_run_id, source_event_id, quantity_atoms,
    protocol_nav_rate_atoms, market_sell_rate_atoms,
    reward_accrual_sol_atoms, basis_change_sol_atoms,
    reward_accrual_usd_atoms, basis_change_usd_atoms
  ) VALUES (
    v_base || ':valuation',
    p_portfolio_id,
    p_source_event_id,
    p_plan->>'currentSpotQuantityAtoms',
    p_plan->>'protocolNavLamports',
    p_plan->>'marketRateLamports',
    p_plan->>'rewardSolLamports',
    p_plan->>'basisSolLamports',
    p_plan->>'rewardUsdMicros',
    p_plan->>'basisUsdMicros'
  );

  IF v_action = 'rebalance_perp' THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version,
      reason, source_event_id
    ) VALUES (
      v_base || ':state:1', p_portfolio_id, 'hedged', 'rebalancing',
      p_expected_state_version + 1, 'delta_breached', p_source_event_id
    ), (
      v_base || ':state:2', p_portfolio_id, 'rebalancing', 'hedged',
      p_expected_state_version + 2, v_reason, p_source_event_id
    );
    v_final_version := p_expected_state_version + 2;
  ELSIF v_action = 'exit' THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version,
      reason, source_event_id
    ) VALUES (
      v_base || ':state:1', p_portfolio_id, 'hedged', 'exiting_perp',
      p_expected_state_version + 1, v_reason, p_source_event_id
    ), (
      v_base || ':state:2', p_portfolio_id, 'exiting_perp', 'exiting_spot',
      p_expected_state_version + 2, 'perp_closed', p_source_event_id
    ), (
      v_base || ':state:3', p_portfolio_id, 'exiting_spot', 'idle',
      p_expected_state_version + 3, 'spot_closed', p_source_event_id
    );
    v_final_version := p_expected_state_version + 3;
  ELSIF v_action = 'emergency' THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version,
      reason, source_event_id
    ) VALUES (
      v_base || ':state:1', p_portfolio_id, 'hedged', 'emergency_flatten',
      p_expected_state_version + 1, v_reason, p_source_event_id
    );
    v_final_version := p_expected_state_version + 1;
  END IF;

  IF v_action <> 'hold' THEN
    UPDATE portfolio_runs
    SET state = v_next_state,
        state_version = v_final_version,
        random_state = (p_plan->>'nextRandomState')::bigint,
        ended_at = CASE WHEN v_next_state = 'idle' THEN now() ELSE ended_at END
    WHERE id = p_portfolio_id;
  END IF;

  INSERT INTO execution_intents (
    id, portfolio_run_id, execution_mode, variant, state_version,
    operation, leg, intent_json, intent_hash
  )
  SELECT
    v_base || ':spot:intent',
    p_portfolio_id,
    'paper'::execution_mode,
    v_variant,
    p_expected_state_version + CASE WHEN v_action = 'exit' THEN 2 ELSE 1 END,
    CASE
      WHEN v_action = 'exit' THEN 'CLOSE'
      WHEN v_action = 'emergency' THEN 'EMERGENCY_FLATTEN'
      ELSE 'REBALANCE'
    END,
    'SPOT',
    p_spot_intent,
    p_spot_intent_hash
  WHERE (p_plan->>'spotPlaced')::boolean
  UNION ALL
  SELECT
    v_base || ':perp:intent',
    p_portfolio_id,
    'paper'::execution_mode,
    v_variant,
    p_expected_state_version + 1,
    CASE
      WHEN v_action = 'exit' THEN 'CLOSE'
      WHEN v_action = 'emergency' THEN 'EMERGENCY_FLATTEN'
      ELSE 'REBALANCE'
    END,
    'PERP',
    p_perp_intent,
    p_perp_intent_hash
  WHERE (p_plan->>'perpPlaced')::boolean;

  INSERT INTO orders (
    id, intent_id, portfolio_run_id, execution_mode, variant, status,
    requested_quantity_atoms, filled_quantity_atoms
  )
  SELECT
    v_base || ':spot:order',
    v_base || ':spot:intent',
    p_portfolio_id,
    'paper'::execution_mode,
    v_variant,
    p_plan->>'spotStatus',
    p_plan->>'spotRequestedQuantityAtoms',
    p_plan->>'spotFilledQuantityAtoms'
  WHERE (p_plan->>'spotPlaced')::boolean
  UNION ALL
  SELECT
    v_base || ':perp:order',
    v_base || ':perp:intent',
    p_portfolio_id,
    'paper'::execution_mode,
    v_variant,
    p_plan->>'perpStatus',
    p_plan->>'perpRequestedQuantityAtoms',
    p_plan->>'perpFilledQuantityAtoms'
  WHERE (p_plan->>'perpPlaced')::boolean;

  INSERT INTO outbox_commands (
    id, portfolio_run_id, intent_id, command_type, payload,
    status, attempts, processed_at
  )
  SELECT
    v_base || ':spot:command',
    p_portfolio_id,
    v_base || ':spot:intent',
    'paper_order',
    p_spot_intent,
    'processed',
    1,
    now()
  WHERE (p_plan->>'spotPlaced')::boolean
  UNION ALL
  SELECT
    v_base || ':perp:command',
    p_portfolio_id,
    v_base || ':perp:intent',
    'paper_order',
    p_perp_intent,
    'processed',
    1,
    now()
  WHERE (p_plan->>'perpPlaced')::boolean;

  INSERT INTO fills (
    id, order_id, portfolio_run_id, execution_mode, variant,
    quantity_atoms, price_atoms, fee_atoms, source_snapshot_id, explanation
  )
  SELECT
    v_base || ':spot:fill',
    v_base || ':spot:order',
    p_portfolio_id,
    'paper'::execution_mode,
    v_variant,
    p_plan->>'spotFilledQuantityAtoms',
    p_plan->>'spotPriceAtoms',
    p_plan->>'spotFeeUsdAtoms',
    p_source_event_id,
    jsonb_build_object('model', 'deterministic-paper-v1', 'action', v_action)
  WHERE (p_plan->>'spotPlaced')::boolean
    AND (p_plan->>'spotFilledQuantityAtoms')::numeric > 0
  UNION ALL
  SELECT
    v_base || ':perp:fill',
    v_base || ':perp:order',
    p_portfolio_id,
    'paper'::execution_mode,
    v_variant,
    p_plan->>'perpFilledQuantityAtoms',
    p_plan->>'perpPriceAtoms',
    p_plan->>'perpFeeUsdAtoms',
    p_source_event_id,
    jsonb_build_object('model', 'deterministic-paper-v1', 'action', v_action)
  WHERE (p_plan->>'perpPlaced')::boolean
    AND (p_plan->>'perpFilledQuantityAtoms')::numeric > 0;

  INSERT INTO ledger_batches (
    id, portfolio_run_id, event_type, event_id, batch_hash
  )
  SELECT
    v_base || ':spot:ledger',
    p_portfolio_id,
    v_action || '_spot_fill',
    v_base || ':spot:fill',
    p_spot_intent_hash
  WHERE (p_plan->>'spotPlaced')::boolean
    AND (p_plan->>'spotFilledQuantityAtoms')::numeric > 0
  UNION ALL
  SELECT
    v_base || ':perp:ledger',
    p_portfolio_id,
    v_action || '_perp_fill',
    v_base || ':perp:fill',
    p_perp_intent_hash
  WHERE (p_plan->>'perpPlaced')::boolean
    AND (p_plan->>'perpFilledQuantityAtoms')::numeric > 0;

  INSERT INTO ledger_entries (
    ledger_batch_id, account_debit, account_credit, asset,
    amount_atoms, usd_value_atoms, price_reference_id
  )
  SELECT
    v_base || ':spot:ledger',
    'paper_cash',
    'spot_inventory',
    p_plan->>'spotAsset',
    p_plan->>'spotFilledQuantityAtoms',
    p_plan->>'spotGrossUsdAtoms',
    p_source_event_id
  WHERE (p_plan->>'spotPlaced')::boolean
    AND (p_plan->>'spotFilledQuantityAtoms')::numeric > 0
  UNION ALL
  SELECT
    v_base || ':perp:ledger',
    CASE WHEN p_plan->>'perpSide' = 'SELL'
      THEN 'paper_cash' ELSE 'perp_short_liability' END,
    CASE WHEN p_plan->>'perpSide' = 'SELL'
      THEN 'perp_short_liability' ELSE 'paper_cash' END,
    'PERP-SOL',
    p_plan->>'perpFilledQuantityAtoms',
    p_plan->>'perpGrossUsdAtoms',
    p_source_event_id
  WHERE (p_plan->>'perpPlaced')::boolean
    AND (p_plan->>'perpFilledQuantityAtoms')::numeric > 0;

  INSERT INTO ledger_entries (
    ledger_batch_id, account_debit, account_credit, asset,
    amount_atoms, usd_value_atoms, price_reference_id
  )
  SELECT
    v_base || ':spot:ledger',
    'trading_fees',
    'paper_cash',
    'USDC',
    p_plan->>'spotFeeUsdAtoms',
    p_plan->>'spotFeeUsdAtoms',
    p_source_event_id
  WHERE (p_plan->>'spotPlaced')::boolean
    AND (p_plan->>'spotFilledQuantityAtoms')::numeric > 0
    AND (p_plan->>'spotFeeUsdAtoms')::numeric > 0
  UNION ALL
  SELECT
    v_base || ':perp:ledger',
    'trading_fees',
    'paper_cash',
    'USDC',
    p_plan->>'perpFeeUsdAtoms',
    p_plan->>'perpFeeUsdAtoms',
    p_source_event_id
  WHERE (p_plan->>'perpPlaced')::boolean
    AND (p_plan->>'perpFilledQuantityAtoms')::numeric > 0
    AND (p_plan->>'perpFeeUsdAtoms')::numeric > 0;

  INSERT INTO position_snapshots (
    id, portfolio_run_id, source_event_id, observed_at_ms, spot_asset,
    spot_quantity_atoms, spot_equivalent_sol_atoms,
    perp_short_quantity_atoms, net_delta_sol_atoms, delta_bps,
    protocol_nav_rate_atoms, market_sell_rate_atoms
  )
  WITH next_position AS (
    SELECT
      trunc(
        (p_plan->>'nextSpotQuantityAtoms')::numeric
        * (p_plan->>'marketRateLamports')::numeric
        / 1000000000
      ) AS spot_equivalent,
      (p_plan->>'nextPerpShortQuantityAtoms')::numeric AS perp_short
  )
  SELECT
    v_base || ':position',
    p_portfolio_id,
    p_source_event_id,
    (p_plan->>'observedAtMs')::bigint,
    p_plan->>'spotAsset',
    p_plan->>'nextSpotQuantityAtoms',
    spot_equivalent::text,
    perp_short::text,
    (spot_equivalent - perp_short)::text,
    CASE WHEN spot_equivalent = 0 THEN 0
      ELSE ceil(abs(spot_equivalent - perp_short) * 10000 / spot_equivalent)::bigint
    END,
    p_plan->>'protocolNavLamports',
    p_plan->>'marketRateLamports'
  FROM next_position;

  IF v_action = 'emergency' THEN
    INSERT INTO risk_events (
      id, strategy_run_id, portfolio_run_id, severity, code, message,
      observed_value, limit_value, action_taken
    ) VALUES (
      v_base || ':risk',
      v_strategy_run_id,
      p_portfolio_id,
      'critical',
      v_reason,
      'paper position action failed closed',
      p_plan,
      jsonb_build_object('requiredState', 'hedged'),
      'emergency_flatten'
    );
  END IF;

  RETURN true;
END;
$$;

INSERT INTO schema_meta(version) VALUES (5);

COMMIT;
