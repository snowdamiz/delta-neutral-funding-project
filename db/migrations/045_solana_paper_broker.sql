BEGIN;

ALTER TABLE normalized_events
  DROP CONSTRAINT normalized_events_source_sequence_unique;
CREATE UNIQUE INDEX normalized_events_source_sequence_unique
  ON normalized_events(source, event_type, source_sequence)
  WHERE event_type <> 'SolanaCandidateSnapshot';
CREATE UNIQUE INDEX normalized_events_candidate_snapshot_sequence_unique
  ON normalized_events(source, event_type, source_sequence, observed_at_ms)
  WHERE event_type = 'SolanaCandidateSnapshot';

CREATE OR REPLACE FUNCTION enforce_source_continuity() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_prior normalized_events%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(NEW.source));
  IF EXISTS (
    SELECT 1 FROM normalized_events WHERE idempotency_key = NEW.idempotency_key
  ) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_prior
  FROM normalized_events
  WHERE source = NEW.source
  ORDER BY source_slot DESC, received_at DESC, id DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;
  IF NEW.event_type = 'SolanaCandidateSnapshot'
     AND v_prior.event_type = 'SolanaCandidateSnapshot'
     AND NEW.source_sequence = v_prior.source_sequence
     AND NEW.source_slot = v_prior.source_slot
     AND NEW.observed_at_ms > v_prior.observed_at_ms THEN
    RETURN NEW;
  END IF;
  IF NEW.source_sequence ~ '^(0|[1-9][0-9]*)$'
     AND v_prior.source_sequence ~ '^(0|[1-9][0-9]*)$' THEN
    IF NEW.source_sequence::numeric = v_prior.source_sequence::numeric + 1
       AND NEW.source_slot >= v_prior.source_slot THEN
      RETURN NEW;
    END IF;
    IF NEW.source_sequence = v_prior.source_sequence
       AND NEW.source_slot = v_prior.source_slot
       AND NOT EXISTS (
         SELECT 1 FROM normalized_events
         WHERE source = NEW.source
           AND event_type = NEW.event_type
           AND source_sequence = NEW.source_sequence
       ) THEN
      RETURN NEW;
    END IF;
  ELSIF NEW.source_slot > v_prior.source_slot THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'source sequence gap or regression for %', NEW.source;
END;
$$;

CREATE TABLE solana_paper_broker_configs (
  id text PRIMARY KEY CHECK (id ~ '^[a-z0-9-]{1,100}$'),
  config_hash char(64) NOT NULL UNIQUE CHECK (config_hash ~ '^[0-9a-f]{64}$'),
  config_json jsonb NOT NULL CHECK (jsonb_typeof(config_json) = 'object'),
  frozen boolean NOT NULL DEFAULT true CHECK (frozen),
  active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX solana_paper_broker_configs_one_active
  ON solana_paper_broker_configs(active) WHERE active;
INSERT INTO solana_paper_broker_configs (id, config_hash, config_json, active) VALUES (
  'solana-paper-broker-v1',
  'd4c53e5d32aca8a236ceba2cc4db2ecfdf2509c0258a80d241392f8877cb9940',
  '{
    "accountRentUsdMicros":"500000",
    "initialCapitalUsdMicros":"1000000000",
    "maximumHoldMs":"900000",
    "minimumBuyerRetentionBps":"5000",
    "minimumDecisionLatencyMs":"500",
    "networkFeeUsdMicros":"20000",
    "paperSlippageBps":"100",
    "quoteValidityMs":"30000",
    "reserveCapitalUsdMicros":"300000000"
  }'::jsonb,
  true
);

