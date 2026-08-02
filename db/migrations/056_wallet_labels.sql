BEGIN;

-- A cohort of base58 keys is unreadable. Every wallet in this strategy came
-- from somewhere — a leaderboard rank, a name, a reason for the operator to
-- trust it — and the console showed none of that, so a candidate could not say
-- whose acquisition triggered it in terms anyone recognises.
--
-- The label travels with the cohort mutation that already exists: same
-- audited, atomic, idempotent replacement, one optional name per wallet.
ALTER TABLE solana_followed_wallets
  ADD COLUMN label text
  CONSTRAINT solana_followed_wallets_label_check
  CHECK (label IS NULL OR (length(label) BETWEEN 1 AND 40 AND label !~ '[\n\r\t]'));

-- Accepts both shapes: a bare address, as every existing caller sends, or an
-- object carrying the name. Mixed arrays are fine — an unnamed wallet is just
-- one whose label is absent.
CREATE OR REPLACE FUNCTION apply_solana_wallet_config(
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
       WHERE jsonb_typeof(value) NOT IN ('string', 'object')
          -- A bare string is the address itself.
          OR (jsonb_typeof(value) = 'string'
              AND value #>> '{}' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$')
          -- An object carries the address and at most a label; nothing else,
          -- so a typo cannot be silently accepted as configuration.
          OR (jsonb_typeof(value) = 'object' AND (
               jsonb_typeof(value -> 'wallet') IS DISTINCT FROM 'string'
               OR value #>> '{wallet}' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
               OR EXISTS (
                 SELECT 1 FROM jsonb_object_keys(value) AS key
                 WHERE key NOT IN ('wallet', 'label')
               )
               OR (value ? 'label' AND (
                    jsonb_typeof(value -> 'label') <> 'string'
                    OR length(value #>> '{label}') NOT BETWEEN 1 AND 40
                    OR value #>> '{label}' ~ '[\n\r\t]'
                  ))
             ))
     )
     OR (
       SELECT count(*) <> count(DISTINCT COALESCE(value #>> '{wallet}', value #>> '{}'))
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
  INSERT INTO solana_followed_wallets(wallet, ordinal, label)
  SELECT
    COALESCE(value #>> '{wallet}', value #>> '{}'),
    ordinality - 1,
    value #>> '{label}'
  FROM jsonb_array_elements(p_wallets)
    WITH ORDINALITY AS submitted(value, ordinality);

  -- An unfollowed wallet keeps no capture state, so following it again
  -- baselines from its next transaction instead of resuming a cursor nobody
  -- is watching — the remedy an operator already reaches for.
  DELETE FROM solana_wallet_cursors
  WHERE wallet NOT IN (SELECT wallet FROM solana_followed_wallets);

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

-- `wallets` stays an array of addresses: the observer validates it as one and
-- must keep working across this change. Labels ride alongside as a lookup.
CREATE OR REPLACE FUNCTION solana_wallet_config() RETURNS jsonb
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
    'labels', COALESCE(
      jsonb_object_agg(wallet.wallet, wallet.label)
        FILTER (WHERE wallet.label IS NOT NULL),
      '{}'::jsonb
    ),
    'maximumWallets', '100',
    'updatedAt', state.updated_at
  )
  FROM solana_wallet_config_state state
  LEFT JOIN solana_followed_wallets wallet ON true
  GROUP BY state.version, state.updated_at;
$$;

INSERT INTO schema_meta(version) VALUES (56);

COMMIT;
