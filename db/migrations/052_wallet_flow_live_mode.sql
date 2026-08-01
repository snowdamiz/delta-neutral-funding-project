BEGIN;

-- Live execution mode for the Solana wallet-flow strategy.
--
-- The collector remains a paper system: EXECUTION_MODE stays 'paper', the
-- paper broker keeps trading every decision, and nothing here touches the
-- existing paper evidence. Live trading is a default-off mirror: when the
-- operator explicitly arms live mode (HMAC-signed, approval-string-guarded),
-- each FILLED paper action additionally enqueues a live intent, bounded by
-- frozen per-trade and daily caps. A separate executor process — which holds
-- the only signing key and runs only under an explicit compose profile —
-- claims intents, executes them through Jupiter, and reports real fills back.
-- Two independent switches must both be on before a single lamport moves:
-- the database arm here, and the operator starting the executor with a key.

-- 1. Per-strategy execution mode. Only strategies seeded here can ever arm.
CREATE TABLE strategy_execution_modes (
  strategy_id text PRIMARY KEY REFERENCES strategy_controls(strategy_id),
  mode text NOT NULL DEFAULT 'paper' CHECK (mode IN ('paper', 'live')),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO strategy_execution_modes (strategy_id) VALUES ('solana_wallet_flow_quant');

CREATE FUNCTION strategy_execution_mode(p_strategy text) RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT mode FROM strategy_execution_modes WHERE strategy_id = p_strategy),
    'paper'
  );
$$;

ALTER TABLE operator_commands
  DROP CONSTRAINT operator_commands_action_check,
  ADD CONSTRAINT operator_commands_action_check CHECK (
    action IN (
      'pause_entries',
      'pause_all',
      'resume',
      'reconcile',
      'exit_position',
      'emergency_flatten',
      'alerts_test',
      'paper_reset',
      'wallet_config',
      'solana_wallet_config',
      'strategy_start',
      'strategy_stop',
      'strategy_arm_live',
      'strategy_disarm_live'
    )
  );

-- 2. Frozen live caps, one active row, immutable like the broker configs.
CREATE TABLE solana_live_configs (
  id text PRIMARY KEY CHECK (id ~ '^[a-z0-9-]{1,100}$'),
  config_hash char(64) NOT NULL UNIQUE CHECK (config_hash ~ '^[0-9a-f]{64}$'),
  config_json jsonb NOT NULL CHECK (jsonb_typeof(config_json) = 'object'),
  frozen boolean NOT NULL DEFAULT true CHECK (frozen),
  active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX solana_live_configs_one_active
  ON solana_live_configs(active) WHERE active;
INSERT INTO solana_live_configs (id, config_hash, config_json, active) VALUES (
  'solana-live-v1',
  'adc5c34e58dd1565d9dc942224e3ed6b0d1fc4eba0d7d17e4d78aae0b93c1c2e',
  '{
    "dailyCapUsdMicros":"1000000000",
    "intentTtlMs":"60000",
    "maxOpenPositions":"3",
    "maxSlippageBps":"300",
    "perTradeCapUsdMicros":"250000000"
  }'::jsonb,
  true
);
CREATE TRIGGER protect_frozen_solana_live_config
BEFORE UPDATE OR DELETE ON solana_live_configs
FOR EACH ROW EXECUTE FUNCTION protect_frozen_solana_config();

