BEGIN;

-- Wallet-flow v2: the paper broker learns to hold winners.
--
-- v1 amputated the right tail the strategy exists to capture: a hard
-- 15-minute time stop, no take-profit of any kind, a forced exit on Pump
-- migration, an exit on a single zero-inflow print, and a full-position
-- realization at $0 on any transient quote failure. v2 replaces that with a
-- recoup-then-ride exit engine: sell cost basis at the configured multiple,
-- trail the remainder on the executable quote's high-water mark, stop out
-- flat/losing positions quickly, debounce flow and liquidity signals over
-- consecutive snapshots, and hold through migration while recording the
-- crossing. Position size moves from $10 (where fixed fees are a 5.4%
-- entry drag) to $100, and up to three positions may be open at once.
--
-- Validation compatibility: solana_validation_report reads per-position
-- realized_pnl_usd_micros, entry_cost_usd_micros, closed_at_ms and
-- entry_migration_status. Those keep exact v1 semantics — realized P&L is
-- total exit proceeds across all legs minus entry cost, recorded when the
-- final leg closes the position.

-- 1. v2 strategy config: position $100, thresholds unchanged.
INSERT INTO solana_strategy_configs (id, config_hash, config_json, active) VALUES (
  'solana-wallet-flow-v2',
  'bd14721431e0f7ab162acd225f7fcaa3d35792932ea9280224608388ad91d212',
  '{
    "maxEntryImpactBps":"200",
    "maxLinkedInventoryExitDepthBps":"10000",
    "maxRoundTripLossBps":"800",
    "maxSnapshotAgeMs":"30000",
    "maxTopTenHolderConcentrationBps":"4000",
    "minimumExitDepthMultiple":"10",
    "minimumOrganicBuyerCount":"10",
    "minimumOrganicInflowUsdMicros":"1",
    "minimumWalletHistory":"20",
    "positionUsdMicros":"100000000"
  }'::jsonb,
  false
);
UPDATE solana_strategy_configs SET active = false WHERE id = 'solana-wallet-flow-v1';
UPDATE solana_strategy_configs SET active = true WHERE id = 'solana-wallet-flow-v2';

-- 2. v2 broker config: exit engine knobs.
INSERT INTO solana_paper_broker_configs (id, config_hash, config_json, active) VALUES (
  'solana-paper-broker-v2',
  '3491ae8d50859f3a12d9b643508b9c1b5c73656630a9b7ae9911323f5669075d',
  '{
    "accountRentUsdMicros":"500000",
    "flatTimeStopMs":"1800000",
    "flowCollapseConsecutive":"3",
    "initialCapitalUsdMicros":"1000000000",
    "maxOpenPositions":"3",
    "maximumHoldMs":"86400000",
    "minimumBuyerRetentionBps":"5000",
    "minimumDecisionLatencyMs":"500",
    "networkFeeUsdMicros":"20000",
    "noLiquidityConsecutive":"3",
    "paperSlippageBps":"100",
    "progressThresholdBps":"2500",
    "quoteValidityMs":"30000",
    "reserveCapitalUsdMicros":"300000000",
    "stopLossBps":"5000",
    "takeProfitMultipleBps":"20000",
    "trailingStopBps":"3000"
  }'::jsonb,
  false
);
UPDATE solana_paper_broker_configs SET active = false WHERE id = 'solana-paper-broker-v1';
UPDATE solana_paper_broker_configs SET active = true WHERE id = 'solana-paper-broker-v2';

-- 3. Position state for the exit engine.
ALTER TABLE solana_paper_positions
  ADD COLUMN remaining_quantity_atoms numeric,
  ADD COLUMN recouped boolean NOT NULL DEFAULT false,
  ADD COLUMN peak_return_bps bigint NOT NULL DEFAULT 0 CHECK (peak_return_bps >= 0),
  ADD COLUMN high_water_quote_usd_micros numeric NOT NULL DEFAULT 0
    CHECK (high_water_quote_usd_micros >= 0),
  ADD COLUMN high_water_quote_atoms numeric NOT NULL DEFAULT 0
    CHECK (high_water_quote_atoms >= 0),
  ADD COLUMN flow_breach_count integer NOT NULL DEFAULT 0 CHECK (flow_breach_count >= 0),
  ADD COLUMN no_liquidity_count integer NOT NULL DEFAULT 0 CHECK (no_liquidity_count >= 0),
  ADD COLUMN migration_crossed boolean NOT NULL DEFAULT false,
  ADD COLUMN exit_leg_count integer NOT NULL DEFAULT 0 CHECK (exit_leg_count >= 0);
