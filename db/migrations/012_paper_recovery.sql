BEGIN;

ALTER TABLE risk_decisions
  DROP CONSTRAINT risk_decisions_action_check,
  ADD CONSTRAINT risk_decisions_action_check CHECK (
    action IN (
      'skip', 'entry', 'hold', 'rebalance_perp', 'exit', 'emergency',
      'recover'
    )
  );

CREATE FUNCTION apply_paper_recovery_plan(
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
  v_next_state portfolio_state := (p_plan->>'nextState')::portfolio_state;
  v_base text := p_source_event_id || ':' || (p_plan->>'variant') || ':recover';
  v_current_state portfolio_state;
  v_strategy_run_id text;
  v_claimed integer;
  v_final_version bigint := p_expected_state_version;
  v_intent_state_version bigint := p_expected_state_version;
  v_current_spot numeric;
  v_current_perp numeric;
  v_spot_filled numeric := CASE WHEN (p_plan->>'spotPlaced')::boolean
    THEN (p_plan->>'spotFilledQuantityAtoms')::numeric ELSE 0 END;
  v_perp_filled numeric := CASE WHEN (p_plan->>'perpPlaced')::boolean
    THEN (p_plan->>'perpFilledQuantityAtoms')::numeric ELSE 0 END;
BEGIN
  INSERT INTO paper_event_applications (
    portfolio_run_id, source_event_id, action
  ) VALUES (
    p_portfolio_id, p_source_event_id, 'recover'
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN true;
  END IF;

  SELECT state, strategy_run_id
  INTO v_current_state, v_strategy_run_id
  FROM portfolio_runs
  WHERE id = p_portfolio_id
    AND variant = v_variant
    AND state IN ('opening_spot', 'opening_perp', 'emergency_flatten')
    AND state_version = p_expected_state_version
  FOR UPDATE;
  IF NOT FOUND THEN
    DELETE FROM paper_event_applications
    WHERE portfolio_run_id = p_portfolio_id
      AND source_event_id = p_source_event_id;
    RETURN false;
  END IF;

  WITH balances AS (
    SELECT
      COALESCE(sum(CASE
        WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY'
          THEN f.quantity_atoms::numeric
        WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL'
          THEN -f.quantity_atoms::numeric
        ELSE 0
      END), 0) AS spot,
      COALESCE(sum(CASE
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL'
          THEN f.quantity_atoms::numeric
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY'
          THEN -f.quantity_atoms::numeric
        ELSE 0
      END), 0) AS perp
    FROM fills f
    JOIN orders o ON o.id = f.order_id
    JOIN execution_intents ei ON ei.id = o.intent_id
    WHERE f.portfolio_run_id = p_portfolio_id
  )
  SELECT spot, perp INTO v_current_spot, v_current_perp FROM balances;

  IF p_plan->>'action' <> 'recover'
     OR v_next_state NOT IN ('idle', 'emergency_flatten')
     OR (p_plan->>'currentSpotQuantityAtoms')::numeric <> v_current_spot
     OR (p_plan->>'spotRequestedQuantityAtoms')::numeric <> v_current_spot
     OR (p_plan->>'perpRequestedQuantityAtoms')::numeric <> v_current_perp
     OR (p_plan->>'nextSpotQuantityAtoms')::numeric <> v_current_spot - v_spot_filled
     OR (p_plan->>'nextPerpShortQuantityAtoms')::numeric <> v_current_perp - v_perp_filled
     OR v_spot_filled < 0
     OR v_perp_filled < 0
     OR v_spot_filled > v_current_spot
     OR v_perp_filled > v_current_perp THEN
    RAISE EXCEPTION 'paper recovery quantities do not reconcile';
  END IF;
  IF (p_plan->>'perpPlaced')::boolean
     AND p_plan->>'perpSide' <> 'BUY' THEN
    RAISE EXCEPTION 'paper recovery perp must be reduce-only buy';
  END IF;
  IF v_current_perp - v_perp_filled > 0
     AND (p_plan->>'spotPlaced')::boolean THEN
    RAISE EXCEPTION 'paper recovery must close the short before spot';
  END IF;
  IF v_next_state = 'idle'
     AND (v_current_spot - v_spot_filled <> 0
          OR v_current_perp - v_perp_filled <> 0) THEN
    RAISE EXCEPTION 'paper recovery cannot become idle with exposure';
  END IF;
  IF v_next_state = 'emergency_flatten'
     AND v_current_spot - v_spot_filled = 0
     AND v_current_perp - v_perp_filled = 0 THEN
    RAISE EXCEPTION 'flat paper recovery must reconcile to idle';
  END IF;

  IF v_current_state <> 'emergency_flatten' THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version,
      reason, source_event_id
    ) VALUES (
      v_base || ':state:emergency',
      p_portfolio_id,
      v_current_state,
      'emergency_flatten',
      v_final_version + 1,
      'entry_recovery_required',
      p_source_event_id
    );
    v_final_version := v_final_version + 1;
  ELSIF v_next_state = 'emergency_flatten' THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version,
      reason, source_event_id
    ) VALUES (
      v_base || ':state:retry',
      p_portfolio_id,
      'emergency_flatten',
      'emergency_flatten',
      v_final_version + 1,
      p_plan->>'reason',
      p_source_event_id
    );
    v_final_version := v_final_version + 1;
  END IF;
  IF v_next_state = 'idle' THEN
    v_intent_state_version := v_final_version + 1;
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version,
      reason, source_event_id
    ) VALUES (
      v_base || ':state:reconciling',
      p_portfolio_id,
      'emergency_flatten',
      'reconciling',
      v_final_version + 1,
      'recovery_actions_complete',
      p_source_event_id
    ), (
      v_base || ':state:idle',
      p_portfolio_id,
      'reconciling',
      'idle',
      v_final_version + 2,
      p_plan->>'reason',
      p_source_event_id
    );
    v_final_version := v_final_version + 2;
  ELSE
    v_intent_state_version := v_final_version;
  END IF;

  UPDATE portfolio_runs
  SET state = v_next_state,
      state_version = v_final_version,
      random_state = (p_plan->>'nextRandomState')::bigint,
      ended_at = CASE WHEN v_next_state = 'idle' THEN now() ELSE ended_at END
  WHERE id = p_portfolio_id;

  INSERT INTO execution_intents (
    id, portfolio_run_id, execution_mode, variant, state_version,
    operation, leg, intent_json, intent_hash
  )
  SELECT
    v_base || ':spot:intent', p_portfolio_id, 'paper'::execution_mode, v_variant,
    v_intent_state_version, 'CLOSE', 'SPOT', p_spot_intent, p_spot_intent_hash
  WHERE (p_plan->>'spotPlaced')::boolean
  UNION ALL
  SELECT
    v_base || ':perp:intent', p_portfolio_id, 'paper'::execution_mode, v_variant,
    v_intent_state_version, 'CLOSE', 'PERP', p_perp_intent, p_perp_intent_hash
  WHERE (p_plan->>'perpPlaced')::boolean;

  INSERT INTO orders (
    id, intent_id, portfolio_run_id, execution_mode, variant, status,
    requested_quantity_atoms, filled_quantity_atoms
  )
  SELECT
    v_base || ':spot:order', v_base || ':spot:intent', p_portfolio_id,
    'paper'::execution_mode, v_variant, p_plan->>'spotStatus',
    p_plan->>'spotRequestedQuantityAtoms', p_plan->>'spotFilledQuantityAtoms'
  WHERE (p_plan->>'spotPlaced')::boolean
  UNION ALL
  SELECT
    v_base || ':perp:order', v_base || ':perp:intent', p_portfolio_id,
    'paper'::execution_mode, v_variant, p_plan->>'perpStatus',
    p_plan->>'perpRequestedQuantityAtoms', p_plan->>'perpFilledQuantityAtoms'
  WHERE (p_plan->>'perpPlaced')::boolean;

  INSERT INTO outbox_commands (
    id, portfolio_run_id, intent_id, command_type, payload,
    status, attempts, processed_at
  )
  SELECT
    v_base || ':spot:command', p_portfolio_id, v_base || ':spot:intent',
    'paper_order', p_spot_intent, 'processed', 1, now()
  WHERE (p_plan->>'spotPlaced')::boolean
  UNION ALL
  SELECT
    v_base || ':perp:command', p_portfolio_id, v_base || ':perp:intent',
    'paper_order', p_perp_intent, 'processed', 1, now()
  WHERE (p_plan->>'perpPlaced')::boolean;

  INSERT INTO fills (
    id, order_id, portfolio_run_id, execution_mode, variant,
    quantity_atoms, price_atoms, fee_atoms, source_snapshot_id, explanation
  )
  SELECT
    v_base || ':spot:fill', v_base || ':spot:order', p_portfolio_id,
    'paper'::execution_mode, v_variant, p_plan->>'spotFilledQuantityAtoms',
    p_plan->>'spotPriceAtoms', p_plan->>'spotFeeUsdAtoms',
    p_source_event_id, jsonb_build_object('model', 'deterministic-paper-v1', 'action', 'recover')
  WHERE (p_plan->>'spotPlaced')::boolean AND v_spot_filled > 0
  UNION ALL
  SELECT
    v_base || ':perp:fill', v_base || ':perp:order', p_portfolio_id,
    'paper'::execution_mode, v_variant, p_plan->>'perpFilledQuantityAtoms',
    p_plan->>'perpPriceAtoms', p_plan->>'perpFeeUsdAtoms',
    p_source_event_id, jsonb_build_object('model', 'deterministic-paper-v1', 'action', 'recover')
  WHERE (p_plan->>'perpPlaced')::boolean AND v_perp_filled > 0;

  INSERT INTO ledger_batches (
    id, portfolio_run_id, event_type, event_id, batch_hash
  )
  SELECT
    v_base || ':spot:ledger', p_portfolio_id, 'recover_spot_fill',
    v_base || ':spot:fill', p_spot_intent_hash
  WHERE (p_plan->>'spotPlaced')::boolean AND v_spot_filled > 0
  UNION ALL
  SELECT
    v_base || ':perp:ledger', p_portfolio_id, 'recover_perp_fill',
    v_base || ':perp:fill', p_perp_intent_hash
  WHERE (p_plan->>'perpPlaced')::boolean AND v_perp_filled > 0;

  INSERT INTO ledger_entries (
    ledger_batch_id, account_debit, account_credit, asset,
    amount_atoms, usd_value_atoms, price_reference_id
  )
  SELECT
    v_base || ':spot:ledger', 'paper_cash', 'spot_inventory',
    p_plan->>'spotAsset', p_plan->>'spotFilledQuantityAtoms',
    p_plan->>'spotGrossUsdAtoms', p_source_event_id
  WHERE (p_plan->>'spotPlaced')::boolean AND v_spot_filled > 0
  UNION ALL
  SELECT
    v_base || ':perp:ledger', 'perp_short_liability', 'paper_cash',
    'PERP-SOL', p_plan->>'perpFilledQuantityAtoms',
    p_plan->>'perpGrossUsdAtoms', p_source_event_id
  WHERE (p_plan->>'perpPlaced')::boolean AND v_perp_filled > 0;

  INSERT INTO ledger_entries (
    ledger_batch_id, account_debit, account_credit, asset,
    amount_atoms, usd_value_atoms, price_reference_id
  )
  SELECT
    v_base || ':spot:ledger', 'trading_fees', 'paper_cash',
    'USDC', p_plan->>'spotFeeUsdAtoms', p_plan->>'spotFeeUsdAtoms',
    p_source_event_id
  WHERE (p_plan->>'spotPlaced')::boolean
    AND v_spot_filled > 0
    AND (p_plan->>'spotFeeUsdAtoms')::numeric > 0
  UNION ALL
  SELECT
    v_base || ':perp:ledger', 'trading_fees', 'paper_cash',
    'USDC', p_plan->>'perpFeeUsdAtoms', p_plan->>'perpFeeUsdAtoms',
    p_source_event_id
  WHERE (p_plan->>'perpPlaced')::boolean
    AND v_perp_filled > 0
    AND (p_plan->>'perpFeeUsdAtoms')::numeric > 0;

  INSERT INTO valuation_events (
    id, portfolio_run_id, source_event_id, quantity_atoms,
    protocol_nav_rate_atoms, market_sell_rate_atoms,
    reward_accrual_sol_atoms, basis_change_sol_atoms,
    reward_accrual_usd_atoms, basis_change_usd_atoms
  ) VALUES (
    v_base || ':valuation', p_portfolio_id, p_source_event_id,
    p_plan->>'currentSpotQuantityAtoms',
    p_plan->>'protocolNavLamports',
    p_plan->>'marketRateLamports',
    p_plan->>'rewardSolLamports',
    p_plan->>'basisSolLamports',
    p_plan->>'rewardUsdMicros',
    p_plan->>'basisUsdMicros'
  );

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

  IF v_next_state = 'idle' THEN
    UPDATE risk_events
    SET resolved_at = now()
    WHERE portfolio_run_id = p_portfolio_id
      AND resolved_at IS NULL;
  ELSE
    INSERT INTO risk_events (
      id, strategy_run_id, portfolio_run_id, severity, code, message,
      observed_value, limit_value, action_taken
    ) VALUES (
      v_base || ':risk', v_strategy_run_id, p_portfolio_id, 'critical',
      p_plan->>'reason', 'paper recovery remains incomplete',
      jsonb_build_object(
        'spotQuantityAtoms', p_plan->>'nextSpotQuantityAtoms',
        'perpShortQuantityAtoms', p_plan->>'nextPerpShortQuantityAtoms'
      ),
      jsonb_build_object('requiredSpotAtoms', '0', 'requiredPerpAtoms', '0'),
      'retry_recovery'
    );
  END IF;

  RETURN true;
END;
$$;

INSERT INTO schema_meta(version) VALUES (12);

COMMIT;
