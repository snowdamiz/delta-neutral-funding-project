BEGIN;

CREATE TABLE solana_validation_windows (
  id text PRIMARY KEY CHECK (id ~ '^[a-z0-9-]{1,100}$'),
  start_at_ms bigint NOT NULL CHECK (start_at_ms >= 0),
  end_at_ms bigint NOT NULL CHECK (end_at_ms = start_at_ms + 7776000000),
  training_cutoff_ms bigint NOT NULL CHECK (training_cutoff_ms < start_at_ms),
  wallets jsonb NOT NULL CHECK (
    jsonb_typeof(wallets) = 'array'
    AND jsonb_array_length(wallets) BETWEEN 1 AND 100
  ),
  strategy_config_id text NOT NULL REFERENCES solana_strategy_configs(id),
  strategy_config_hash char(64) NOT NULL,
  broker_config_id text NOT NULL REFERENCES solana_paper_broker_configs(id),
  broker_config_hash char(64) NOT NULL,
  maximum_drawdown_bps integer NOT NULL CHECK (maximum_drawdown_bps BETWEEN 1 AND 10000),
  minimum_cohort_trades integer NOT NULL DEFAULT 20 CHECK (minimum_cohort_trades > 0),
  bootstrap_samples integer NOT NULL DEFAULT 2000 CHECK (bootstrap_samples BETWEEN 100 AND 10000),
  bootstrap_seed bigint NOT NULL DEFAULT 42,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE solana_validation_control_trades (
  window_id text NOT NULL REFERENCES solana_validation_windows(id),
  variant text NOT NULL CHECK (variant IN ('raw_wallet_copy', 'quant_only')),
  trade_id text NOT NULL,
  cohort text NOT NULL CHECK (cohort IN ('pump_launch', 'established_token')),
  entered_at_ms bigint NOT NULL,
  exited_at_ms bigint NOT NULL CHECK (exited_at_ms >= entered_at_ms),
  net_pnl_usd_micros numeric NOT NULL,
  evidence_hash char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (window_id, variant, trade_id)
);

CREATE TABLE solana_validation_stress_results (
  window_id text NOT NULL REFERENCES solana_validation_windows(id),
  scenario text NOT NULL CHECK (
    scenario IN ('creator_cluster_dump', 'rpc_gap', 'quote_expiry', 'total_loss')
  ),
  passed boolean NOT NULL DEFAULT false,
  completed_at_ms bigint,
  evidence_hash char(64) CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
  PRIMARY KEY (window_id, scenario),
  CHECK (
    (completed_at_ms IS NULL AND evidence_hash IS NULL AND NOT passed)
    OR (completed_at_ms IS NOT NULL AND evidence_hash IS NOT NULL)
  )
);

CREATE FUNCTION protect_frozen_solana_config() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE'
     OR NEW.id <> OLD.id
     OR NEW.config_hash <> OLD.config_hash
     OR NEW.config_json <> OLD.config_json
     OR NEW.frozen <> OLD.frozen
     OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'frozen Solana configuration is immutable'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER protect_frozen_solana_strategy_config
BEFORE UPDATE OR DELETE ON solana_strategy_configs
FOR EACH ROW EXECUTE FUNCTION protect_frozen_solana_config();
CREATE TRIGGER protect_frozen_solana_broker_config
BEFORE UPDATE OR DELETE ON solana_paper_broker_configs
FOR EACH ROW EXECUTE FUNCTION protect_frozen_solana_config();

CREATE FUNCTION protect_solana_validation_window() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'frozen Solana validation window is immutable'
    USING ERRCODE = 'check_violation';
END;
$$;
CREATE TRIGGER protect_solana_validation_window
BEFORE UPDATE OR DELETE ON solana_validation_windows
FOR EACH ROW EXECUTE FUNCTION protect_solana_validation_window();

CREATE FUNCTION start_solana_validation_window(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_id text;
  v_start bigint;
  v_training_cutoff bigint;
  v_max_drawdown integer;
  v_wallets jsonb;
  v_strategy solana_strategy_configs%ROWTYPE;
  v_broker solana_paper_broker_configs%ROWTYPE;
BEGIN
  IF jsonb_typeof(p_request) <> 'object'
     OR p_request->>'windowId' !~ '^[a-z0-9-]{1,100}$'
     OR p_request->>'startAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR p_request->>'trainingCutoffMs' !~ '^(0|[1-9][0-9]*)$'
     OR p_request->>'maximumDrawdownBps' !~ '^[1-9][0-9]*$'
     OR jsonb_typeof(p_request->'wallets') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_request->'wallets') NOT BETWEEN 1 AND 100
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_request->'wallets') item
       WHERE jsonb_typeof(item) <> 'string'
         OR item #>> '{}' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
     )
     OR (SELECT count(*) FROM jsonb_array_elements_text(p_request->'wallets'))
       <> (SELECT count(DISTINCT value)
           FROM jsonb_array_elements_text(p_request->'wallets') item(value)) THEN
    RAISE EXCEPTION 'invalid frozen Solana validation request'
      USING ERRCODE = 'check_violation';
  END IF;
  v_id := p_request->>'windowId';
  v_start := (p_request->>'startAtMs')::bigint;
  v_training_cutoff := (p_request->>'trainingCutoffMs')::bigint;
  v_max_drawdown := (p_request->>'maximumDrawdownBps')::integer;
  v_wallets := p_request->'wallets';
  IF v_training_cutoff >= v_start
     OR v_max_drawdown NOT BETWEEN 1 AND 10000
     OR v_start <= COALESCE((SELECT max(observed_at_ms) FROM normalized_events), -1)
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements_text(v_wallets) requested(wallet)
       LEFT JOIN solana_wallet_cursors cursor ON cursor.wallet = requested.wallet
       WHERE cursor.wallet IS NULL OR NOT cursor.capture_complete
     ) THEN
    RAISE EXCEPTION 'Solana validation must start in the future with complete wallet capture'
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO STRICT v_strategy FROM solana_strategy_configs WHERE active AND frozen;
  SELECT * INTO STRICT v_broker FROM solana_paper_broker_configs WHERE active AND frozen;
  INSERT INTO solana_validation_windows (
    id, start_at_ms, end_at_ms, training_cutoff_ms, wallets,
    strategy_config_id, strategy_config_hash, broker_config_id,
    broker_config_hash, maximum_drawdown_bps
  ) VALUES (
    v_id, v_start, v_start + 7776000000, v_training_cutoff, v_wallets,
    v_strategy.id, v_strategy.config_hash, v_broker.id, v_broker.config_hash,
    v_max_drawdown
  );
  INSERT INTO solana_validation_stress_results (window_id, scenario)
  SELECT v_id, scenario FROM unnest(ARRAY[
    'creator_cluster_dump', 'rpc_gap', 'quote_expiry', 'total_loss'
  ]) scenario;
  RETURN jsonb_build_object(
    'windowId', v_id,
    'startAtMs', v_start::text,
    'endAtMs', (v_start + 7776000000)::text,
    'strategyConfigHash', v_strategy.config_hash,
    'brokerConfigHash', v_broker.config_hash,
    'frozen', true
  );
