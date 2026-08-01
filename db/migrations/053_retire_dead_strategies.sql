BEGIN;

-- Retire the strategies with no path to real money: the Phoenix SOL carry
-- pair (sol_control / jitosol_carry — the venue's terms bar the operator and
-- the trade earned zero across 1,722 recorded decisions), cross-venue funding
-- arbitrage (needs two live perp venues; zero exist for this operator), and
-- the three Hyperliquid wallet-tracking strategies (the venue is closed to
-- the operator, so no mode can ever monetize).
--
-- Historical evidence tables are preserved untouched; this migration removes
-- decision logic, triggers, controls, and registrations only. The Phoenix and
-- JitoSOL captures stay: the cross-asset scanner uses the Phoenix funding row
-- as its SOL venue, and the NAV-discount strategy consumes the JitoSOL
-- snapshot and the direct-unstake counterfactual ledger.

-- 1. The surviving scanners no longer gate synchronized entries on a hedged
-- sol_control benchmark, and the synchronized comparison books end.
DO $$
DECLARE
  v_name text;
  v_definition text;
  v_patched text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'run_cross_asset_paper_scan',
    'run_reverse_carry_paper_scan',
    'run_nav_discount_paper_cycle'
  ] LOOP
    SELECT pg_get_functiondef(oid) INTO v_definition
    FROM pg_proc WHERE proname = v_name;
    IF regexp_count(v_definition, 'AND variant = ''sol_control''') <> 1 THEN
      RAISE EXCEPTION '% benchmark predicate changed', v_name;
    END IF;
    v_patched := replace(
      v_definition,
      E'    SELECT CASE\n'
      || E'      WHEN v_portfolio.mode = ''independent'' THEN true\n'
      || E'      ELSE EXISTS (\n'
      || E'        SELECT 1\n'
      || E'        FROM portfolio_runs\n'
      || E'        WHERE comparison_group_id = v_portfolio.comparison_group_id\n'
      || E'          AND variant = ''sol_control''\n'
      || E'          AND state = ''hedged''\n'
      || E'      )\n'
      || E'    END\n'
      || E'    INTO v_control_ready;',
      'SELECT true INTO v_control_ready;'
    );
    IF v_patched = v_definition THEN
      RAISE EXCEPTION '% benchmark predicate did not match', v_name;
    END IF;
    EXECUTE v_patched;
  END LOOP;
END;
$$;

UPDATE portfolio_runs
SET ended_at = now()
WHERE ended_at IS NULL
  AND (
    variant::text IN (
      'sol_control', 'jitosol_carry', 'cross_venue_funding',
      'hyperliquid_wallet_flow', 'hyperliquid_wallet_mirror',
      'hyperliquid_wallet_fade'
    )
    OR comparison_group_id = 'local-paper-run:synchronized'
  );

-- 2. Cross-venue funding arbitrage and Hyperliquid wallet tracking: triggers
-- first, then every overload of their functions by name so a signature
-- mismatch cannot silently leave logic behind.
DROP TRIGGER IF EXISTS record_cross_venue_funding_ledger ON funding_payments;
DROP TRIGGER IF EXISTS funding_observation_margin_fields ON funding_observations;
DROP TRIGGER IF EXISTS cross_asset_wallet_flow_signal ON cross_asset_paper_decisions;
DROP TRIGGER IF EXISTS reverse_carry_wallet_flow_signal ON reverse_carry_paper_decisions;
DROP TRIGGER IF EXISTS nav_discount_wallet_flow_signal ON nav_discount_paper_decisions;
DROP TRIGGER IF EXISTS cross_venue_wallet_flow_signal ON cross_venue_paper_decisions;
DROP TRIGGER IF EXISTS stop_hyperliquid_strategies_for_empty_cohort
  ON wallet_tracking_config_state;
DROP TRIGGER IF EXISTS paper_valuation_accounting ON valuation_events;

DO $$
DECLARE
  v_signature text;
  v_dropped integer := 0;
BEGIN
  FOR v_signature IN
    SELECT oid::regprocedure::text FROM pg_proc
    WHERE proname IN (
      'record_cross_venue_funding_ledger',
      'funding_observation_margin_fields',
      'run_cross_venue_paper_scan',
      'cross_venue_funding_leaderboard',
      'attach_wallet_flow_signal',
      'process_wallet_paper_fill',
      'record_wallet_observation',
      'wallet_mode_assessment',
      'wallet_consistency_scores',
      'wallet_score_rows',
      'refresh_wallet_flow_signals',
      'apply_wallet_tracking_config',
      'apply_synchronized_paper_entries',
      'apply_synchronized_paper_position_plans',
      'account_paper_valuation',
      'record_shadow_result'
    )
  LOOP
    EXECUTE 'DROP FUNCTION ' || v_signature;
    v_dropped := v_dropped + 1;
  END LOOP;
  IF v_dropped < 16 THEN
    RAISE EXCEPTION 'expected to drop at least 16 retired functions, dropped %',
      v_dropped;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION stop_wallet_strategies_for_empty_cohort() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_TABLE_NAME = 'solana_wallet_config_state'
     AND NOT EXISTS (SELECT 1 FROM solana_followed_wallets) THEN
    UPDATE strategy_controls
    SET enabled = false,
        version = version + 1,
        updated_at = now()
    WHERE strategy_id = 'solana_wallet_flow_quant'
      AND enabled;
  END IF;
  RETURN NEW;
END;
$$;

-- 4. The registry: only surviving strategies keep controls. The wallet
-- strategy precondition function drops its Hyperliquid branch.
DELETE FROM strategy_controls
WHERE strategy_id IN (
  'sol_control', 'jitosol_carry', 'cross_venue_funding',
  'hyperliquid_wallet_flow', 'hyperliquid_wallet_mirror',
  'hyperliquid_wallet_fade'
);

CREATE OR REPLACE FUNCTION apply_strategy_control(
  p_strategy text,
  p_enabled boolean,
  p_idempotency_key text,
  p_reason text,
  p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_action text := CASE WHEN p_enabled THEN 'strategy_start' ELSE 'strategy_stop' END;
  v_existing operator_commands%ROWTYPE;
  v_control strategy_controls%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR length(p_reason) NOT BETWEEN 1 AND 500
     OR p_request_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid strategy control request';
  END IF;

  LOCK TABLE operator_commands, strategy_controls IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM operator_commands
  WHERE idempotency_key = p_idempotency_key;
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
    SELECT 1 FROM strategy_controls WHERE strategy_id = p_strategy
  ) THEN
    RAISE EXCEPTION 'unknown strategy';
  END IF;
  IF p_enabled
     AND p_strategy = 'solana_wallet_flow_quant'
     AND NOT EXISTS (SELECT 1 FROM solana_followed_wallets) THEN
    RAISE EXCEPTION 'strategy requires at least one configured Solana wallet';
  END IF;

  UPDATE strategy_controls
  SET enabled = p_enabled,
      version = version + 1,
      updated_at = now()
  WHERE strategy_id = p_strategy
  RETURNING * INTO v_control;

  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'action', v_action,
    'strategy', p_strategy,
    'status', 'applied',
    'duplicate', false,
    'enabled', v_control.enabled,
    'version', v_control.version::text
  );

  INSERT INTO operator_commands (
    id, action, target, idempotency_key, reason, request_hash,
    control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key,
    v_action,
    p_strategy,
    p_idempotency_key,
    p_reason,
    p_request_hash,
    (SELECT version FROM control_state WHERE singleton),
    v_result
  );
  RETURN v_result;
END;
$$;

INSERT INTO schema_meta(version) VALUES (53);

COMMIT;