-- 3. Intents, live positions, and fills.
CREATE TABLE solana_live_intents (
  id text PRIMARY KEY CHECK (id ~ '^[A-Za-z0-9:_-]{1,220}$'),
  snapshot_event_id text NOT NULL UNIQUE
    REFERENCES solana_candidate_snapshots(event_id),
  acquisition_event_id text NOT NULL
    REFERENCES solana_wallet_acquisitions(event_id),
  config_id text NOT NULL REFERENCES solana_live_configs(id),
  kind text NOT NULL CHECK (kind IN ('ENTRY', 'EXIT')),
  mint text NOT NULL CHECK (mint ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  input_usd_micros numeric NOT NULL CHECK (input_usd_micros >= 0),
  fraction_bps integer NOT NULL CHECK (fraction_bps BETWEEN 0 AND 10000),
  max_slippage_bps integer NOT NULL CHECK (max_slippage_bps BETWEEN 1 AND 10000),
  reason text NOT NULL CHECK (reason ~ '^[A-Z][A-Z0-9_]{1,100}$'),
  status text NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'claimed', 'filled', 'failed', 'expired')
  ),
  failure_reason text,
  created_at_ms bigint NOT NULL CHECK (created_at_ms >= 0),
  expires_at_ms bigint NOT NULL CHECK (expires_at_ms > created_at_ms),
  claimed_at_ms bigint,
  claimed_by text,
  resolved_at_ms bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'ENTRY' AND input_usd_micros > 0 AND fraction_bps = 0)
    OR (kind = 'EXIT' AND input_usd_micros = 0 AND fraction_bps > 0))
);
CREATE INDEX solana_live_intents_pending
  ON solana_live_intents(status, expires_at_ms) WHERE status IN ('pending', 'claimed');

CREATE TABLE solana_live_positions (
  acquisition_event_id text PRIMARY KEY
    REFERENCES solana_wallet_acquisitions(event_id),
  mint text NOT NULL CHECK (mint ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  quantity_atoms numeric NOT NULL DEFAULT 0 CHECK (quantity_atoms >= 0),
  remaining_atoms numeric NOT NULL DEFAULT 0 CHECK (remaining_atoms >= 0),
  cost_usd_micros numeric NOT NULL DEFAULT 0 CHECK (cost_usd_micros >= 0),
  proceeds_usd_micros numeric NOT NULL DEFAULT 0 CHECK (proceeds_usd_micros >= 0),
  fee_lamports numeric NOT NULL DEFAULT 0 CHECK (fee_lamports >= 0),
  opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= 0),
  closed_at_ms bigint,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (remaining_atoms <= quantity_atoms),
  CHECK (status = 'open' OR remaining_atoms = 0)
);

CREATE TABLE solana_live_fills (
  signature text PRIMARY KEY CHECK (signature ~ '^[1-9A-HJ-NP-Za-km-z]{32,120}$'),
  intent_id text NOT NULL UNIQUE REFERENCES solana_live_intents(id),
  kind text NOT NULL CHECK (kind IN ('ENTRY', 'EXIT')),
  input_amount numeric NOT NULL CHECK (input_amount > 0),
  output_amount numeric NOT NULL CHECK (output_amount >= 0),
  fee_lamports numeric NOT NULL CHECK (fee_lamports >= 0),
  slot bigint NOT NULL CHECK (slot >= 0),
  confirmed_at_ms bigint NOT NULL CHECK (confirmed_at_ms >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 4. Arm and disarm, mirroring apply_strategy_control's audit shape. Arming
-- requires the literal approval string, an active frozen live config, a
-- configured cohort, and a started strategy; disarming is unconditional.
CREATE FUNCTION apply_strategy_execution_mode(
  p_strategy text,
  p_mode text,
  p_approval text,
  p_idempotency_key text,
  p_reason text,
  p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_action text := CASE WHEN p_mode = 'live'
    THEN 'strategy_arm_live' ELSE 'strategy_disarm_live' END;
  v_existing operator_commands%ROWTYPE;
  v_mode strategy_execution_modes%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_mode NOT IN ('paper', 'live')
     OR p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR length(p_reason) NOT BETWEEN 1 AND 500
     OR p_request_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid strategy execution mode request';
  END IF;

  LOCK TABLE operator_commands, strategy_execution_modes IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM operator_commands WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.action <> v_action
       OR v_existing.target <> p_strategy
       OR v_existing.reason <> p_reason
       OR v_existing.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'idempotency key reused for a different operator command';
    END IF;
    RETURN v_existing.result || jsonb_build_object('duplicate', true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM strategy_execution_modes WHERE strategy_id = p_strategy
  ) THEN
    RAISE EXCEPTION 'unknown strategy';
  END IF;
  IF p_mode = 'live' THEN
    IF p_approval <> 'ARM LIVE TRADING' THEN
      RAISE EXCEPTION 'live arming requires the explicit approval string';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM solana_live_configs WHERE active AND frozen) THEN
      RAISE EXCEPTION 'live arming requires an active frozen live configuration';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM solana_followed_wallets) THEN
      RAISE EXCEPTION 'live arming requires at least one configured Solana wallet';
    END IF;
    IF NOT strategy_enabled(p_strategy) THEN
      RAISE EXCEPTION 'live arming requires the strategy to be started';
    END IF;
  END IF;

  UPDATE strategy_execution_modes
  SET mode = p_mode, version = version + 1, updated_at = now()
  WHERE strategy_id = p_strategy
  RETURNING * INTO v_mode;

  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'action', v_action,
    'strategy', p_strategy,
    'status', 'applied',
    'duplicate', false,
    'mode', v_mode.mode,
    'version', v_mode.version::text
  );
  INSERT INTO operator_commands (
    id, action, target, idempotency_key, reason, request_hash,
    control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key, v_action, p_strategy,
    p_idempotency_key, p_reason, p_request_hash,
    (SELECT version FROM control_state WHERE singleton), v_result
  );
  RETURN v_result;