END;
$$;

CREATE FUNCTION record_solana_validation_evidence(p_evidence jsonb) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_window solana_validation_windows%ROWTYPE;
  v_kind text;
  v_inserted boolean;
BEGIN
  IF jsonb_typeof(p_evidence) <> 'object'
     OR p_evidence->>'windowId' !~ '^[a-z0-9-]{1,100}$'
     OR p_evidence->>'kind' NOT IN ('control', 'stress')
     OR p_evidence->>'evidenceHash' !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid Solana validation evidence'
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO STRICT v_window
  FROM solana_validation_windows WHERE id = p_evidence->>'windowId';
  v_kind := p_evidence->>'kind';
  IF v_kind = 'stress' THEN
    IF p_evidence->>'scenario'
         NOT IN ('creator_cluster_dump', 'rpc_gap', 'quote_expiry', 'total_loss')
       OR jsonb_typeof(p_evidence->'passed') IS DISTINCT FROM 'boolean'
       OR p_evidence->>'completedAtMs' !~ '^(0|[1-9][0-9]*)$'
       OR (p_evidence->>'completedAtMs')::bigint < v_window.start_at_ms THEN
      RAISE EXCEPTION 'invalid Solana validation stress evidence'
        USING ERRCODE = 'check_violation';
    END IF;
    UPDATE solana_validation_stress_results SET
      passed = (p_evidence->>'passed')::boolean,
      completed_at_ms = (p_evidence->>'completedAtMs')::bigint,
      evidence_hash = p_evidence->>'evidenceHash'
    WHERE window_id = v_window.id
      AND scenario = p_evidence->>'scenario'
      AND evidence_hash IS NULL;
    v_inserted := FOUND;
    IF NOT v_inserted AND NOT EXISTS (
      SELECT 1 FROM solana_validation_stress_results
      WHERE window_id = v_window.id
        AND scenario = p_evidence->>'scenario'
        AND passed = (p_evidence->>'passed')::boolean
        AND completed_at_ms = (p_evidence->>'completedAtMs')::bigint
        AND evidence_hash = p_evidence->>'evidenceHash'
    ) THEN
      RAISE EXCEPTION 'Solana validation stress evidence conflict';
    END IF;
  ELSE
    IF p_evidence->>'variant' NOT IN ('raw_wallet_copy', 'quant_only')
       OR p_evidence->>'tradeId' !~ '^[A-Za-z0-9:_-]{1,200}$'
       OR p_evidence->>'cohort' NOT IN ('pump_launch', 'established_token')
       OR p_evidence->>'enteredAtMs' !~ '^(0|[1-9][0-9]*)$'
       OR p_evidence->>'exitedAtMs' !~ '^(0|[1-9][0-9]*)$'
       OR p_evidence->>'netPnlUsdMicros' !~ '^-?(0|[1-9][0-9]*)$'
       OR p_evidence->>'netPnlUsdMicros' = '-0'
       OR (p_evidence->>'enteredAtMs')::bigint < v_window.start_at_ms
       OR (p_evidence->>'exitedAtMs')::bigint > v_window.end_at_ms
       OR (p_evidence->>'exitedAtMs')::bigint < (p_evidence->>'enteredAtMs')::bigint THEN
      RAISE EXCEPTION 'invalid Solana validation control trade'
        USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO solana_validation_control_trades (
      window_id, variant, trade_id, cohort, entered_at_ms, exited_at_ms,
      net_pnl_usd_micros, evidence_hash
    ) VALUES (
      v_window.id, p_evidence->>'variant', p_evidence->>'tradeId',
      p_evidence->>'cohort', (p_evidence->>'enteredAtMs')::bigint,
      (p_evidence->>'exitedAtMs')::bigint,
      (p_evidence->>'netPnlUsdMicros')::numeric,
      p_evidence->>'evidenceHash'
    ) ON CONFLICT DO NOTHING;
    v_inserted := FOUND;
    IF NOT v_inserted AND NOT EXISTS (
      SELECT 1 FROM solana_validation_control_trades
      WHERE window_id = v_window.id
        AND variant = p_evidence->>'variant'
        AND trade_id = p_evidence->>'tradeId'
        AND cohort = p_evidence->>'cohort'
        AND entered_at_ms = (p_evidence->>'enteredAtMs')::bigint
        AND exited_at_ms = (p_evidence->>'exitedAtMs')::bigint
        AND net_pnl_usd_micros = (p_evidence->>'netPnlUsdMicros')::numeric
        AND evidence_hash = p_evidence->>'evidenceHash'
    ) THEN
      RAISE EXCEPTION 'Solana validation control trade conflict';
    END IF;
  END IF;
  RETURN jsonb_build_object('recorded', v_inserted, 'kind', v_kind);
