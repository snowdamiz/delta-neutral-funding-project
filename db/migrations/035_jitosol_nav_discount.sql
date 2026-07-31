BEGIN;

ALTER TYPE strategy_variant
  ADD VALUE IF NOT EXISTS 'jitosol_nav_discount';

CREATE TABLE nav_discount_paper_positions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  status text NOT NULL CHECK (status IN ('open', 'exit_blocked', 'closed')),
  exit_route text NOT NULL CHECK (exit_route IN ('direct', 'instant')),
  quantity_atoms numeric(78, 0) NOT NULL CHECK (quantity_atoms > 0),
  hedge_quantity_atoms numeric(78, 0) NOT NULL
    CHECK (hedge_quantity_atoms > 0),
  protocol_nav_lamports bigint NOT NULL CHECK (protocol_nav_lamports > 0),
  entry_ask_usd_micros bigint NOT NULL CHECK (entry_ask_usd_micros > 0),
  instant_bid_usd_micros bigint NOT NULL CHECK (instant_bid_usd_micros > 0),
  acquisition_cost_usd_micros bigint NOT NULL
    CHECK (acquisition_cost_usd_micros > 0),
  paper_cost_usd_micros bigint NOT NULL
    CHECK (paper_cost_usd_micros >= 0),
  projected_funding_usd_micros bigint NOT NULL,
  projected_net_usd_micros bigint NOT NULL,
  direct_unstake_counterfactual_id text
    REFERENCES direct_unstake_counterfactuals(id) ON DELETE CASCADE,
  opened_epoch bigint NOT NULL CHECK (opened_epoch >= 0),
  available_epoch bigint NOT NULL CHECK (available_epoch = opened_epoch + 1),
  opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= 0),
  closed_at_ms bigint CHECK (closed_at_ms >= opened_at_ms),
  opened_source_event_id text NOT NULL
    REFERENCES normalized_events(id) ON DELETE CASCADE,
  latest_source_event_id text NOT NULL
    REFERENCES normalized_events(id) ON DELETE CASCADE,
  realized_basis_usd_micros bigint NOT NULL DEFAULT 0,
  realized_funding_usd_micros bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX nav_discount_one_open_per_portfolio
  ON nav_discount_paper_positions(portfolio_run_id)
  WHERE status IN ('open', 'exit_blocked');

CREATE TABLE nav_discount_paper_decisions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL
    REFERENCES normalized_events(id) ON DELETE CASCADE,
  protocol_nav_lamports bigint NOT NULL CHECK (protocol_nav_lamports > 0),
  hedge_lamports numeric(78, 0) NOT NULL CHECK (hedge_lamports > 0),
  market_ask_usd_micros bigint NOT NULL CHECK (market_ask_usd_micros > 0),
  market_bid_usd_micros bigint NOT NULL CHECK (market_bid_usd_micros > 0),
  discount_bps bigint NOT NULL,
  direct_net_usd_micros bigint NOT NULL,
  instant_net_usd_micros bigint NOT NULL,
  selected_route text NOT NULL CHECK (selected_route IN ('direct', 'instant')),
  expected_funding_usd_micros bigint NOT NULL,
  net_carry_usd_micros bigint NOT NULL,
  eligible boolean NOT NULL,
  action text NOT NULL CHECK (
    action IN ('open', 'hold', 'close', 'gated', 'exit_blocked')
  ),
  reason_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (portfolio_run_id, source_event_id)
);