END;
$$;

-- Stopping the strategy, or emptying the cohort, disarms live mode.
CREATE FUNCTION disarm_live_on_strategy_stop() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT NEW.enabled THEN
    UPDATE strategy_execution_modes
    SET mode = 'paper', version = version + 1, updated_at = now()
    WHERE strategy_id = NEW.strategy_id AND mode = 'live';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER disarm_live_on_strategy_stop
AFTER UPDATE OF enabled ON strategy_controls
FOR EACH ROW EXECUTE FUNCTION disarm_live_on_strategy_stop();

-- 5. Intent creation: a mirror of FILLED paper actions, bounded by the caps.
CREATE FUNCTION enqueue_solana_live_intent(
  p_plan jsonb,
  p_snapshot solana_candidate_snapshots
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_config solana_live_configs%ROWTYPE;
  v_paper solana_paper_positions%ROWTYPE;
  v_live solana_live_positions%ROWTYPE;
  v_input numeric := 0;
  v_fraction integer := 0;
  v_kind text := p_plan->>'action';
  v_daily numeric;
BEGIN
  IF strategy_execution_mode('solana_wallet_flow_quant') <> 'live'
     OR v_kind NOT IN ('ENTRY', 'EXIT')
     OR p_plan->>'status' <> 'FILLED' THEN
    RETURN;
  END IF;
  SELECT * INTO STRICT v_config FROM solana_live_configs WHERE active AND frozen;

  IF v_kind = 'ENTRY' THEN
    v_input := LEAST(
      (p_plan->>'quoteUsdMicros')::numeric,
      (v_config.config_json->>'perTradeCapUsdMicros')::numeric
    );
    IF (SELECT count(*) FROM solana_live_positions WHERE status = 'open')
        >= (v_config.config_json->>'maxOpenPositions')::integer THEN
      RETURN;
    END IF;
    SELECT COALESCE(sum(input_usd_micros), 0) INTO v_daily
    FROM solana_live_intents
    WHERE kind = 'ENTRY' AND status IN ('pending', 'claimed', 'filled')
      AND created_at_ms / 86400000 = p_snapshot.observed_at_ms / 86400000;
    IF v_daily + v_input
        > (v_config.config_json->>'dailyCapUsdMicros')::numeric THEN
      RETURN;
    END IF;
  ELSE
    -- Mirror an exit only when a live position actually exists.
    SELECT * INTO v_live FROM solana_live_positions
    WHERE acquisition_event_id = p_snapshot.acquisition_event_id
      AND status = 'open';
    IF NOT FOUND THEN
      RETURN;
    END IF;
    IF (p_plan->>'partial')::boolean THEN
      -- Called before the paper writes, so the paper position still holds its
      -- pre-exit remaining quantity.
      SELECT * INTO STRICT v_paper FROM solana_paper_positions
      WHERE acquisition_event_id = p_snapshot.acquisition_event_id;
      v_fraction := LEAST(10000, GREATEST(1, trunc(
        (p_plan->>'quantityAtoms')::numeric * 10000
        / v_paper.remaining_quantity_atoms
      )::integer));
    ELSE
      v_fraction := 10000;
    END IF;
  END IF;

  INSERT INTO solana_live_intents (
    id, snapshot_event_id, acquisition_event_id, config_id, kind, mint,
    input_usd_micros, fraction_bps, max_slippage_bps, reason,
    created_at_ms, expires_at_ms
  ) VALUES (
    'live:' || p_snapshot.event_id, p_snapshot.event_id,
    p_snapshot.acquisition_event_id, v_config.id, v_kind, p_snapshot.mint,
    v_input, v_fraction,
    (v_config.config_json->>'maxSlippageBps')::integer,
    p_plan->>'reason', p_snapshot.observed_at_ms,
    p_snapshot.observed_at_ms + (v_config.config_json->>'intentTtlMs')::bigint
  ) ON CONFLICT (snapshot_event_id) DO NOTHING;
END;
$$;

-- 6. The executor's claim/report surface.
CREATE FUNCTION claim_solana_live_intents(
  p_executor_id text,
  p_now_ms bigint,
  p_limit integer
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF p_executor_id !~ '^[A-Za-z0-9:_-]{1,100}$'
     OR p_now_ms < 0 OR p_limit NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'invalid live intent claim request';
  END IF;
  UPDATE solana_live_intents
  SET status = 'expired', resolved_at_ms = p_now_ms
  WHERE status IN ('pending', 'claimed') AND expires_at_ms <= p_now_ms;

  WITH claimed AS (
    UPDATE solana_live_intents intent
    SET status = 'claimed', claimed_at_ms = p_now_ms, claimed_by = p_executor_id
    WHERE intent.id IN (
      SELECT id FROM solana_live_intents
      WHERE status = 'pending' AND expires_at_ms > p_now_ms
      ORDER BY created_at_ms, id
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
    )
    RETURNING intent.*
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'intentId', claimed.id,
    'kind', claimed.kind,
    'mint', claimed.mint,
    'acquisitionEventId', claimed.acquisition_event_id,
    'inputUsdMicros', claimed.input_usd_micros::text,
    'fractionBps', claimed.fraction_bps,
    'maxSlippageBps', claimed.max_slippage_bps,
    'reason', claimed.reason,
    'expiresAtMs', claimed.expires_at_ms::text,
    'liveRemainingAtoms', COALESCE((
      SELECT remaining_atoms::text FROM solana_live_positions
      WHERE acquisition_event_id = claimed.acquisition_event_id
        AND status = 'open'
    ), '0')
  ) ORDER BY claimed.created_at_ms, claimed.id), '[]'::jsonb)
  INTO v_items FROM claimed;
  RETURN v_items;