END;
$$;

CREATE FUNCTION deterministic_bootstrap_lower_95(
  p_values numeric[],
  p_samples integer,
  p_seed bigint
) RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_count integer := COALESCE(array_length(p_values, 1), 0);
  v_sample integer;
  v_draw integer;
  v_index integer;
  v_mean numeric;
  v_means numeric[] := ARRAY[]::numeric[];
BEGIN
  IF v_count = 0 THEN RETURN 0; END IF;
  IF p_samples NOT BETWEEN 100 AND 10000 OR p_values @> ARRAY[NULL]::numeric[] THEN
    RAISE EXCEPTION 'invalid deterministic bootstrap input'
      USING ERRCODE = 'check_violation';
  END IF;
  FOR v_sample IN 0..p_samples - 1 LOOP
    v_mean := 0;
    FOR v_draw IN 0..v_count - 1 LOOP
      v_index := mod(
        hashtextextended(v_sample::text || ':' || v_draw::text, p_seed)::numeric
          + 9223372036854775808,
        v_count
      )::integer + 1;
      v_mean := v_mean + p_values[v_index];
    END LOOP;
    v_means := array_append(v_means, v_mean / v_count);
  END LOOP;
  RETURN (SELECT percentile_disc(0.05) WITHIN GROUP (ORDER BY value)
          FROM unnest(v_means) value);
