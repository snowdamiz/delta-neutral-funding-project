BEGIN;

ALTER TABLE execution_intents
  ADD CONSTRAINT execution_intents_portfolio_version_leg_unique
  UNIQUE (portfolio_run_id, state_version, leg);

ALTER TABLE orders
  ADD CONSTRAINT orders_intent_unique UNIQUE (intent_id),
  ADD CONSTRAINT orders_quantities_canonical CHECK (
    requested_quantity_atoms ~ '^(0|[1-9][0-9]*)$'
    AND filled_quantity_atoms ~ '^(0|[1-9][0-9]*)$'
  );

ALTER TABLE fills
  ADD CONSTRAINT fills_amounts_canonical CHECK (
    quantity_atoms ~ '^[1-9][0-9]*$'
    AND price_atoms ~ '^[1-9][0-9]*$'
    AND fee_atoms ~ '^(0|[1-9][0-9]*)$'
  );

CREATE OR REPLACE FUNCTION apply_paper_plan(
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
  v_outcome text := p_plan->>'outcome';
  v_reason text := p_plan->>'reason';
  v_next_state portfolio_state := (p_plan->>'nextState')::portfolio_state;
  v_next_random_state bigint := (p_plan->>'nextRandomState')::bigint;
  v_base text := p_source_event_id || ':' || (p_plan->>'variant');
  v_spot_placed boolean := (p_plan->>'spotPlaced')::boolean;
  v_spot_status text := p_plan->>'spotStatus';
  v_spot_full boolean := (p_plan->>'spotStatus') = 'filled';
  v_perp_placed boolean := (p_plan->>'perpPlaced')::boolean;
  v_perp_status text := p_plan->>'perpStatus';
  v_perp_full boolean := (p_plan->>'perpStatus') = 'filled';
  v_final_version bigint;
  v_strategy_run_id text;
BEGIN
  IF v_outcome = 'skipped' THEN
    RETURN true;
  END IF;

  SELECT strategy_run_id
  INTO v_strategy_run_id
  FROM portfolio_runs
  WHERE id = p_portfolio_id
    AND state = 'idle'
    AND state_version = p_expected_state_version
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_outcome NOT IN ('hedged', 'partial', 'rejected', 'unknown') THEN
    RAISE EXCEPTION 'unsupported paper plan outcome %', v_outcome;
  END IF;
  IF v_next_state = 'hedged'
     AND NOT (v_spot_placed AND v_spot_full AND v_perp_placed AND v_perp_full) THEN
    RAISE EXCEPTION 'hedged paper plan requires two full fills';
  END IF;
  IF v_next_state = 'opening_perp' AND NOT (v_spot_placed AND v_spot_full) THEN
    RAISE EXCEPTION 'opening_perp paper plan requires a full spot fill';
  END IF;
  IF v_next_state NOT IN ('opening_spot', 'opening_perp', 'hedged', 'emergency_flatten') THEN
    RAISE EXCEPTION 'unsupported paper plan target state %', v_next_state;
  END IF;

  INSERT INTO state_transitions (
    id, portfolio_run_id, from_state, to_state, state_version, reason, source_event_id
  ) VALUES (
    v_base || ':state:1', p_portfolio_id, 'idle', 'candidate',
    p_expected_state_version + 1, 'opportunity_found', p_source_event_id
  ), (
    v_base || ':state:2', p_portfolio_id, 'candidate', 'opening_spot',
    p_expected_state_version + 2, 'entry_approved', p_source_event_id
  );

  IF v_spot_full THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version, reason, source_event_id
    ) VALUES (
      v_base || ':state:3', p_portfolio_id, 'opening_spot', 'opening_perp',
      p_expected_state_version + 3, 'spot_filled', p_source_event_id
    );
  END IF;

  IF v_next_state = 'hedged' THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version, reason, source_event_id
    ) VALUES (
      v_base || ':state:4', p_portfolio_id, 'opening_perp', 'hedged',
      p_expected_state_version + 4, v_reason, p_source_event_id
    );
  ELSIF v_next_state = 'emergency_flatten' THEN
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version, reason, source_event_id
    ) VALUES (
      v_base || ':state:emergency',
      p_portfolio_id,
      CASE WHEN v_spot_full THEN 'opening_perp' ELSE 'opening_spot' END::portfolio_state,
      'emergency_flatten',
      p_expected_state_version + CASE WHEN v_spot_full THEN 4 ELSE 3 END,
      v_reason,
      p_source_event_id
    );
  END IF;

  v_final_version := p_expected_state_version + CASE v_next_state
    WHEN 'opening_spot' THEN 2
    WHEN 'opening_perp' THEN 3
    WHEN 'hedged' THEN 4
    WHEN 'emergency_flatten' THEN CASE WHEN v_spot_full THEN 4 ELSE 3 END
  END;

  UPDATE portfolio_runs
  SET state = v_next_state,
      state_version = v_final_version,
      random_state = v_next_random_state
  WHERE id = p_portfolio_id;

  IF v_spot_placed THEN
    INSERT INTO execution_intents (
      id, portfolio_run_id, execution_mode, variant, state_version,
      operation, leg, intent_json, intent_hash
    ) VALUES (
      v_base || ':spot:intent', p_portfolio_id, 'paper', v_variant,
      p_expected_state_version + 2, 'OPEN', 'SPOT', p_spot_intent, p_spot_intent_hash
    );

    INSERT INTO orders (
      id, intent_id, portfolio_run_id, execution_mode, variant, status,
      requested_quantity_atoms, filled_quantity_atoms
    ) VALUES (
      v_base || ':spot:order', v_base || ':spot:intent', p_portfolio_id,
      'paper', v_variant, v_spot_status,
      p_plan->>'spotRequestedQuantityAtoms', p_plan->>'spotFilledQuantityAtoms'
    );

    INSERT INTO outbox_commands (
      id, portfolio_run_id, intent_id, command_type, payload,
      status, attempts, processed_at
    ) VALUES (
      v_base || ':spot:command', p_portfolio_id, v_base || ':spot:intent',
      'paper_order', p_spot_intent, 'processed', 1, now()
    );
  END IF;

  IF v_spot_placed AND (p_plan->>'spotFilledQuantityAtoms')::numeric > 0 THEN
    INSERT INTO fills (
      id, order_id, portfolio_run_id, execution_mode, variant,
      quantity_atoms, price_atoms, fee_atoms, source_snapshot_id, explanation
    ) VALUES (
      v_base || ':spot:fill', v_base || ':spot:order', p_portfolio_id,
      'paper', v_variant, p_plan->>'spotFilledQuantityAtoms',
      p_plan->>'spotPriceAtoms', p_plan->>'spotFeeUsdAtoms',
      p_source_event_id, jsonb_build_object('model', 'deterministic-paper-v1')
    );

    INSERT INTO ledger_batches (
      id, portfolio_run_id, event_type, event_id, batch_hash
    ) VALUES (
      v_base || ':spot:ledger', p_portfolio_id, 'spot_fill',
      v_base || ':spot:fill', p_spot_intent_hash
    );

    INSERT INTO ledger_entries (
      ledger_batch_id, account_debit, account_credit, asset,
      amount_atoms, usd_value_atoms, price_reference_id
    ) VALUES (
      v_base || ':spot:ledger', 'spot_inventory', 'paper_cash',
      p_plan->>'spotAsset', p_plan->>'spotFilledQuantityAtoms',
      p_plan->>'spotGrossUsdAtoms', p_source_event_id
    );

    INSERT INTO ledger_entries (
      ledger_batch_id, account_debit, account_credit, asset,
      amount_atoms, usd_value_atoms, price_reference_id
    )
    SELECT v_base || ':spot:ledger', 'trading_fees', 'paper_cash', 'USDC',
      p_plan->>'spotFeeUsdAtoms', p_plan->>'spotFeeUsdAtoms', p_source_event_id
    WHERE (p_plan->>'spotFeeUsdAtoms')::numeric > 0;
  END IF;

  IF v_perp_placed THEN
    INSERT INTO execution_intents (
      id, portfolio_run_id, execution_mode, variant, state_version,
      operation, leg, intent_json, intent_hash
    ) VALUES (
      v_base || ':perp:intent', p_portfolio_id, 'paper', v_variant,
      p_expected_state_version + 3, 'OPEN', 'PERP', p_perp_intent, p_perp_intent_hash
    );

    INSERT INTO orders (
      id, intent_id, portfolio_run_id, execution_mode, variant, status,
      requested_quantity_atoms, filled_quantity_atoms
    ) VALUES (
      v_base || ':perp:order', v_base || ':perp:intent', p_portfolio_id,
      'paper', v_variant, v_perp_status,
      p_plan->>'perpRequestedQuantityAtoms', p_plan->>'perpFilledQuantityAtoms'
    );

    INSERT INTO outbox_commands (
      id, portfolio_run_id, intent_id, command_type, payload,
      status, attempts, processed_at
    ) VALUES (
      v_base || ':perp:command', p_portfolio_id, v_base || ':perp:intent',
      'paper_order', p_perp_intent, 'processed', 1, now()
    );
  END IF;

  IF v_perp_placed AND (p_plan->>'perpFilledQuantityAtoms')::numeric > 0 THEN
    INSERT INTO fills (
      id, order_id, portfolio_run_id, execution_mode, variant,
      quantity_atoms, price_atoms, fee_atoms, source_snapshot_id, explanation
    ) VALUES (
      v_base || ':perp:fill', v_base || ':perp:order', p_portfolio_id,
      'paper', v_variant, p_plan->>'perpFilledQuantityAtoms',
      p_plan->>'perpPriceAtoms', p_plan->>'perpFeeUsdAtoms',
      p_source_event_id, jsonb_build_object('model', 'deterministic-paper-v1')
    );

    INSERT INTO ledger_batches (
      id, portfolio_run_id, event_type, event_id, batch_hash
    ) VALUES (
      v_base || ':perp:ledger', p_portfolio_id, 'perp_fill',
      v_base || ':perp:fill', p_perp_intent_hash
    );

    INSERT INTO ledger_entries (
      ledger_batch_id, account_debit, account_credit, asset,
      amount_atoms, usd_value_atoms, price_reference_id
    ) VALUES (
      v_base || ':perp:ledger', 'paper_cash', 'perp_short_liability',
      'PERP-SOL', p_plan->>'perpFilledQuantityAtoms',
      p_plan->>'perpGrossUsdAtoms', p_source_event_id
    );

    INSERT INTO ledger_entries (
      ledger_batch_id, account_debit, account_credit, asset,
      amount_atoms, usd_value_atoms, price_reference_id
    )
    SELECT v_base || ':perp:ledger', 'trading_fees', 'paper_cash', 'USDC',
      p_plan->>'perpFeeUsdAtoms', p_plan->>'perpFeeUsdAtoms', p_source_event_id
    WHERE (p_plan->>'perpFeeUsdAtoms')::numeric > 0;
  END IF;

  IF v_next_state = 'emergency_flatten' THEN
    INSERT INTO risk_events (
      id, strategy_run_id, portfolio_run_id, severity, code, message,
      observed_value, limit_value, action_taken
    ) VALUES (
      v_base || ':risk', v_strategy_run_id, p_portfolio_id, 'critical',
      v_reason, 'paper entry failed closed', p_plan,
      jsonb_build_object('requiredState', 'hedged'), 'emergency_flatten'
    );
  END IF;

  RETURN true;
END;
$$;

INSERT INTO schema_meta(version) VALUES (4);

COMMIT;