UPDATE solana_paper_positions
SET remaining_quantity_atoms = CASE WHEN status = 'open' THEN quantity_atoms ELSE 0 END;
ALTER TABLE solana_paper_positions
  ALTER COLUMN remaining_quantity_atoms SET NOT NULL,
  ADD CONSTRAINT solana_paper_positions_remaining_bounds CHECK (
    remaining_quantity_atoms >= 0 AND remaining_quantity_atoms <= quantity_atoms
  ),
  ADD CONSTRAINT solana_paper_positions_closed_empty CHECK (
    status = 'open' OR remaining_quantity_atoms = 0
  );

-- Up to maxOpenPositions concurrent positions; the planner enforces the cap.
DROP INDEX solana_paper_positions_one_open;
CREATE INDEX solana_paper_positions_open ON solana_paper_positions(status)
  WHERE status = 'open';

-- 4. Partial exits: one row per executed exit leg.
CREATE TABLE solana_paper_exit_legs (
  position_id text NOT NULL REFERENCES solana_paper_positions(id),
  leg_no integer NOT NULL CHECK (leg_no >= 1),
  snapshot_event_id text NOT NULL UNIQUE REFERENCES solana_candidate_snapshots(event_id),
  reason text NOT NULL CHECK (reason ~ '^[A-Z][A-Z0-9_]{1,100}$'),
  quantity_atoms numeric NOT NULL CHECK (quantity_atoms > 0),
  quote_usd_micros numeric NOT NULL CHECK (quote_usd_micros >= 0),
  proceeds_usd_micros numeric NOT NULL CHECK (proceeds_usd_micros >= 0),
  fee_usd_micros numeric NOT NULL CHECK (fee_usd_micros >= 0),
  exited_at_ms bigint NOT NULL CHECK (exited_at_ms >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (position_id, leg_no)
);

-- 5. The v2 planner. Pure: all writes happen in execute_solana_paper_snapshot.
CREATE OR REPLACE FUNCTION plan_solana_paper_action(
  p_snapshot_event_id text,
  p_processing_at_ms bigint
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_snapshot solana_candidate_snapshots%ROWTYPE;
  v_decision solana_candidate_decisions%ROWTYPE;
  v_config solana_paper_broker_configs%ROWTYPE;
  v_account solana_paper_accounts%ROWTYPE;
  v_position solana_paper_positions%ROWTYPE;
  v_entry_snapshot solana_candidate_snapshots%ROWTYPE;
  v_payload jsonb;
  v_first_enter_ms bigint;
  v_position_id text;
  v_action text;
  v_status text;
  v_reason text;
  v_quantity numeric := 0;
  v_quote_usd numeric := 0;
  v_fee_usd numeric := 0;
  v_cash_delta numeric := 0;
  v_entry_cost numeric;
  v_slippage_bps integer;
  v_network_fee numeric;
  v_payload_atoms numeric;
  v_value numeric;
  v_impact integer;
  v_age_ms bigint;
  v_return_bps bigint;
  v_hard_reject boolean := false;
  v_no_quote boolean := false;
  v_breach boolean := false;
  v_partial boolean := false;
  v_recoup boolean := false;
  v_state_valid boolean := false;
  v_new_peak bigint;
  v_new_hw_usd numeric;
  v_new_hw_atoms numeric;
  v_new_flow integer;
  v_new_no_liquidity integer;
  v_migration_crossed boolean;
  v_recoup_target numeric;
  v_expired boolean;
BEGIN
  IF p_processing_at_ms < 0 THEN
    RAISE EXCEPTION 'paper processing time must be non-negative';
  END IF;
  SELECT * INTO STRICT v_snapshot
  FROM solana_candidate_snapshots WHERE event_id = p_snapshot_event_id;
  IF p_processing_at_ms < v_snapshot.observed_at_ms THEN
    RAISE EXCEPTION 'paper processing time precedes the quote';
  END IF;
  SELECT * INTO STRICT v_decision
  FROM solana_candidate_decisions WHERE snapshot_event_id = p_snapshot_event_id;
  SELECT * INTO STRICT v_config
  FROM solana_paper_broker_configs WHERE active AND frozen;
  SELECT * INTO STRICT v_account
  FROM solana_paper_accounts WHERE id = 'solana-wallet-flow-paper';
  SELECT canonical_payload->'payload' INTO STRICT v_payload
  FROM normalized_events WHERE id = p_snapshot_event_id;
  v_position_id := 'solana-paper:' || v_snapshot.acquisition_event_id;
  v_slippage_bps := (v_config.config_json->>'paperSlippageBps')::integer;
  v_network_fee := (v_config.config_json->>'networkFeeUsdMicros')::numeric;
  v_expired := p_processing_at_ms - v_snapshot.observed_at_ms >
    (v_config.config_json->>'quoteValidityMs')::bigint;

  SELECT * INTO v_position
  FROM solana_paper_positions
  WHERE acquisition_event_id = v_snapshot.acquisition_event_id AND status = 'open';
  IF FOUND THEN
    SELECT * INTO STRICT v_entry_snapshot
    FROM solana_candidate_snapshots WHERE event_id = v_position.entry_snapshot_event_id;
    v_action := 'HOLD'; v_status := 'PLANNED'; v_reason := 'HEALTHY';
    v_payload_atoms := COALESCE(v_payload->>'paperPositionAtoms', '0')::numeric;
    v_value := COALESCE(v_payload->>'positionSellOutputUsdMicros', '0')::numeric;
    v_impact := COALESCE(v_payload->>'positionSellImpactBps', '10000')::integer;
    v_age_ms := v_snapshot.observed_at_ms - v_position.opened_at_ms;
    v_entry_cost := v_position.entry_cost_usd_micros;
    v_new_peak := v_position.peak_return_bps;
    v_new_hw_usd := v_position.high_water_quote_usd_micros;
    v_new_hw_atoms := v_position.high_water_quote_atoms;
    v_new_flow := v_position.flow_breach_count;
    v_new_no_liquidity := v_position.no_liquidity_count;
    v_migration_crossed := v_position.migration_crossed
      OR (v_snapshot.migration_status <> v_position.entry_migration_status
        AND v_snapshot.migration_status <> 'unknown');
    v_hard_reject := v_decision.decision = 'REJECT' AND (
      v_decision.reason IN (
        'SANCTIONS_HIT', 'MINT_AUTHORITY_ENABLED', 'FREEZE_AUTHORITY_ENABLED',
        'CREATOR_SOLD', 'CLUSTER_SOLD', 'HOLDER_CONCENTRATION',
        'LINKED_INVENTORY', 'EXIT_DEPTH', 'UNKNOWN_TOKEN_PROGRAM',
        'UNKNOWN_ROUTE_PROGRAM'
      )
      OR v_decision.reason LIKE 'TOKEN2022\_%'
    );
    v_no_quote := v_decision.decision = 'REJECT' AND v_decision.reason IN (
      'REJECT_NO_ROUND_TRIP', 'SNAPSHOT_SOURCE_FAILED'
    );

    IF v_decision.decision = 'REJECT' AND v_decision.reason = 'REJECT_STALE_SNAPSHOT' THEN
      v_reason := 'REJECT_STALE_SNAPSHOT';
    ELSIF NOT v_no_quote AND v_payload_atoms <> v_position.remaining_quantity_atoms THEN
      -- The monitor quoted a quantity this position no longer holds (a
      -- partial exit landed between quote and processing). Never exit on a
      -- stale-quantity quote; the next monitor pass re-quotes the remainder.
      v_reason := 'POSITION_QUOTE_STALE';
    ELSIF v_no_quote OR v_value = 0 OR v_impact > 1000 THEN
      -- No executable exit this snapshot. One print is a quote blip; the
      -- configured consecutive count is a rug. Realizing at the (possibly
      -- zero) quote only after the debounce keeps total-loss evidence honest
      -- without donating positions to transient API failures.
      v_state_valid := true;
      v_new_no_liquidity := v_position.no_liquidity_count + 1;
      IF v_new_no_liquidity >= (v_config.config_json->>'noLiquidityConsecutive')::integer THEN
        v_action := 'EXIT'; v_reason := 'EXIT_NO_LIQUIDITY';
      ELSE
        v_reason := 'EXIT_LIQUIDITY_DEGRADED';
      END IF;
    ELSE
      v_state_valid := true;
      v_new_no_liquidity := 0;
      v_return_bps := trunc(v_value * 10000 / v_entry_cost);
      v_new_peak := GREATEST(v_position.peak_return_bps, v_return_bps);
      IF v_new_hw_atoms = 0
         OR v_value * v_new_hw_atoms > v_new_hw_usd * v_position.remaining_quantity_atoms THEN
        v_new_hw_usd := v_value;
        v_new_hw_atoms := v_position.remaining_quantity_atoms;
      END IF;
      v_breach := v_snapshot.net_quote_inflow_usd_micros = 0
        OR (v_entry_snapshot.unlinked_buyer_count > 0
          AND v_snapshot.unlinked_buyer_count * 10000
            < v_entry_snapshot.unlinked_buyer_count
              * (v_config.config_json->>'minimumBuyerRetentionBps')::integer);
      v_new_flow := CASE WHEN v_breach THEN v_position.flow_breach_count + 1 ELSE 0 END;

      IF v_hard_reject THEN
        v_action := 'EXIT'; v_reason := v_decision.reason;
      ELSIF NOT v_position.recouped
         AND v_value * 10000 >= v_entry_cost
           * (v_config.config_json->>'takeProfitMultipleBps')::numeric THEN
        -- Recoup: sell just enough to return the entry cost (plus the exit
        -- fee, net of modeled slippage); the remainder rides as house money
        -- under the trailing stop.
        v_recoup_target := v_entry_cost + v_network_fee;
        v_quantity := ceil(
          v_position.remaining_quantity_atoms * v_recoup_target * 10000
          / (v_value * (10000 - v_slippage_bps))
        );
        IF v_quantity >= v_position.remaining_quantity_atoms THEN
          v_action := 'EXIT'; v_reason := 'RECOUP';
        ELSE
          v_action := 'EXIT'; v_reason := 'RECOUP';
          v_partial := true; v_recoup := true;
          v_new_hw_usd := v_value;
          v_new_hw_atoms := v_position.remaining_quantity_atoms;
        END IF;
      ELSIF v_position.recouped
         AND v_value * v_new_hw_atoms * 10000
           < v_new_hw_usd * v_position.remaining_quantity_atoms
             * (10000 - (v_config.config_json->>'trailingStopBps')::numeric) THEN
        v_action := 'EXIT'; v_reason := 'TRAILING_STOP';
      ELSIF NOT v_position.recouped
         AND v_value * 10000 <= v_entry_cost
           * (10000 - (v_config.config_json->>'stopLossBps')::numeric) THEN
        v_action := 'EXIT'; v_reason := 'STOP_LOSS';
      ELSIF v_age_ms >= (v_config.config_json->>'maximumHoldMs')::bigint THEN
        v_action := 'EXIT'; v_reason := 'TIME_STOP_MAX';
      ELSIF NOT v_position.recouped
         AND v_age_ms >= (v_config.config_json->>'flatTimeStopMs')::bigint
         AND v_new_peak < 10000 + (v_config.config_json->>'progressThresholdBps')::bigint THEN
        -- The flat time stop only kills positions that never went anywhere.
        -- A position that reached the progress threshold earns its hold; a
        -- recouped one answers to the trailing stop instead.
        v_action := 'EXIT'; v_reason := 'TIME_STOP_FLAT';
      ELSIF NOT v_position.recouped
         AND v_breach
         AND v_new_flow >= (v_config.config_json->>'flowCollapseConsecutive')::integer THEN
        v_action := 'EXIT'; v_reason := 'ORGANIC_FLOW_COLLAPSE';
      ELSIF v_breach THEN
        v_reason := 'ORGANIC_FLOW_WEAK';
      ELSIF v_migration_crossed AND NOT v_position.migration_crossed THEN
        v_reason := 'MIGRATION_OBSERVED';
      END IF;
    END IF;

    IF v_action = 'EXIT' THEN
      IF v_expired THEN
        v_status := 'REJECTED'; v_reason := 'QUOTE_EXPIRED';
        v_quantity := 0; v_partial := false; v_recoup := false;
      ELSE
        v_status := 'FILLED';
        IF NOT v_partial THEN
          v_quantity := v_position.remaining_quantity_atoms;
          v_quote_usd := v_value;
        ELSE
          v_quote_usd := trunc(v_value * v_quantity / v_position.remaining_quantity_atoms);
        END IF;
        IF v_quote_usd > 0 THEN
          v_fee_usd := v_network_fee;
          v_cash_delta := GREATEST(0,
            trunc(v_quote_usd * (10000 - v_slippage_bps) / 10000) - v_fee_usd
          );
        END IF;
      END IF;
    END IF;
  ELSE
    IF EXISTS (
      SELECT 1 FROM solana_paper_positions
      WHERE acquisition_event_id = v_snapshot.acquisition_event_id
    ) THEN
      v_action := 'SKIP'; v_status := 'REJECTED'; v_reason := 'ALREADY_TRADED';
    ELSIF NOT strategy_enabled('solana_wallet_flow_quant') THEN
      v_action := 'SKIP'; v_status := 'REJECTED'; v_reason := 'STRATEGY_STOPPED';
    ELSIF v_decision.decision = 'REJECT' THEN
      v_action := 'SKIP'; v_status := 'REJECTED'; v_reason := v_decision.reason;
    ELSIF v_decision.decision <> 'ENTER' THEN
      v_action := 'HOLD'; v_status := 'PLANNED'; v_reason := v_decision.reason;
    ELSIF v_expired THEN
      v_action := 'ENTRY'; v_status := 'REJECTED'; v_reason := 'QUOTE_EXPIRED';
    ELSE
      SELECT min(s.observed_at_ms) INTO v_first_enter_ms
      FROM solana_candidate_decisions d
      JOIN solana_candidate_snapshots s ON s.event_id = d.snapshot_event_id
      WHERE s.acquisition_event_id = v_snapshot.acquisition_event_id
        AND d.decision = 'ENTER';
      IF v_snapshot.observed_at_ms - v_first_enter_ms <
          (v_config.config_json->>'minimumDecisionLatencyMs')::bigint THEN
        v_action := 'HOLD'; v_status := 'PLANNED'; v_reason := 'ENTRY_LATENCY';
      ELSIF (SELECT count(*) FROM solana_paper_positions WHERE status = 'open')
          >= (v_config.config_json->>'maxOpenPositions')::integer THEN
        v_action := 'SKIP'; v_status := 'REJECTED'; v_reason := 'POSITION_LIMIT';
      ELSIF v_snapshot.buy_input_usd_micros <>
          (SELECT (config_json->>'positionUsdMicros')::numeric
           FROM solana_strategy_configs WHERE active) THEN
        v_action := 'ENTRY'; v_status := 'REJECTED'; v_reason := 'ENTRY_NOTIONAL';
      ELSE
        v_quantity := trunc(
          (v_snapshot.buy_output_atoms - v_snapshot.transfer_fee_buy_atoms)
          * (10000 - v_slippage_bps) / 10000
        );
        v_fee_usd := v_network_fee
          + (v_config.config_json->>'accountRentUsdMicros')::numeric;
        v_entry_cost := v_snapshot.buy_input_usd_micros + v_fee_usd;
        IF v_quantity <= 0 THEN
          v_action := 'ENTRY'; v_status := 'REJECTED'; v_reason := 'ENTRY_ZERO_FILL';
        ELSIF v_account.cash_balance_usd_micros - v_entry_cost
            < v_account.reserve_capital_usd_micros THEN
          v_action := 'ENTRY'; v_status := 'REJECTED'; v_reason := 'CAPITAL_RESERVE';
          v_quantity := 0;
        ELSE
          v_action := 'ENTRY'; v_status := 'FILLED'; v_reason := 'PAPER_ENTRY';
          v_quote_usd := v_snapshot.buy_input_usd_micros;
          v_cash_delta := -v_entry_cost;
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'snapshotEventId', p_snapshot_event_id,
    'acquisitionEventId', v_snapshot.acquisition_event_id,
    'positionId', v_position_id,
    'configId', v_config.id,
    'action', v_action,
    'status', v_status,
    'reason', v_reason,
    'quoteObservedAtMs', v_snapshot.observed_at_ms::text,
    'quoteExpiresAtMs', (v_snapshot.observed_at_ms
      + (v_config.config_json->>'quoteValidityMs')::bigint)::text,
    'processedAtMs', p_processing_at_ms::text,
    'quantityAtoms', v_quantity::text,
    'quoteUsdMicros', v_quote_usd::text,
    'feeUsdMicros', v_fee_usd::text,
    'cashDeltaUsdMicros', v_cash_delta::text,
    'decision', v_decision.decision,
    'decisionReason', v_decision.reason,
    'brokerConfigHash', v_config.config_hash,
    'partial', v_partial,
    'recoup', v_recoup,
    'stateValid', v_state_valid,
    'positionValueUsdMicros', COALESCE(v_value, 0)::text,
    'newPeakReturnBps', COALESCE(v_new_peak, 0)::text,
    'newHighWaterQuoteUsdMicros', COALESCE(v_new_hw_usd, 0)::text,
    'newHighWaterQuoteAtoms', COALESCE(v_new_hw_atoms, 0)::text,
    'newFlowBreachCount', COALESCE(v_new_flow, 0)::text,
    'newNoLiquidityCount', COALESCE(v_new_no_liquidity, 0)::text,
    'migrationCrossed', COALESCE(v_migration_crossed, false)
  );
END;
$$;

-- 6. The v2 executor: applies the plan, including partial legs and state.
CREATE OR REPLACE FUNCTION execute_solana_paper_snapshot(p_snapshot_event_id text) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_snapshot solana_candidate_snapshots%ROWTYPE;
  v_plan jsonb;
  v_position_id text;
  v_position solana_paper_positions%ROWTYPE;
  v_first_enter_ms bigint;
  v_entry_cost numeric;
  v_proceeds numeric;
  v_leg_no integer;
  v_total_proceeds numeric;
BEGIN
  SELECT * INTO STRICT v_snapshot
  FROM solana_candidate_snapshots WHERE event_id = p_snapshot_event_id;
  PERFORM 1 FROM solana_paper_accounts
  WHERE id = 'solana-wallet-flow-paper' FOR UPDATE;
  v_plan := plan_solana_paper_action(p_snapshot_event_id, v_snapshot.observed_at_ms);
  v_position_id := v_plan->>'positionId';

  IF v_plan->>'action' = 'ENTRY' AND v_plan->>'status' = 'FILLED' THEN
    SELECT min(s.observed_at_ms) INTO STRICT v_first_enter_ms
    FROM solana_candidate_decisions d
    JOIN solana_candidate_snapshots s ON s.event_id = d.snapshot_event_id
    WHERE s.acquisition_event_id = v_snapshot.acquisition_event_id
      AND d.decision = 'ENTER';
    v_entry_cost := -(v_plan->>'cashDeltaUsdMicros')::numeric;
    INSERT INTO solana_paper_positions (
      id, acquisition_event_id, wallet, mint, status, config_id,
      entry_snapshot_event_id, entry_decision_at_ms, opened_at_ms,
      decision_latency_ms, entry_input_usd_micros, entry_cost_usd_micros,
      quantity_atoms, entry_transfer_fee_atoms, entry_network_fee_usd_micros,
      entry_rent_usd_micros, entry_migration_status, entry_unlinked_buyer_count,
      remaining_quantity_atoms
    ) VALUES (
      v_position_id, v_snapshot.acquisition_event_id, v_snapshot.wallet,
      v_snapshot.mint, 'open', v_plan->>'configId', p_snapshot_event_id,
      v_first_enter_ms, v_snapshot.observed_at_ms,
      v_snapshot.observed_at_ms - v_first_enter_ms,
      v_snapshot.buy_input_usd_micros, v_entry_cost,
      (v_plan->>'quantityAtoms')::numeric, v_snapshot.transfer_fee_buy_atoms,
      (SELECT (config_json->>'networkFeeUsdMicros')::numeric
       FROM solana_paper_broker_configs WHERE id = v_plan->>'configId'),
      (SELECT (config_json->>'accountRentUsdMicros')::numeric
       FROM solana_paper_broker_configs WHERE id = v_plan->>'configId'),
      v_snapshot.migration_status, v_snapshot.unlinked_buyer_count,
      (v_plan->>'quantityAtoms')::numeric
    );
    UPDATE solana_paper_accounts SET
      cash_balance_usd_micros = cash_balance_usd_micros - v_entry_cost,
      updated_at_ms = v_snapshot.observed_at_ms
    WHERE id = 'solana-wallet-flow-paper';
  ELSIF v_plan->>'action' = 'EXIT' AND v_plan->>'status' = 'FILLED' THEN
    SELECT * INTO STRICT v_position
    FROM solana_paper_positions WHERE id = v_position_id AND status = 'open';
    v_proceeds := (v_plan->>'cashDeltaUsdMicros')::numeric;
    v_leg_no := v_position.exit_leg_count + 1;
    INSERT INTO solana_paper_exit_legs (
      position_id, leg_no, snapshot_event_id, reason, quantity_atoms,
      quote_usd_micros, proceeds_usd_micros, fee_usd_micros, exited_at_ms
    ) VALUES (
      v_position_id, v_leg_no, p_snapshot_event_id, v_plan->>'reason',
      (v_plan->>'quantityAtoms')::numeric, (v_plan->>'quoteUsdMicros')::numeric,
      v_proceeds, (v_plan->>'feeUsdMicros')::numeric, v_snapshot.observed_at_ms
    );
    IF (v_plan->>'partial')::boolean THEN
      UPDATE solana_paper_positions SET
        remaining_quantity_atoms = remaining_quantity_atoms
          - (v_plan->>'quantityAtoms')::numeric,
        recouped = recouped OR (v_plan->>'recoup')::boolean,
        exit_leg_count = v_leg_no,
        peak_return_bps = (v_plan->>'newPeakReturnBps')::bigint,
        high_water_quote_usd_micros = (v_plan->>'newHighWaterQuoteUsdMicros')::numeric,
        high_water_quote_atoms = (v_plan->>'newHighWaterQuoteAtoms')::numeric,
        flow_breach_count = (v_plan->>'newFlowBreachCount')::integer,
        no_liquidity_count = (v_plan->>'newNoLiquidityCount')::integer,
        migration_crossed = (v_plan->>'migrationCrossed')::boolean
      WHERE id = v_position_id AND status = 'open';
      UPDATE solana_paper_accounts SET
        cash_balance_usd_micros = cash_balance_usd_micros + v_proceeds,
        updated_at_ms = v_snapshot.observed_at_ms
      WHERE id = 'solana-wallet-flow-paper';
    ELSE
      SELECT COALESCE(sum(proceeds_usd_micros), 0) INTO v_total_proceeds
      FROM solana_paper_exit_legs WHERE position_id = v_position_id;
      UPDATE solana_paper_positions SET
        status = 'closed',
        remaining_quantity_atoms = 0,
        exit_leg_count = v_leg_no,
        exit_snapshot_event_id = p_snapshot_event_id,
        closed_at_ms = v_snapshot.observed_at_ms,
        exit_reason = v_plan->>'reason',
        exit_quote_usd_micros = (v_plan->>'quoteUsdMicros')::numeric,
        exit_proceeds_usd_micros = v_total_proceeds,
        exit_network_fee_usd_micros = (v_plan->>'feeUsdMicros')::numeric,
        realized_pnl_usd_micros = v_total_proceeds - entry_cost_usd_micros,
        peak_return_bps = (v_plan->>'newPeakReturnBps')::bigint,
        migration_crossed = (v_plan->>'migrationCrossed')::boolean
      WHERE id = v_position_id AND status = 'open';
      UPDATE solana_paper_accounts SET
        cash_balance_usd_micros = cash_balance_usd_micros + v_proceeds,
        realized_pnl_usd_micros = realized_pnl_usd_micros
          + v_total_proceeds
          - (SELECT entry_cost_usd_micros FROM solana_paper_positions
             WHERE id = v_position_id),
        updated_at_ms = v_snapshot.observed_at_ms
      WHERE id = 'solana-wallet-flow-paper';
    END IF;
  ELSIF v_plan->>'action' IN ('HOLD', 'EXIT') AND (v_plan->>'stateValid')::boolean THEN
    UPDATE solana_paper_positions SET
      peak_return_bps = (v_plan->>'newPeakReturnBps')::bigint,
      high_water_quote_usd_micros = (v_plan->>'newHighWaterQuoteUsdMicros')::numeric,
      high_water_quote_atoms = (v_plan->>'newHighWaterQuoteAtoms')::numeric,
      flow_breach_count = (v_plan->>'newFlowBreachCount')::integer,
      no_liquidity_count = (v_plan->>'newNoLiquidityCount')::integer,
      migration_crossed = (v_plan->>'migrationCrossed')::boolean
    WHERE id = v_position_id AND status = 'open';
  END IF;

  INSERT INTO solana_paper_actions (
    id, snapshot_event_id, acquisition_event_id, position_id, config_id,
    action, status, reason, quote_observed_at_ms, quote_expires_at_ms,
    processed_at_ms, quantity_atoms, quote_usd_micros, fee_usd_micros,
    cash_delta_usd_micros, evidence
  ) VALUES (
    p_snapshot_event_id || ':paper', p_snapshot_event_id,
    v_snapshot.acquisition_event_id,
    CASE WHEN EXISTS (SELECT 1 FROM solana_paper_positions WHERE id = v_position_id)
      THEN v_position_id END,
    v_plan->>'configId', v_plan->>'action', v_plan->>'status', v_plan->>'reason',
    (v_plan->>'quoteObservedAtMs')::bigint,
    (v_plan->>'quoteExpiresAtMs')::bigint,
    (v_plan->>'processedAtMs')::bigint,
    (v_plan->>'quantityAtoms')::numeric,
    (v_plan->>'quoteUsdMicros')::numeric,
    (v_plan->>'feeUsdMicros')::numeric,
    (v_plan->>'cashDeltaUsdMicros')::numeric,
    v_plan
  ) ON CONFLICT (snapshot_event_id) DO NOTHING;
END;
$$;

-- 7. Read model v2: exit-engine state and legs; the monitor quotes the
-- remaining quantity after partial exits.
CREATE OR REPLACE FUNCTION solana_wallet_flow_read_model() RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH cursor_items AS (
    SELECT jsonb_build_object(
      'wallet', wallet,
      'latestSignature', latest_signature,
      'latestSlot', latest_slot::text,
      'captureComplete', capture_complete,
      'gapReason', gap_reason,
      'observedAtMs', observed_at_ms::text
    ) AS item
    FROM solana_wallet_cursors ORDER BY wallet
  ), latest_candidates AS (
    SELECT DISTINCT ON (s.acquisition_event_id)
      jsonb_strip_nulls(jsonb_build_object(
        'acquisition', e.canonical_payload,
        'snapshotEventId', d.snapshot_event_id,
        'snapshotObservedAtMs', s.observed_at_ms::text,
        'decision', d.decision,
        'reason', d.reason,
        'configId', d.config_id,
        'positionAtoms', CASE WHEN p.status = 'open'
          THEN p.remaining_quantity_atoms::text END
      )) AS item,
      s.acquisition_event_id,
      s.observed_at_ms
    FROM solana_candidate_decisions d
    JOIN solana_candidate_snapshots s ON s.event_id = d.snapshot_event_id
    JOIN normalized_events e ON e.id = s.acquisition_event_id
    LEFT JOIN solana_paper_positions p
      ON p.acquisition_event_id = s.acquisition_event_id
    WHERE (d.decision IN ('WATCH', 'ENTER') OR p.status = 'open')
      AND (p.id IS NULL OR p.status = 'open')
    ORDER BY s.acquisition_event_id, s.observed_at_ms DESC, s.event_id DESC
  ), position_items AS (
    SELECT jsonb_build_object(
      'id', p.id,
      'acquisitionEventId', p.acquisition_event_id,
      'wallet', p.wallet,
      'mint', p.mint,
      'status', p.status,
      'openedAtMs', p.opened_at_ms::text,
      'closedAtMs', CASE WHEN p.closed_at_ms IS NULL THEN NULL ELSE p.closed_at_ms::text END,
      'decisionLatencyMs', p.decision_latency_ms::text,
      'entryCostUsdMicros', p.entry_cost_usd_micros::text,
      'quantityAtoms', p.quantity_atoms::text,
      'remainingQuantityAtoms', p.remaining_quantity_atoms::text,
      'recouped', p.recouped,
      'peakReturnBps', p.peak_return_bps::text,
      'flowBreachCount', p.flow_breach_count,
      'noLiquidityCount', p.no_liquidity_count,
      'migrationCrossed', p.migration_crossed,
      'entryMigrationStatus', p.entry_migration_status,
      'exitReason', p.exit_reason,
      'exitProceedsUsdMicros', CASE WHEN p.exit_proceeds_usd_micros IS NULL
        THEN NULL ELSE p.exit_proceeds_usd_micros::text END,
      'realizedPnlUsdMicros', CASE WHEN p.realized_pnl_usd_micros IS NULL
        THEN NULL ELSE p.realized_pnl_usd_micros::text END,
      'exitLegs', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'legNo', l.leg_no,
          'reason', l.reason,
          'quantityAtoms', l.quantity_atoms::text,
          'quoteUsdMicros', l.quote_usd_micros::text,
          'proceedsUsdMicros', l.proceeds_usd_micros::text,
          'feeUsdMicros', l.fee_usd_micros::text,
          'exitedAtMs', l.exited_at_ms::text
        ) ORDER BY l.leg_no)
        FROM solana_paper_exit_legs l WHERE l.position_id = p.id
      ), '[]'::jsonb)
    ) AS item, p.opened_at_ms, p.id
    FROM solana_paper_positions p
    ORDER BY p.opened_at_ms DESC, p.id DESC
    LIMIT 100
  ), action_items AS (
    SELECT jsonb_build_object(
      'id', id,
      'snapshotEventId', snapshot_event_id,
      'acquisitionEventId', acquisition_event_id,
      'action', action,
      'status', status,
      'reason', reason,
      'quoteObservedAtMs', quote_observed_at_ms::text,
      'quoteExpiresAtMs', quote_expires_at_ms::text,
      'processedAtMs', processed_at_ms::text,
      'quantityAtoms', quantity_atoms::text,
      'quoteUsdMicros', quote_usd_micros::text,
      'feeUsdMicros', fee_usd_micros::text,
      'cashDeltaUsdMicros', cash_delta_usd_micros::text
    ) AS item, processed_at_ms, id
    FROM solana_paper_actions
    ORDER BY processed_at_ms DESC, id DESC
    LIMIT 100
  )
  SELECT jsonb_build_object(
    'cursors', COALESCE((SELECT jsonb_agg(item) FROM cursor_items), '[]'::jsonb),
    'openMints', COALESCE((SELECT jsonb_agg(item ORDER BY observed_at_ms, acquisition_event_id)
      FROM latest_candidates), '[]'::jsonb),
    'paperAccount', (
      SELECT jsonb_build_object(
        'initialCapitalUsdMicros', initial_capital_usd_micros::text,
        'reserveCapitalUsdMicros', reserve_capital_usd_micros::text,
        'cashBalanceUsdMicros', cash_balance_usd_micros::text,
        'realizedPnlUsdMicros', realized_pnl_usd_micros::text,
        'updatedAtMs', updated_at_ms::text
      ) FROM solana_paper_accounts WHERE id = 'solana-wallet-flow-paper'
    ),
    'positions', COALESCE((SELECT jsonb_agg(item ORDER BY opened_at_ms DESC, id DESC)
      FROM position_items), '[]'::jsonb),
    'actions', COALESCE((SELECT jsonb_agg(item ORDER BY processed_at_ms DESC, id DESC)
      FROM action_items), '[]'::jsonb),
    'strategyConfig', (SELECT jsonb_build_object(
      'id', id, 'configHash', config_hash, 'values', config_json
    ) FROM solana_strategy_configs WHERE active),
    'brokerConfig', (SELECT jsonb_build_object(
      'id', id, 'configHash', config_hash, 'values', config_json
    ) FROM solana_paper_broker_configs WHERE active)
  );
$$;

INSERT INTO schema_meta(version) VALUES (50);

COMMIT;