END;
$$;

CREATE FUNCTION claim_solana_live_request(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql
AS $$
BEGIN
  IF jsonb_typeof(p_request) <> 'object'
     OR p_request->>'executorId' !~ '^[A-Za-z0-9:_-]{1,100}$'
     OR p_request->>'nowMs' !~ '^(0|[1-9][0-9]*)$'
     OR p_request->>'limit' !~ '^[1-9][0-9]?$' THEN
    RAISE EXCEPTION 'invalid live intent claim request'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN claim_solana_live_intents(
    p_request->>'executorId',
    (p_request->>'nowMs')::bigint,
    (p_request->>'limit')::integer
  );
END;
$$;

CREATE FUNCTION record_solana_live_report(p_report jsonb) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_intent solana_live_intents%ROWTYPE;
  v_position solana_live_positions%ROWTYPE;
BEGIN
  IF jsonb_typeof(p_report) <> 'object'
     OR p_report->>'intentId' !~ '^[A-Za-z0-9:_-]{1,220}$'
     OR p_report->>'status' NOT IN ('filled', 'failed')
     OR p_report->>'resolvedAtMs' !~ '^(0|[1-9][0-9]*)$' THEN
    RAISE EXCEPTION 'invalid live execution report'
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO STRICT v_intent
  FROM solana_live_intents WHERE id = p_report->>'intentId';

  IF p_report->>'status' = 'failed' THEN
    IF v_intent.status IN ('filled', 'failed') THEN
      RETURN jsonb_build_object('recorded', false, 'status', v_intent.status);
    END IF;
    IF length(COALESCE(p_report->>'failureReason', '')) NOT BETWEEN 1 AND 500 THEN
      RAISE EXCEPTION 'live failure report requires a reason'
        USING ERRCODE = 'check_violation';
    END IF;
    UPDATE solana_live_intents
    SET status = 'failed',
        failure_reason = p_report->>'failureReason',
        resolved_at_ms = (p_report->>'resolvedAtMs')::bigint
    WHERE id = v_intent.id;
    RETURN jsonb_build_object('recorded', true, 'status', 'failed');
  END IF;

  IF p_report->>'signature' !~ '^[1-9A-HJ-NP-Za-km-z]{32,120}$'
     OR p_report->>'inputAmount' !~ '^[1-9][0-9]*$'
     OR p_report->>'outputAmount' !~ '^(0|[1-9][0-9]*)$'
     OR p_report->>'feeLamports' !~ '^(0|[1-9][0-9]*)$'
     OR p_report->>'slot' !~ '^(0|[1-9][0-9]*)$' THEN
    RAISE EXCEPTION 'invalid live fill report'
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM solana_live_fills WHERE signature = p_report->>'signature') THEN
    RETURN jsonb_build_object('recorded', false, 'status', 'filled');
  END IF;

  INSERT INTO solana_live_fills (
    signature, intent_id, kind, input_amount, output_amount, fee_lamports,
    slot, confirmed_at_ms
  ) VALUES (
    p_report->>'signature', v_intent.id, v_intent.kind,
    (p_report->>'inputAmount')::numeric, (p_report->>'outputAmount')::numeric,
    (p_report->>'feeLamports')::numeric, (p_report->>'slot')::bigint,
    (p_report->>'resolvedAtMs')::bigint
  );
  UPDATE solana_live_intents
  SET status = 'filled', resolved_at_ms = (p_report->>'resolvedAtMs')::bigint
  WHERE id = v_intent.id;

  IF v_intent.kind = 'ENTRY' THEN
    INSERT INTO solana_live_positions (
      acquisition_event_id, mint, quantity_atoms, remaining_atoms,
      cost_usd_micros, fee_lamports, opened_at_ms
    ) VALUES (
      v_intent.acquisition_event_id, v_intent.mint,
      (p_report->>'outputAmount')::numeric, (p_report->>'outputAmount')::numeric,
      (p_report->>'inputAmount')::numeric, (p_report->>'feeLamports')::numeric,
      (p_report->>'resolvedAtMs')::bigint
    )
    ON CONFLICT (acquisition_event_id) DO UPDATE SET
      quantity_atoms = solana_live_positions.quantity_atoms
        + EXCLUDED.quantity_atoms,
      remaining_atoms = solana_live_positions.remaining_atoms
        + EXCLUDED.remaining_atoms,
      cost_usd_micros = solana_live_positions.cost_usd_micros
        + EXCLUDED.cost_usd_micros,
      fee_lamports = solana_live_positions.fee_lamports + EXCLUDED.fee_lamports,
      updated_at = now();
  ELSE
    SELECT * INTO STRICT v_position
    FROM solana_live_positions
    WHERE acquisition_event_id = v_intent.acquisition_event_id;
    UPDATE solana_live_positions
    SET proceeds_usd_micros = proceeds_usd_micros
          + (p_report->>'outputAmount')::numeric,
        fee_lamports = fee_lamports + (p_report->>'feeLamports')::numeric,
        remaining_atoms = CASE
          WHEN v_intent.fraction_bps = 10000 THEN 0
          ELSE GREATEST(0, remaining_atoms - (p_report->>'inputAmount')::numeric)
        END,
        status = CASE
          WHEN v_intent.fraction_bps = 10000
            OR remaining_atoms - (p_report->>'inputAmount')::numeric <= 0
          THEN 'closed' ELSE 'open' END,
        closed_at_ms = CASE
          WHEN v_intent.fraction_bps = 10000
            OR remaining_atoms - (p_report->>'inputAmount')::numeric <= 0
          THEN (p_report->>'resolvedAtMs')::bigint END,
        updated_at = now()
    WHERE acquisition_event_id = v_intent.acquisition_event_id;
  END IF;
  RETURN jsonb_build_object('recorded', true, 'status', 'filled');