CREATE TABLE solana_paper_accounts (
  id text PRIMARY KEY,
  config_id text NOT NULL REFERENCES solana_paper_broker_configs(id),
  initial_capital_usd_micros numeric NOT NULL CHECK (initial_capital_usd_micros > 0),
  reserve_capital_usd_micros numeric NOT NULL CHECK (reserve_capital_usd_micros >= 0),
  cash_balance_usd_micros numeric NOT NULL CHECK (cash_balance_usd_micros >= 0),
  realized_pnl_usd_micros numeric NOT NULL DEFAULT 0,
  updated_at_ms bigint NOT NULL CHECK (updated_at_ms >= 0)
);
INSERT INTO solana_paper_accounts VALUES (
  'solana-wallet-flow-paper', 'solana-paper-broker-v1', 1000000000,
  300000000, 1000000000, 0, 0
);

CREATE TABLE solana_paper_positions (
  id text PRIMARY KEY,
  acquisition_event_id text NOT NULL UNIQUE REFERENCES solana_wallet_acquisitions(event_id),
  wallet text NOT NULL,
  mint text NOT NULL,
  status text NOT NULL CHECK (status IN ('open', 'closed')),
  config_id text NOT NULL REFERENCES solana_paper_broker_configs(id),
  entry_snapshot_event_id text NOT NULL REFERENCES solana_candidate_snapshots(event_id),
  entry_decision_at_ms bigint NOT NULL CHECK (entry_decision_at_ms >= 0),
  opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= entry_decision_at_ms),
  decision_latency_ms bigint NOT NULL CHECK (decision_latency_ms >= 0),
  entry_input_usd_micros numeric NOT NULL CHECK (entry_input_usd_micros > 0),
  entry_cost_usd_micros numeric NOT NULL CHECK (entry_cost_usd_micros >= entry_input_usd_micros),
  quantity_atoms numeric NOT NULL CHECK (quantity_atoms > 0),
  entry_transfer_fee_atoms numeric NOT NULL CHECK (entry_transfer_fee_atoms >= 0),
  entry_network_fee_usd_micros numeric NOT NULL CHECK (entry_network_fee_usd_micros >= 0),
  entry_rent_usd_micros numeric NOT NULL CHECK (entry_rent_usd_micros >= 0),
  entry_migration_status text NOT NULL,
  entry_unlinked_buyer_count integer NOT NULL CHECK (entry_unlinked_buyer_count >= 0),
  exit_snapshot_event_id text REFERENCES solana_candidate_snapshots(event_id),
  closed_at_ms bigint,
  exit_reason text,
  exit_quote_usd_micros numeric CHECK (exit_quote_usd_micros >= 0),
  exit_proceeds_usd_micros numeric CHECK (exit_proceeds_usd_micros >= 0),
  exit_network_fee_usd_micros numeric CHECK (exit_network_fee_usd_micros >= 0),
  realized_pnl_usd_micros numeric,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (status = 'open' AND exit_snapshot_event_id IS NULL AND closed_at_ms IS NULL)
    OR
    (status = 'closed' AND exit_snapshot_event_id IS NOT NULL
      AND closed_at_ms IS NOT NULL AND exit_reason IS NOT NULL
      AND exit_quote_usd_micros IS NOT NULL AND exit_proceeds_usd_micros IS NOT NULL
      AND realized_pnl_usd_micros IS NOT NULL)
  )
);
CREATE UNIQUE INDEX solana_paper_positions_one_open
  ON solana_paper_positions(status) WHERE status = 'open';