END;
$$;

CREATE FUNCTION solana_validation_report(
  p_window_id text,
  p_as_of_ms bigint
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_window solana_validation_windows%ROWTYPE;
  v_duration_complete boolean;
  v_capture_complete boolean;
  v_selection_frozen boolean;
  v_eligible_enters integer;
  v_trade_count integer;
  v_open_count integer;
  v_strategy_net numeric;
  v_net_without_best_three numeric;
  v_return_values numeric[];
  v_lower_95 numeric;
  v_max_drawdown_bps integer;
  v_latency_complete boolean;
  v_costs_complete boolean;
  v_pump_count integer;
  v_established_count integer;
  v_pump_lower_95 numeric;
  v_established_lower_95 numeric;
  v_raw_count integer;
  v_quant_count integer;
  v_raw_net numeric;
  v_quant_net numeric;
  v_stress_count integer;
  v_controls_complete boolean;
  v_cohorts_pass boolean;
  v_passed boolean;
BEGIN
  SELECT * INTO STRICT v_window
  FROM solana_validation_windows WHERE id = p_window_id;
  IF p_as_of_ms < v_window.start_at_ms THEN
    RAISE EXCEPTION 'validation report precedes its frozen window';
  END IF;
  v_duration_complete := p_as_of_ms >= v_window.end_at_ms;
  SELECT NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(v_window.wallets) cohort(wallet)
    WHERE (
      SELECT count(DISTINCT ((checkpoint.observed_at_ms - v_window.start_at_ms) / 86400000))
      FROM solana_wallet_checkpoints checkpoint
      WHERE checkpoint.wallet = cohort.wallet
        AND checkpoint.status = 'complete'
        AND checkpoint.observed_at_ms >= v_window.start_at_ms
        AND checkpoint.observed_at_ms < v_window.end_at_ms
    ) < 90
  ) AND NOT EXISTS (
    SELECT 1 FROM solana_wallet_checkpoints checkpoint
    WHERE checkpoint.wallet IN (SELECT jsonb_array_elements_text(v_window.wallets))
      AND checkpoint.status = 'gap'
      AND checkpoint.observed_at_ms >= v_window.start_at_ms
      AND checkpoint.observed_at_ms < v_window.end_at_ms
  ) INTO v_capture_complete;
  SELECT EXISTS (
    SELECT 1 FROM solana_strategy_configs strategy
    JOIN solana_paper_broker_configs broker ON true
    WHERE strategy.id = v_window.strategy_config_id
      AND strategy.config_hash = v_window.strategy_config_hash
      AND strategy.frozen
      AND broker.id = v_window.broker_config_id
      AND broker.config_hash = v_window.broker_config_hash
      AND broker.frozen
  ) INTO v_selection_frozen;
  SELECT count(DISTINCT snapshot.acquisition_event_id)::integer
  INTO v_eligible_enters
  FROM solana_candidate_decisions decision
  JOIN solana_candidate_snapshots snapshot ON snapshot.event_id = decision.snapshot_event_id
  WHERE decision.config_id = v_window.strategy_config_id
    AND decision.decision = 'ENTER'
    AND snapshot.wallet IN (SELECT jsonb_array_elements_text(v_window.wallets))
    AND snapshot.observed_at_ms >= v_window.start_at_ms
    AND snapshot.observed_at_ms < v_window.end_at_ms
    AND snapshot.observed_at_ms <= p_as_of_ms;

  SELECT count(*) FILTER (WHERE status = 'closed' AND closed_at_ms <= p_as_of_ms)::integer,
    count(*) FILTER (WHERE status = 'open' OR closed_at_ms > p_as_of_ms)::integer,
    COALESCE(sum(realized_pnl_usd_micros)
      FILTER (WHERE status = 'closed' AND closed_at_ms <= p_as_of_ms), 0),
    array_agg(realized_pnl_usd_micros * 1000000 / entry_cost_usd_micros
      ORDER BY closed_at_ms, id)
      FILTER (WHERE status = 'closed' AND closed_at_ms <= p_as_of_ms),
    COALESCE(bool_and(
      decision_latency_ms >= 0 AND opened_at_ms >= entry_decision_at_ms
      AND (status = 'open' OR closed_at_ms >= opened_at_ms)
    ), false),
    COALESCE(bool_and(
      entry_cost_usd_micros >= entry_input_usd_micros
      AND entry_network_fee_usd_micros >= 0 AND entry_rent_usd_micros >= 0
      AND (status = 'open' OR closed_at_ms > p_as_of_ms OR exit_network_fee_usd_micros >= 0)
    ), false),
    count(*) FILTER (WHERE entry_migration_status IN ('pre_migration', 'post_migration')
      AND status = 'closed' AND closed_at_ms <= p_as_of_ms)::integer,
    count(*) FILTER (WHERE entry_migration_status = 'not_applicable'
      AND status = 'closed' AND closed_at_ms <= p_as_of_ms)::integer
  INTO v_trade_count, v_open_count, v_strategy_net, v_return_values,
    v_latency_complete, v_costs_complete, v_pump_count, v_established_count
  FROM solana_paper_positions
  WHERE wallet IN (SELECT jsonb_array_elements_text(v_window.wallets))
    AND opened_at_ms >= v_window.start_at_ms
    AND opened_at_ms < v_window.end_at_ms
    AND opened_at_ms <= p_as_of_ms;
  v_lower_95 := deterministic_bootstrap_lower_95(
    v_return_values, v_window.bootstrap_samples, v_window.bootstrap_seed
  );
  SELECT COALESCE(sum(realized_pnl_usd_micros), 0)
  INTO v_net_without_best_three
  FROM (
    SELECT realized_pnl_usd_micros
    FROM solana_paper_positions
    WHERE wallet IN (SELECT jsonb_array_elements_text(v_window.wallets))
      AND status = 'closed'
      AND closed_at_ms <= p_as_of_ms
      AND opened_at_ms >= v_window.start_at_ms
      AND opened_at_ms < v_window.end_at_ms
    ORDER BY realized_pnl_usd_micros DESC, id
    OFFSET 3
  ) remaining;
  WITH outcomes AS (
    SELECT closed_at_ms, id, realized_pnl_usd_micros,
      v_window.maximum_drawdown_bps AS allowed,
      (SELECT initial_capital_usd_micros FROM solana_paper_accounts
       WHERE id = 'solana-wallet-flow-paper')
        + sum(realized_pnl_usd_micros) OVER (ORDER BY closed_at_ms, id) AS equity
    FROM solana_paper_positions
    WHERE status = 'closed'
      AND wallet IN (SELECT jsonb_array_elements_text(v_window.wallets))
      AND opened_at_ms >= v_window.start_at_ms
      AND opened_at_ms < v_window.end_at_ms
      AND closed_at_ms <= p_as_of_ms
  ), peaks AS (
    SELECT *, GREATEST(
      (SELECT initial_capital_usd_micros FROM solana_paper_accounts
       WHERE id = 'solana-wallet-flow-paper'),
      max(equity) OVER (ORDER BY closed_at_ms, id)
    ) AS peak FROM outcomes
  )
  SELECT COALESCE(max(CASE WHEN peak <= 0 THEN 10000
    ELSE LEAST(10000, trunc((peak - equity) * 10000 / peak)::integer) END), 0)
  INTO v_max_drawdown_bps FROM peaks;
  SELECT
    count(*) FILTER (WHERE variant = 'raw_wallet_copy')::integer,
    count(*) FILTER (WHERE variant = 'quant_only')::integer,
    COALESCE(sum(net_pnl_usd_micros) FILTER (WHERE variant = 'raw_wallet_copy'), 0),
    COALESCE(sum(net_pnl_usd_micros) FILTER (WHERE variant = 'quant_only'), 0)
  INTO v_raw_count, v_quant_count, v_raw_net, v_quant_net
  FROM solana_validation_control_trades
  WHERE window_id = v_window.id AND exited_at_ms <= p_as_of_ms;
  SELECT count(*) FILTER (WHERE passed AND evidence_hash IS NOT NULL)::integer
  INTO v_stress_count
  FROM solana_validation_stress_results
  WHERE window_id = v_window.id AND completed_at_ms <= p_as_of_ms;
  SELECT deterministic_bootstrap_lower_95(
    array_agg(realized_pnl_usd_micros * 1000000 / entry_cost_usd_micros
      ORDER BY closed_at_ms, id),
    v_window.bootstrap_samples, v_window.bootstrap_seed
  ) INTO v_pump_lower_95
  FROM solana_paper_positions
  WHERE status = 'closed'
    AND entry_migration_status IN ('pre_migration', 'post_migration')
    AND wallet IN (SELECT jsonb_array_elements_text(v_window.wallets))
    AND opened_at_ms >= v_window.start_at_ms AND opened_at_ms < v_window.end_at_ms
    AND closed_at_ms <= p_as_of_ms;
  SELECT deterministic_bootstrap_lower_95(
    array_agg(realized_pnl_usd_micros * 1000000 / entry_cost_usd_micros
      ORDER BY closed_at_ms, id),
    v_window.bootstrap_samples, v_window.bootstrap_seed
  ) INTO v_established_lower_95
  FROM solana_paper_positions
  WHERE status = 'closed' AND entry_migration_status = 'not_applicable'
    AND wallet IN (SELECT jsonb_array_elements_text(v_window.wallets))
    AND opened_at_ms >= v_window.start_at_ms AND opened_at_ms < v_window.end_at_ms
    AND closed_at_ms <= p_as_of_ms;
  v_controls_complete := v_trade_count > 0
    AND v_raw_count >= v_trade_count AND v_quant_count >= v_trade_count;
  v_cohorts_pass := v_pump_count >= v_window.minimum_cohort_trades
    AND v_established_count >= v_window.minimum_cohort_trades
    AND COALESCE(v_pump_lower_95, 0) > 0
    AND COALESCE(v_established_lower_95, 0) > 0;
  v_passed := v_duration_complete AND v_capture_complete AND v_selection_frozen
    AND v_eligible_enters >= 100 AND v_trade_count >= 100 AND v_open_count = 0
    AND v_latency_complete AND v_costs_complete AND v_lower_95 > 0
    AND v_net_without_best_three > 0
    AND v_max_drawdown_bps <= v_window.maximum_drawdown_bps
    AND v_controls_complete AND v_strategy_net > v_raw_net AND v_strategy_net > v_quant_net
    AND v_cohorts_pass AND v_stress_count = 4;
  RETURN jsonb_build_object(
    'windowId', v_window.id,
    'startAtMs', v_window.start_at_ms::text,
    'endAtMs', v_window.end_at_ms::text,
    'asOfMs', p_as_of_ms::text,
    'passed', v_passed,
    'gates', jsonb_build_object(
      'durationComplete', v_duration_complete,
      'captureComplete', v_capture_complete,
      'selectionFrozen', v_selection_frozen,
      'eligibleEnterCount', v_eligible_enters >= 100,
      'closedTradeCount', v_trade_count >= 100,
      'allPositionsClosed', v_open_count = 0,
      'latencyCoverage', v_latency_complete,
      'costCoverage', v_costs_complete,
      'positiveLower95Bootstrap', v_lower_95 > 0,
      'positiveWithoutBestThree', v_net_without_best_three > 0,
      'drawdownWithinLimit', v_max_drawdown_bps <= v_window.maximum_drawdown_bps,
      'controlCoverage', v_controls_complete,
      'outperformedControls', v_strategy_net > v_raw_net AND v_strategy_net > v_quant_net,
      'cohortsPassSeparately', v_cohorts_pass,
      'stressEvidenceComplete', v_stress_count = 4
    ),
    'counts', jsonb_build_object(
      'eligibleEnters', v_eligible_enters::text,
      'strategyTrades', v_trade_count::text,
      'openPositions', v_open_count::text,
      'pumpLaunchTrades', v_pump_count::text,
      'establishedTokenTrades', v_established_count::text,
      'rawWalletControlTrades', v_raw_count::text,
      'quantOnlyControlTrades', v_quant_count::text,
      'passingStressScenarios', v_stress_count::text
    ),
    'statistics', jsonb_build_object(
      'strategyNetPnlUsdMicros', v_strategy_net::text,
      'lower95BootstrapReturnPpm', v_lower_95::text,
      'netWithoutBestThreeUsdMicros', v_net_without_best_three::text,
      'maximumDrawdownBps', v_max_drawdown_bps::text,
      'maximumAllowedDrawdownBps', v_window.maximum_drawdown_bps::text,
      'rawWalletControlNetPnlUsdMicros', v_raw_net::text,
      'quantOnlyControlNetPnlUsdMicros', v_quant_net::text,
      'pumpLower95ReturnPpm', COALESCE(v_pump_lower_95, 0)::text,
      'establishedLower95ReturnPpm', COALESCE(v_established_lower_95, 0)::text
    ),
    'identity', jsonb_build_object(
      'strategyConfigId', v_window.strategy_config_id,
      'strategyConfigHash', v_window.strategy_config_hash,
      'brokerConfigId', v_window.broker_config_id,
      'brokerConfigHash', v_window.broker_config_hash,
      'trainingCutoffMs', v_window.training_cutoff_ms::text,
      'wallets', v_window.wallets,
      'bootstrapSamples', v_window.bootstrap_samples::text,
      'bootstrapSeed', v_window.bootstrap_seed::text
    )
  );
END;
$$;

CREATE FUNCTION solana_validation_latest_report() RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_window solana_validation_windows%ROWTYPE;
  v_as_of bigint;
BEGIN
  SELECT * INTO v_window FROM solana_validation_windows
  ORDER BY start_at_ms DESC, id DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT GREATEST(
    v_window.start_at_ms,
    COALESCE(max(observed_at_ms), v_window.start_at_ms)
  ) INTO v_as_of FROM normalized_events;
  RETURN solana_validation_report(v_window.id, v_as_of);
END;
$$;

INSERT INTO schema_meta(version) VALUES (46);

COMMIT;