END;
$$;

-- 7. Fold the live mirror into the paper executor.
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

  -- The live mirror sees the paper position state at decision time, before
  -- the paper writes below mutate it.
  PERFORM enqueue_solana_live_intent(v_plan, v_snapshot);

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

-- 8. Live read model, folded into the wallet-flow state by the collector.
CREATE FUNCTION solana_live_read_model() RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'mode', strategy_execution_mode('solana_wallet_flow_quant'),
    'config', (SELECT jsonb_build_object(
      'id', id, 'configHash', config_hash, 'values', config_json
    ) FROM solana_live_configs WHERE active),
    'dailySpendUsdMicros', COALESCE((
      SELECT sum(input_usd_micros)::text FROM solana_live_intents
      WHERE kind = 'ENTRY' AND status IN ('pending', 'claimed', 'filled')
        AND created_at_ms / 86400000 = (
          SELECT COALESCE(max(observed_at_ms), 0) / 86400000
          FROM normalized_events
        )
    ), '0'),
    'intents', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id,
        'kind', kind,
        'mint', mint,
        'status', status,
        'reason', reason,
        'inputUsdMicros', input_usd_micros::text,
        'fractionBps', fraction_bps,
        'failureReason', failure_reason,
        'createdAtMs', created_at_ms::text,
        'expiresAtMs', expires_at_ms::text,
        'resolvedAtMs', CASE WHEN resolved_at_ms IS NULL
          THEN NULL ELSE resolved_at_ms::text END
      ) ORDER BY created_at_ms DESC, id DESC)
      FROM (SELECT * FROM solana_live_intents
            ORDER BY created_at_ms DESC, id DESC LIMIT 50) recent
    ), '[]'::jsonb),
    'positions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'acquisitionEventId', acquisition_event_id,
        'mint', mint,
        'status', status,
        'quantityAtoms', quantity_atoms::text,
        'remainingAtoms', remaining_atoms::text,
        'costUsdMicros', cost_usd_micros::text,
        'proceedsUsdMicros', proceeds_usd_micros::text,
        'feeLamports', fee_lamports::text,
        'openedAtMs', opened_at_ms::text,
        'closedAtMs', CASE WHEN closed_at_ms IS NULL
          THEN NULL ELSE closed_at_ms::text END
      ) ORDER BY opened_at_ms DESC)
      FROM solana_live_positions
    ), '[]'::jsonb),
    'fills', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'signature', signature,
        'intentId', intent_id,
        'kind', kind,
        'inputAmount', input_amount::text,
        'outputAmount', output_amount::text,
        'feeLamports', fee_lamports::text,
        'slot', slot::text,
        'confirmedAtMs', confirmed_at_ms::text
      ) ORDER BY confirmed_at_ms DESC, signature DESC)
      FROM (SELECT * FROM solana_live_fills
            ORDER BY confirmed_at_ms DESC, signature DESC LIMIT 50) recent
    ), '[]'::jsonb)
  );
$$;

INSERT INTO schema_meta(version) VALUES (52);

COMMIT;
