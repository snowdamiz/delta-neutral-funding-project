BEGIN;

CREATE TABLE wallet_tracking_config_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO wallet_tracking_config_state(singleton) VALUES (true);

CREATE TABLE wallet_tracking_wallets (
  wallet text PRIMARY KEY CHECK (wallet ~ '^0x[0-9a-f]{40}$'),
  ordinal integer NOT NULL UNIQUE CHECK (ordinal >= 0),
  added_at timestamptz NOT NULL DEFAULT now()
);

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
      'wallet_config'
    )
  );

CREATE FUNCTION apply_wallet_tracking_config(
  p_idempotency_key text,
  p_reason text,
  p_request_hash text,
  p_wallets jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_existing operator_commands%ROWTYPE;
  v_state wallet_tracking_config_state%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR length(p_reason) NOT BETWEEN 1 AND 500
     OR p_request_hash !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_wallets) <> 'array'
     OR jsonb_array_length(p_wallets) > 50
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_wallets) submitted(value)
       WHERE jsonb_typeof(value) <> 'string'
          OR value #>> '{}' !~ '^0x[0-9a-f]{40}$'
     )
     OR (
       SELECT count(*) <> count(DISTINCT value #>> '{}')
       FROM jsonb_array_elements(p_wallets) submitted(value)
     ) THEN
    RAISE EXCEPTION 'invalid Hyperliquid wallet cohort';
  END IF;

  LOCK TABLE operator_commands, wallet_tracking_wallets
    IN SHARE ROW EXCLUSIVE MODE;
  SELECT *
  INTO v_existing
  FROM operator_commands
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.action <> 'wallet_config'
       OR v_existing.target <> 'hyperliquid_wallets'
       OR v_existing.reason <> p_reason
       OR v_existing.request_hash <> p_request_hash
       OR v_existing.result->'wallets' <> p_wallets THEN
      RAISE EXCEPTION 'idempotency key reused for a different operator command';
    END IF;
    RETURN v_existing.result || jsonb_build_object('duplicate', true);
  END IF;

  DELETE FROM wallet_tracking_wallets;
  INSERT INTO wallet_tracking_wallets(wallet, ordinal)
  SELECT value, ordinality - 1
  FROM jsonb_array_elements_text(p_wallets)
    WITH ORDINALITY AS submitted(value, ordinality);

  UPDATE wallet_tracking_config_state
  SET version = version + 1,
      updated_at = now()
  WHERE singleton
  RETURNING * INTO v_state;

  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'status', 'applied',
    'duplicate', false,
    'version', v_state.version::text,
    'count', jsonb_array_length(p_wallets)::text,
    'wallets', p_wallets
  );

  INSERT INTO operator_commands (
    id, action, target, idempotency_key, reason, request_hash,
    control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key,
    'wallet_config',
    'hyperliquid_wallets',
    p_idempotency_key,
    p_reason,
    p_request_hash,
    (SELECT version FROM control_state WHERE singleton),
    v_result
  );

  RETURN v_result;
END;
$$;

INSERT INTO schema_meta(version) VALUES (39);

COMMIT;
