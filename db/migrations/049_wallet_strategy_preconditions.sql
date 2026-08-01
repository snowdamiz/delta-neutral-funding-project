BEGIN;

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
     AND p_strategy IN (
       'hyperliquid_wallet_flow',
       'hyperliquid_wallet_mirror',
       'hyperliquid_wallet_fade'
     )
     AND NOT EXISTS (SELECT 1 FROM wallet_tracking_wallets) THEN
    RAISE EXCEPTION 'strategy requires at least one configured Hyperliquid wallet';
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

CREATE FUNCTION stop_wallet_strategies_for_empty_cohort() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_TABLE_NAME = 'wallet_tracking_config_state'
     AND NOT EXISTS (SELECT 1 FROM wallet_tracking_wallets) THEN
    UPDATE strategy_controls
    SET enabled = false,
        version = version + 1,
        updated_at = now()
    WHERE strategy_id IN (
      'hyperliquid_wallet_flow',
      'hyperliquid_wallet_mirror',
      'hyperliquid_wallet_fade'
    )
      AND enabled;
  ELSIF TG_TABLE_NAME = 'solana_wallet_config_state'
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

CREATE TRIGGER stop_hyperliquid_strategies_for_empty_cohort
AFTER UPDATE OF version ON wallet_tracking_config_state
FOR EACH ROW EXECUTE FUNCTION stop_wallet_strategies_for_empty_cohort();

CREATE TRIGGER stop_solana_strategy_for_empty_cohort
AFTER UPDATE OF version ON solana_wallet_config_state
FOR EACH ROW EXECUTE FUNCTION stop_wallet_strategies_for_empty_cohort();

INSERT INTO schema_meta(version) VALUES (49);

COMMIT;
