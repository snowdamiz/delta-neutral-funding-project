BEGIN;

CREATE TABLE solana_wallet_config_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO solana_wallet_config_state(singleton) VALUES (true);

CREATE TABLE solana_followed_wallets (
  wallet text PRIMARY KEY CHECK (wallet ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
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
      'wallet_config',
      'solana_wallet_config'
    )
  );

CREATE FUNCTION solana_wallet_config() RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'version', state.version::text,
    'wallets', COALESCE(
      jsonb_agg(wallet.wallet ORDER BY wallet.ordinal)
        FILTER (WHERE wallet.wallet IS NOT NULL),
      '[]'::jsonb
    ),
    'maximumWallets', '100',
    'updatedAt', state.updated_at
  )
  FROM solana_wallet_config_state state
  LEFT JOIN solana_followed_wallets wallet ON true
  GROUP BY state.version, state.updated_at;
$$;

CREATE FUNCTION apply_solana_wallet_config(
  p_idempotency_key text,
  p_reason text,
  p_request_hash text,
  p_wallets jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_existing operator_commands%ROWTYPE;
  v_state solana_wallet_config_state%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR length(p_reason) NOT BETWEEN 1 AND 500
     OR p_request_hash !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_wallets) <> 'array'
     OR jsonb_array_length(p_wallets) > 100
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_wallets) submitted(value)
       WHERE jsonb_typeof(value) <> 'string'
          OR value #>> '{}' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
     )
     OR (
       SELECT count(*) <> count(DISTINCT value #>> '{}')
       FROM jsonb_array_elements(p_wallets) submitted(value)
     ) THEN
    RAISE EXCEPTION 'invalid Solana wallet cohort';
  END IF;

  LOCK TABLE operator_commands, solana_followed_wallets
    IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM operator_commands
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.action <> 'solana_wallet_config'
       OR v_existing.target <> 'solana_followed_wallets'
       OR v_existing.reason <> p_reason
       OR v_existing.request_hash <> p_request_hash
       OR v_existing.result->'wallets' <> p_wallets THEN
      RAISE EXCEPTION 'idempotency key reused for a different operator command';
    END IF;
    RETURN v_existing.result || jsonb_build_object('duplicate', true);
  END IF;

  DELETE FROM solana_followed_wallets;
  INSERT INTO solana_followed_wallets(wallet, ordinal)
  SELECT value, ordinality - 1
  FROM jsonb_array_elements_text(p_wallets)
    WITH ORDINALITY AS submitted(value, ordinality);

  UPDATE solana_wallet_config_state
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
    'solana_wallet_config',
    'solana_followed_wallets',
    p_idempotency_key,
    p_reason,
    p_request_hash,
    (SELECT version FROM control_state WHERE singleton),
    v_result
  );

  RETURN v_result;
END;
$$;

INSERT INTO schema_meta(version) VALUES (47);

COMMIT;