CREATE FUNCTION run_nav_discount_paper_cycle(
  p_source_event_id text,
  p_now_ms bigint,
  p_source_max_age_ms bigint,
  p_minimum_margin_ratio_ppm bigint,
  p_minimum_liquidation_distance_bps bigint,
  p_direct_unstake_fee_ppm bigint,
  p_direct_chain_fees_usd_micros bigint,
  p_direct_hedge_cost_usd_micros bigint,
  p_direct_capital_delay_haircut_usd_micros bigint,
  p_direct_final_hedge_close_cost_usd_micros bigint,
  p_hold_hours integer
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_event normalized_events%ROWTYPE;
  v_payload jsonb;
  v_portfolio record;
  v_position nav_discount_paper_positions%ROWTYPE;
  v_direct direct_unstake_counterfactuals%ROWTYPE;
  v_control_ready boolean;
  v_entries_paused boolean;
  v_nav numeric;
  v_nav_price numeric;
  v_quantity numeric;
  v_hedge numeric;
  v_redemption_lamports numeric;
  v_withdrawal_fee_lamports numeric;
  v_net_redemption_lamports numeric;
  v_redemption_usd numeric;
  v_withdrawal_fee_usd numeric;
  v_acquisition_usd numeric;
  v_instant_proceeds_usd numeric;
  v_projected_funding numeric;
  v_direct_net numeric;
  v_instant_net numeric;
  v_selected_net numeric;
  v_route text;
  v_eligible boolean;
  v_action text;
  v_reason text;
  v_counterfactual_id text;
  v_counterfactual_net numeric;
  v_opened integer := 0;
  v_held integer := 0;
  v_closed integer := 0;
  v_blocked integer := 0;
BEGIN
  IF p_source_event_id IS NULL
     OR p_source_max_age_ms <= 0
     OR p_minimum_margin_ratio_ppm <= 0
     OR p_minimum_liquidation_distance_bps < 0
     OR p_direct_unstake_fee_ppm NOT BETWEEN 0 AND 1000000
     OR p_direct_chain_fees_usd_micros < 0
     OR p_direct_hedge_cost_usd_micros < 0
     OR p_direct_capital_delay_haircut_usd_micros < 0
     OR p_direct_final_hedge_close_cost_usd_micros < 0
     OR p_hold_hours <= 0 THEN
    RAISE EXCEPTION 'invalid NAV discount paper inputs';
  END IF;

  SELECT * INTO v_event
  FROM normalized_events
  WHERE id = p_source_event_id
    AND event_type = 'MarketSnapshot';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NAV discount source event is invalid';
  END IF;
  v_payload := v_event.canonical_payload->'payload';
  IF jsonb_typeof(v_payload) <> 'object'
     OR v_payload->>'epoch' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'oracleStatus' NOT IN ('valid', 'invalid')
     OR v_payload->>'totalPoolLamports' !~ '^[1-9][0-9]*$'
     OR v_payload->>'supplyAtoms' !~ '^[1-9][0-9]*$'
     OR v_payload->>'jitosolAtoms' !~ '^[1-9][0-9]*$'
     OR v_payload->>'shortReceiptPpm' !~ '^(0|-?[1-9][0-9]*)$'
     OR abs((v_payload->>'shortReceiptPpm')::numeric) > 1000000
     OR v_payload->>'solPriceUsdMicros' !~ '^[1-9][0-9]*$'
     OR v_payload->>'priorNavLamports' !~ '^[1-9][0-9]*$'
     OR v_payload->>'costsUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'riskHaircutUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'collateralUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'maintenanceRequirementUsdMicros'
       !~ '^[1-9][0-9]*$'
     OR v_payload->>'liquidationDistanceBps' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'jitosolSpotBidPriceUsdMicros' !~ '^[1-9][0-9]*$'
     OR v_payload->>'jitosolSpotAskPriceUsdMicros' !~ '^[1-9][0-9]*$'
     OR v_payload->>'jitosolExitDepthLamports' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'perpExitDepthLamports' !~ '^(0|[1-9][0-9]*)$' THEN
    RAISE EXCEPTION 'invalid NAV discount source contract';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM nav_discount_paper_decisions
    WHERE source_event_id = p_source_event_id
  ) THEN
    RETURN jsonb_build_object(
      'opened', 0, 'held', 0, 'closed', 0, 'blocked', 0, 'duplicate', true
    );
  END IF;

  v_nav := trunc(
    (v_payload->>'totalPoolLamports')::numeric * 1000000000
      / (v_payload->>'supplyAtoms')::numeric
  );
  v_nav_price := trunc(
    v_nav * (v_payload->>'solPriceUsdMicros')::numeric / 1000000000
  );
  v_quantity := (v_payload->>'jitosolAtoms')::numeric;
  v_hedge := ceil(v_quantity * v_nav / 1000000000);
  v_redemption_lamports := trunc(v_quantity * v_nav / 1000000000);
  v_withdrawal_fee_lamports := ceil(
    v_redemption_lamports * p_direct_unstake_fee_ppm / 1000000
  );
  v_net_redemption_lamports :=
    v_redemption_lamports - v_withdrawal_fee_lamports;
  v_redemption_usd := trunc(
    v_redemption_lamports
      * (v_payload->>'solPriceUsdMicros')::numeric / 1000000000
  );
  v_withdrawal_fee_usd := ceil(
    v_withdrawal_fee_lamports
      * (v_payload->>'solPriceUsdMicros')::numeric / 1000000000
  );
  v_acquisition_usd := ceil(
    v_quantity
      * (v_payload->>'jitosolSpotAskPriceUsdMicros')::numeric / 1000000000
  );
  v_instant_proceeds_usd := trunc(
    v_quantity
      * (v_payload->>'jitosolSpotBidPriceUsdMicros')::numeric / 1000000000
  );
  v_projected_funding := trunc(
    v_redemption_usd
      * (v_payload->>'shortReceiptPpm')::numeric
      * p_hold_hours / 1000000
  );
  v_direct_net :=
    v_redemption_usd
    - v_acquisition_usd
    - v_withdrawal_fee_usd
    + v_projected_funding
    - p_direct_chain_fees_usd_micros
    - p_direct_hedge_cost_usd_micros
    - p_direct_capital_delay_haircut_usd_micros
    - p_direct_final_hedge_close_cost_usd_micros
    - (v_payload->>'costsUsdMicros')::numeric
    - (v_payload->>'riskHaircutUsdMicros')::numeric;
  v_instant_net :=
    v_instant_proceeds_usd
    - v_acquisition_usd
    - (v_payload->>'costsUsdMicros')::numeric
    - (v_payload->>'riskHaircutUsdMicros')::numeric;
  IF v_instant_net > v_direct_net THEN
    v_route := 'instant';
    v_selected_net := v_instant_net;
  ELSE
    v_route := 'direct';
    v_selected_net := v_direct_net;
  END IF;

  SELECT pause_entries OR pause_all
  INTO v_entries_paused
  FROM control_state;

  FOR v_portfolio IN
    SELECT p.id, p.comparison_group_id, g.mode
    FROM portfolio_runs p
    JOIN comparison_groups g ON g.id = p.comparison_group_id
    WHERE p.variant = 'jitosol_nav_discount'
      AND p.execution_mode = 'paper'
      AND p.ended_at IS NULL
      AND p.state <> 'paused'
    ORDER BY p.id
  LOOP
    SELECT * INTO v_position
    FROM nav_discount_paper_positions
    WHERE portfolio_run_id = v_portfolio.id
      AND status IN ('open', 'exit_blocked')
    LIMIT 1;
    IF FOUND THEN
      SELECT * INTO v_direct
      FROM direct_unstake_counterfactuals
      WHERE id = v_position.direct_unstake_counterfactual_id;
      IF NOT FOUND OR v_direct.state = 'failed' THEN
        UPDATE nav_discount_paper_positions
        SET status = 'exit_blocked',
            latest_source_event_id = p_source_event_id,
            updated_at = now()
        WHERE id = v_position.id;
        UPDATE portfolio_runs
        SET state = 'emergency_flatten'
        WHERE id = v_portfolio.id;
        v_action := 'exit_blocked';
        v_reason := 'direct_unstake_failed';
        v_blocked := v_blocked + 1;
      ELSIF v_direct.state = 'withdrawn' THEN
        UPDATE nav_discount_paper_positions
        SET status = 'closed',
            closed_at_ms = p_now_ms,
            latest_source_event_id = p_source_event_id,
            realized_basis_usd_micros =
              v_direct.protocol_redemption_usd_micros::bigint
              - v_direct.withdrawal_fee_usd_micros::bigint
              - acquisition_cost_usd_micros
              - v_direct.chain_fees_usd_micros::bigint
              - v_direct.hedge_cost_usd_micros::bigint
              - v_direct.capital_delay_haircut_usd_micros::bigint
              - v_direct.final_hedge_close_cost_usd_micros::bigint,
            realized_funding_usd_micros =
              v_direct.cooldown_funding_usd_micros::bigint,
            updated_at = now()
        WHERE id = v_position.id;
        UPDATE portfolio_runs
        SET state = 'idle', state_version = state_version + 1
        WHERE id = v_portfolio.id;
        v_action := 'close';
        v_reason := 'nav_discount_direct_cycle_completed';
        v_selected_net :=
          v_direct.net_usd_micros::numeric
          - v_position.acquisition_cost_usd_micros
          - v_position.paper_cost_usd_micros
          - (v_payload->>'riskHaircutUsdMicros')::numeric;
        v_closed := v_closed + 1;
      ELSE
        UPDATE nav_discount_paper_positions
        SET status = 'open',
            latest_source_event_id = p_source_event_id,
            updated_at = now()
        WHERE id = v_position.id;
        UPDATE portfolio_runs
        SET state = 'hedged'
        WHERE id = v_portfolio.id;
        v_action := 'hold';
        v_reason := 'direct_unstake_pending';
        v_selected_net := v_position.projected_net_usd_micros;
        v_held := v_held + 1;
      END IF;
      INSERT INTO nav_discount_paper_decisions (
        id, portfolio_run_id, source_event_id, protocol_nav_lamports,
        hedge_lamports,
        market_ask_usd_micros, market_bid_usd_micros, discount_bps,
        direct_net_usd_micros, instant_net_usd_micros, selected_route,
        expected_funding_usd_micros, net_carry_usd_micros,
        eligible, action, reason_code
      ) VALUES (
        p_source_event_id || ':' || v_portfolio.id,
        v_portfolio.id,
        p_source_event_id,
        v_nav::bigint,
        v_hedge,
        (v_payload->>'jitosolSpotAskPriceUsdMicros')::bigint,
        (v_payload->>'jitosolSpotBidPriceUsdMicros')::bigint,
        floor(
          (v_nav_price
            - (v_payload->>'jitosolSpotAskPriceUsdMicros')::numeric)
            * 10000 / v_nav_price
        )::bigint,
        v_direct_net::bigint,
        v_instant_net::bigint,
        v_position.exit_route,
        v_position.projected_funding_usd_micros,
        v_selected_net::bigint,
        false,
        v_action,
        v_reason
      );
      CONTINUE;
    END IF;

    SELECT CASE
      WHEN v_portfolio.mode = 'independent' THEN true
      ELSE EXISTS (
        SELECT 1
        FROM portfolio_runs
        WHERE comparison_group_id = v_portfolio.comparison_group_id
          AND variant = 'sol_control'
          AND state = 'hedged'
      )
    END
    INTO v_control_ready;

    v_eligible :=
      NOT v_entries_paused
      AND v_control_ready
      AND v_payload->>'oracleStatus' = 'valid'
      AND v_event.observed_at_ms <= p_now_ms
      AND p_now_ms - v_event.observed_at_ms <= p_source_max_age_ms
      AND v_nav >= (v_payload->>'priorNavLamports')::numeric
      AND v_nav_price
        > (v_payload->>'jitosolSpotAskPriceUsdMicros')::numeric
      AND (v_payload->>'jitosolExitDepthLamports')::numeric >= v_hedge
      AND (v_payload->>'perpExitDepthLamports')::numeric >= v_hedge
      AND (
        (v_payload->>'collateralUsdMicros')::numeric * 1000000
          / (v_payload->>'maintenanceRequirementUsdMicros')::numeric
      ) >= p_minimum_margin_ratio_ppm
      AND (v_payload->>'liquidationDistanceBps')::numeric
        >= p_minimum_liquidation_distance_bps
      AND v_selected_net > 0;
    v_action := 'gated';
    v_reason := CASE
      WHEN v_entries_paused THEN 'entries_paused'
      WHEN NOT v_control_ready THEN 'benchmark_not_hedged'
      WHEN v_payload->>'oracleStatus' <> 'valid' THEN 'oracle_invalid'
      WHEN v_event.observed_at_ms > p_now_ms THEN 'source_time_in_future'
      WHEN p_now_ms - v_event.observed_at_ms > p_source_max_age_ms
        THEN 'source_stale'
      WHEN v_nav < (v_payload->>'priorNavLamports')::numeric
        THEN 'jitosol_nav_decrease'
      WHEN v_nav_price
        <= (v_payload->>'jitosolSpotAskPriceUsdMicros')::numeric
        THEN 'nav_discount_absent'
      WHEN (v_payload->>'jitosolExitDepthLamports')::numeric < v_hedge
        OR (v_payload->>'perpExitDepthLamports')::numeric < v_hedge
        THEN 'insufficient_exit_depth'
      WHEN (
        (v_payload->>'collateralUsdMicros')::numeric * 1000000
          / (v_payload->>'maintenanceRequirementUsdMicros')::numeric
      ) < p_minimum_margin_ratio_ppm
        THEN 'margin_ratio_below_minimum'
      WHEN (v_payload->>'liquidationDistanceBps')::numeric
        < p_minimum_liquidation_distance_bps
        THEN 'liquidation_distance_below_minimum'
      ELSE 'nav_discount_not_profitable'
    END;

    IF v_eligible AND v_route = 'direct' THEN
      v_counterfactual_id :=
        p_source_event_id || ':' || v_portfolio.id || ':direct-unstake';
      v_counterfactual_net :=
        v_redemption_usd
        - v_withdrawal_fee_usd
        - p_direct_chain_fees_usd_micros
        - p_direct_hedge_cost_usd_micros
        - p_direct_capital_delay_haircut_usd_micros
        - p_direct_final_hedge_close_cost_usd_micros;

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
        v_counterfactual_id,
        v_portfolio.id,
        p_source_event_id,
        'requested',
        (v_payload->>'epoch')::bigint,
        (v_payload->>'epoch')::bigint + 1,
        v_quantity::text,
        v_hedge::text,
        v_redemption_lamports::text,
        v_withdrawal_fee_lamports::text,
        v_net_redemption_lamports::text,
        v_redemption_usd::text,
        v_withdrawal_fee_usd::text,
        '0',
        p_direct_chain_fees_usd_micros::text,
        p_direct_hedge_cost_usd_micros::text,
        p_direct_capital_delay_haircut_usd_micros::text,
        p_direct_final_hedge_close_cost_usd_micros::text,
        v_counterfactual_net::text
      );
      INSERT INTO direct_unstake_events (
        id, counterfactual_id, source_event_id, state, reason
      ) VALUES (
        v_counterfactual_id || ':requested',
        v_counterfactual_id,
        p_source_event_id,
        'requested',
        'nav_discount_direct_unstake_started'
      );
      INSERT INTO direct_unstake_ledger_entries (
        id, counterfactual_id, source_event_id, component, usd_value_micros
      )
      SELECT
        v_counterfactual_id || ':' || component,
        v_counterfactual_id,
        p_source_event_id,
        component,
        CASE WHEN value = 0 THEN '0' ELSE value::text END
      FROM (VALUES
        ('protocol_redemption', v_redemption_usd),
        ('withdrawal_fee', -v_withdrawal_fee_usd),
        ('chain_fees', -p_direct_chain_fees_usd_micros::numeric),
        ('hedge_cost', -p_direct_hedge_cost_usd_micros::numeric),
        ('capital_delay_haircut',
          -p_direct_capital_delay_haircut_usd_micros::numeric),
        ('final_hedge_close_cost',
          -p_direct_final_hedge_close_cost_usd_micros::numeric)
      ) AS components(component, value);

      INSERT INTO nav_discount_paper_positions (
        id, portfolio_run_id, status, exit_route, quantity_atoms,
        hedge_quantity_atoms, protocol_nav_lamports,
        entry_ask_usd_micros, instant_bid_usd_micros,
        acquisition_cost_usd_micros, paper_cost_usd_micros,
        projected_funding_usd_micros, projected_net_usd_micros,
        direct_unstake_counterfactual_id, opened_epoch, available_epoch,
        opened_at_ms, opened_source_event_id, latest_source_event_id
      ) VALUES (
        p_source_event_id || ':' || v_portfolio.id,
        v_portfolio.id,
        'open',
        'direct',
        v_quantity,
        v_hedge,
        v_nav::bigint,
        (v_payload->>'jitosolSpotAskPriceUsdMicros')::bigint,
        (v_payload->>'jitosolSpotBidPriceUsdMicros')::bigint,
        v_acquisition_usd::bigint,
        (v_payload->>'costsUsdMicros')::bigint,
        v_projected_funding::bigint,
        v_direct_net::bigint,
        v_counterfactual_id,
        (v_payload->>'epoch')::bigint,
        (v_payload->>'epoch')::bigint + 1,
        p_now_ms,
        p_source_event_id,
        p_source_event_id
      );
      UPDATE portfolio_runs
      SET state = 'hedged', state_version = state_version + 1
      WHERE id = v_portfolio.id;
      v_action := 'open';
      v_reason := 'nav_discount_direct_opened';
      v_opened := v_opened + 1;
    ELSIF v_eligible THEN
      INSERT INTO nav_discount_paper_positions (
        id, portfolio_run_id, status, exit_route, quantity_atoms,
        hedge_quantity_atoms, protocol_nav_lamports,
        entry_ask_usd_micros, instant_bid_usd_micros,
        acquisition_cost_usd_micros, paper_cost_usd_micros,
        projected_funding_usd_micros, projected_net_usd_micros,
        opened_epoch, available_epoch, opened_at_ms, closed_at_ms,
        opened_source_event_id, latest_source_event_id,
        realized_basis_usd_micros
      ) VALUES (
        p_source_event_id || ':' || v_portfolio.id,
        v_portfolio.id,
        'closed',
        'instant',
        v_quantity,
        v_hedge,
        v_nav::bigint,
        (v_payload->>'jitosolSpotAskPriceUsdMicros')::bigint,
        (v_payload->>'jitosolSpotBidPriceUsdMicros')::bigint,
        v_acquisition_usd::bigint,
        (v_payload->>'costsUsdMicros')::bigint,
        0,
        v_instant_net::bigint,
        (v_payload->>'epoch')::bigint,
        (v_payload->>'epoch')::bigint + 1,
        p_now_ms,
        p_now_ms,
        p_source_event_id,
        p_source_event_id,
        (v_instant_proceeds_usd - v_acquisition_usd)::bigint
      );
      v_action := 'close';
      v_reason := 'nav_discount_instant_cycle_completed';
      v_closed := v_closed + 1;
    END IF;

    IF v_eligible THEN
      INSERT INTO ledger_batches (
        id, portfolio_run_id, event_type, event_id, batch_hash
      ) VALUES (
        p_source_event_id || ':' || v_portfolio.id || ':nav-discount-cost',
        v_portfolio.id,
        'nav_discount_cost',
        p_source_event_id,
        v_event.raw_payload_hash
      );
      INSERT INTO ledger_entries (
        ledger_batch_id, account_debit, account_credit, asset,
        amount_atoms, usd_value_atoms, price_reference_id
      )
      SELECT
        p_source_event_id || ':' || v_portfolio.id || ':nav-discount-cost',
        'trading_fees',
        'paper_cash',
        'USDC',
        (v_payload->>'costsUsdMicros'),
        (v_payload->>'costsUsdMicros'),
        p_source_event_id
      WHERE (v_payload->>'costsUsdMicros')::numeric > 0;
    END IF;

    INSERT INTO nav_discount_paper_decisions (
      id, portfolio_run_id, source_event_id, protocol_nav_lamports,
      hedge_lamports,
      market_ask_usd_micros, market_bid_usd_micros, discount_bps,
      direct_net_usd_micros, instant_net_usd_micros, selected_route,
      expected_funding_usd_micros, net_carry_usd_micros,
      eligible, action, reason_code
    ) VALUES (
      p_source_event_id || ':' || v_portfolio.id,
      v_portfolio.id,
      p_source_event_id,
      v_nav::bigint,
      v_hedge,
      (v_payload->>'jitosolSpotAskPriceUsdMicros')::bigint,
      (v_payload->>'jitosolSpotBidPriceUsdMicros')::bigint,
      floor(
        (v_nav_price
          - (v_payload->>'jitosolSpotAskPriceUsdMicros')::numeric)
          * 10000 / v_nav_price
      )::bigint,
      v_direct_net::bigint,
      v_instant_net::bigint,
      v_route,
      v_projected_funding::bigint,
      v_selected_net::bigint,
      v_eligible,
      v_action,
      v_reason
    );
  END LOOP;

  RETURN jsonb_build_object(
    'opened', v_opened,
    'held', v_held,
    'closed', v_closed,
    'blocked', v_blocked,
    'duplicate', false
  );
END;
$$;

INSERT INTO schema_meta(version) VALUES (35);

COMMIT;