CREATE TABLE solana_paper_actions (
  id text PRIMARY KEY,
  snapshot_event_id text NOT NULL UNIQUE REFERENCES solana_candidate_snapshots(event_id),
  acquisition_event_id text NOT NULL REFERENCES solana_wallet_acquisitions(event_id),
  position_id text REFERENCES solana_paper_positions(id),
  config_id text NOT NULL REFERENCES solana_paper_broker_configs(id),
  action text NOT NULL CHECK (action IN ('ENTRY', 'EXIT', 'HOLD', 'SKIP')),
  status text NOT NULL CHECK (status IN ('FILLED', 'PLANNED', 'REJECTED')),
  reason text NOT NULL CHECK (reason ~ '^[A-Z][A-Z0-9_]{1,100}$'),
  quote_observed_at_ms bigint NOT NULL CHECK (quote_observed_at_ms >= 0),
  quote_expires_at_ms bigint NOT NULL CHECK (quote_expires_at_ms >= quote_observed_at_ms),
  processed_at_ms bigint NOT NULL CHECK (processed_at_ms >= quote_observed_at_ms),
  quantity_atoms numeric NOT NULL CHECK (quantity_atoms >= 0),
  quote_usd_micros numeric NOT NULL CHECK (quote_usd_micros >= 0),
  fee_usd_micros numeric NOT NULL CHECK (fee_usd_micros >= 0),
  cash_delta_usd_micros numeric NOT NULL,
  evidence jsonb NOT NULL CHECK (jsonb_typeof(evidence) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX solana_paper_actions_time
  ON solana_paper_actions(processed_at_ms DESC, action, status);

CREATE FUNCTION plan_solana_paper_action(
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

  SELECT * INTO v_position
  FROM solana_paper_positions
  WHERE acquisition_event_id = v_snapshot.acquisition_event_id AND status = 'open';
  IF FOUND THEN
    SELECT * INTO STRICT v_entry_snapshot
    FROM solana_candidate_snapshots WHERE event_id = v_position.entry_snapshot_event_id;
    v_action := 'HOLD'; v_status := 'PLANNED'; v_reason := 'HEALTHY';
    IF v_decision.decision = 'REJECT' THEN
      v_reason := v_decision.reason;
    ELSIF v_snapshot.migration_status <> v_position.entry_migration_status THEN
      v_reason := 'MIGRATION_CHANGED';
    ELSIF v_snapshot.observed_at_ms - v_position.opened_at_ms >=
        (v_config.config_json->>'maximumHoldMs')::bigint THEN
      v_reason := 'TIME_STOP';
    ELSIF v_snapshot.net_quote_inflow_usd_micros = 0
       OR (v_entry_snapshot.unlinked_buyer_count > 0
         AND v_snapshot.unlinked_buyer_count * 10000
           < v_entry_snapshot.unlinked_buyer_count
             * (v_config.config_json->>'minimumBuyerRetentionBps')::integer) THEN
      v_reason := 'ORGANIC_FLOW_COLLAPSE';
    ELSIF COALESCE(v_payload->>'paperPositionAtoms', '0')::numeric <> v_position.quantity_atoms THEN
      v_reason := 'POSITION_QUOTE_MISMATCH';
    ELSIF COALESCE(v_payload->>'positionSellOutputUsdMicros', '0')::numeric = 0
       OR COALESCE(v_payload->>'positionSellImpactBps', '10000')::integer > 1000 THEN
      v_reason := 'EXIT_NO_LIQUIDITY';
    END IF;

    IF v_reason <> 'HEALTHY' THEN
      v_action := 'EXIT';
      IF p_processing_at_ms - v_snapshot.observed_at_ms >
          (v_config.config_json->>'quoteValidityMs')::bigint THEN
        v_status := 'REJECTED'; v_reason := 'QUOTE_EXPIRED';
      ELSE
        v_status := 'FILLED';
        v_quantity := v_position.quantity_atoms;
        v_quote_usd := COALESCE(v_payload->>'positionSellOutputUsdMicros', '0')::numeric;
        IF v_quote_usd > 0 THEN
          v_fee_usd := (v_config.config_json->>'networkFeeUsdMicros')::numeric;
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
    ELSIF v_decision.decision = 'REJECT' THEN
      v_action := 'SKIP'; v_status := 'REJECTED'; v_reason := v_decision.reason;
    ELSIF v_decision.decision <> 'ENTER' THEN
      v_action := 'HOLD'; v_status := 'PLANNED'; v_reason := v_decision.reason;
    ELSIF p_processing_at_ms - v_snapshot.observed_at_ms >
        (v_config.config_json->>'quoteValidityMs')::bigint THEN
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
      ELSIF EXISTS (SELECT 1 FROM solana_paper_positions WHERE status = 'open') THEN
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
        v_fee_usd := (v_config.config_json->>'networkFeeUsdMicros')::numeric
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
    'brokerConfigHash', v_config.config_hash
  );
END;
$$;

CREATE FUNCTION execute_solana_paper_snapshot(p_snapshot_event_id text) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_snapshot solana_candidate_snapshots%ROWTYPE;
  v_plan jsonb;
  v_position_id text;
  v_first_enter_ms bigint;
  v_entry_cost numeric;
  v_exit_proceeds numeric;
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
      entry_rent_usd_micros, entry_migration_status, entry_unlinked_buyer_count
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
      v_snapshot.migration_status, v_snapshot.unlinked_buyer_count
    );
    UPDATE solana_paper_accounts SET
      cash_balance_usd_micros = cash_balance_usd_micros - v_entry_cost,
      updated_at_ms = v_snapshot.observed_at_ms
    WHERE id = 'solana-wallet-flow-paper';
  ELSIF v_plan->>'action' = 'EXIT' AND v_plan->>'status' = 'FILLED' THEN
    v_exit_proceeds := (v_plan->>'cashDeltaUsdMicros')::numeric;
    UPDATE solana_paper_positions SET
      status = 'closed',
      exit_snapshot_event_id = p_snapshot_event_id,
      closed_at_ms = v_snapshot.observed_at_ms,
      exit_reason = v_plan->>'reason',
      exit_quote_usd_micros = (v_plan->>'quoteUsdMicros')::numeric,
      exit_proceeds_usd_micros = v_exit_proceeds,
      exit_network_fee_usd_micros = (v_plan->>'feeUsdMicros')::numeric,
      realized_pnl_usd_micros = v_exit_proceeds - entry_cost_usd_micros
    WHERE id = v_position_id AND status = 'open';
    UPDATE solana_paper_accounts SET
      cash_balance_usd_micros = cash_balance_usd_micros + v_exit_proceeds,
      realized_pnl_usd_micros = realized_pnl_usd_micros
        + v_exit_proceeds
        - (SELECT entry_cost_usd_micros FROM solana_paper_positions WHERE id = v_position_id),
      updated_at_ms = v_snapshot.observed_at_ms
    WHERE id = 'solana-wallet-flow-paper';
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

CREATE FUNCTION trade_solana_candidate_decision() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM execute_solana_paper_snapshot(NEW.snapshot_event_id);
  RETURN NEW;
END;
$$;
CREATE TRIGGER trade_solana_candidate_decision
AFTER INSERT ON solana_candidate_decisions
FOR EACH ROW EXECUTE FUNCTION trade_solana_candidate_decision();

CREATE FUNCTION solana_wallet_flow_read_model() RETURNS jsonb
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
        'positionAtoms', CASE WHEN p.status = 'open' THEN p.quantity_atoms::text END
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
      'id', id,
      'acquisitionEventId', acquisition_event_id,
      'wallet', wallet,
      'mint', mint,
      'status', status,
      'openedAtMs', opened_at_ms::text,
      'closedAtMs', CASE WHEN closed_at_ms IS NULL THEN NULL ELSE closed_at_ms::text END,
      'decisionLatencyMs', decision_latency_ms::text,
      'entryCostUsdMicros', entry_cost_usd_micros::text,
      'quantityAtoms', quantity_atoms::text,
      'exitReason', exit_reason,
      'exitProceedsUsdMicros', CASE WHEN exit_proceeds_usd_micros IS NULL
        THEN NULL ELSE exit_proceeds_usd_micros::text END,
      'realizedPnlUsdMicros', CASE WHEN realized_pnl_usd_micros IS NULL
        THEN NULL ELSE realized_pnl_usd_micros::text END
    ) AS item, opened_at_ms, id
    FROM solana_paper_positions
    ORDER BY opened_at_ms DESC, id DESC
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

INSERT INTO schema_meta(version) VALUES (45);

COMMIT;
