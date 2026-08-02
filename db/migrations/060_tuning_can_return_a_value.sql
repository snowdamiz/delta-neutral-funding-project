BEGIN;

-- A parameter could never be moved back.
--
-- Tuning mints a frozen config and promotes it, and a config's hash is its
-- identity. So restoring a knob to a value it previously held reproduces a
-- configuration that already exists — and inserting it collided on the hash
-- unique constraint, failing with a raw 23505. Every adjustment was therefore
-- one-way: raise a gate to see what it admits and you could not put it back.
--
-- The hash being the identity is the answer, not the obstacle. The same
-- parameters ARE the same configuration, so promote the row that already
-- carries them instead of minting a duplicate. Decisions made under those
-- parameters then all point at one config id, whenever they were made.

CREATE OR REPLACE FUNCTION apply_solana_tuning(
  p_idempotency_key text,
  p_reason text,
  p_request_hash text,
  p_changes jsonb,
  p_now_ms bigint DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_existing operator_commands%ROWTYPE;
  v_now_ms bigint := COALESCE(p_now_ms, (extract(epoch FROM now()) * 1000)::bigint);
  v_change record;
  v_current bigint;
  v_next bigint;
  v_knob solana_tunable_knobs%ROWTYPE;
  v_last_ms bigint;
  v_strategy jsonb;
  v_broker jsonb;
  v_strategy_id text;
  v_broker_id text;
  v_new_strategy_id text;
  v_new_broker_id text;
  v_applied jsonb := '[]'::jsonb;
  v_result jsonb;
BEGIN
  IF p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR length(p_reason) NOT BETWEEN 1 AND 500
     OR p_request_hash !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_changes) <> 'object'
     OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION 'invalid Solana tuning request';
  END IF;

  LOCK TABLE operator_commands, solana_strategy_configs, solana_paper_broker_configs,
             solana_tuning_changes IN SHARE ROW EXCLUSIVE MODE;

  SELECT * INTO v_existing
  FROM operator_commands WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.action <> 'solana_tuning'
       OR v_existing.reason <> p_reason
       OR v_existing.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'idempotency key reused for a different operator command';
    END IF;
    RETURN v_existing.result || jsonb_build_object('duplicate', true);
  END IF;

  -- Live capital is not the place to discover a parameter change. Disarming
  -- is one click and leaves the paper broker running.
  IF EXISTS (
    SELECT 1 FROM strategy_execution_modes
    WHERE strategy_id = 'solana_wallet_flow_quant' AND mode = 'live'
  ) THEN
    RAISE EXCEPTION 'cannot tune while live trading is armed';
  END IF;

  -- A validation window freezes the configuration it is measuring; retuning
  -- mid-window would silently invalidate the result it exists to produce.
  IF EXISTS (
    SELECT 1 FROM solana_validation_windows
    WHERE v_now_ms BETWEEN start_at_ms AND end_at_ms
  ) THEN
    RAISE EXCEPTION 'cannot tune during an open validation window';
  END IF;

  SELECT id, config_json INTO v_strategy_id, v_strategy
  FROM solana_strategy_configs WHERE active;
  SELECT id, config_json INTO v_broker_id, v_broker
  FROM solana_paper_broker_configs WHERE active;
  IF v_strategy_id IS NULL OR v_broker_id IS NULL THEN
    RAISE EXCEPTION 'no active Solana configuration to tune';
  END IF;

  FOR v_change IN SELECT key, value FROM jsonb_each_text(p_changes) LOOP
    SELECT * INTO v_knob FROM solana_tunable_knobs WHERE knob = v_change.key;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'unknown tunable parameter: %', v_change.key;
    END IF;
    IF v_change.value !~ '^(0|[1-9][0-9]{0,18})$' THEN
      RAISE EXCEPTION 'parameter % must be a whole number', v_change.key;
    END IF;
    v_next := v_change.value::bigint;
    v_current := (CASE v_knob.scope
                    WHEN 'strategy' THEN v_strategy ->> v_knob.knob
                    ELSE v_broker ->> v_knob.knob
                  END)::bigint;
    IF v_current IS NULL THEN
      RAISE EXCEPTION 'parameter % is not present in the active configuration', v_change.key;
    END IF;
    IF v_next = v_current THEN
      CONTINUE;
    END IF;
    IF v_next < v_knob.minimum OR v_next > v_knob.maximum THEN
      RAISE EXCEPTION 'parameter % must be between % and %',
        v_change.key, v_knob.minimum, v_knob.maximum;
    END IF;
    -- The over-adjustment guardrail, measured against the value in force so
    -- that repeated moves have to walk rather than leap.
    IF abs(v_next - v_current) * 10000 > v_current * v_knob.max_change_bps THEN
      RAISE EXCEPTION
        'parameter % may move at most % bps away from % in one adjustment',
        v_change.key, v_knob.max_change_bps, v_current;
    END IF;
    SELECT max(changed_at_ms) INTO v_last_ms
    FROM solana_tuning_changes WHERE knob = v_knob.knob;
    IF v_last_ms IS NOT NULL AND v_now_ms - v_last_ms < v_knob.cooldown_ms THEN
      RAISE EXCEPTION 'parameter % was changed % seconds ago and is settling',
        v_change.key, ((v_now_ms - v_last_ms) / 1000);
    END IF;

    IF v_knob.scope = 'strategy' THEN
      v_strategy := jsonb_set(v_strategy, ARRAY[v_knob.knob], to_jsonb(v_next::text));
    ELSE
      v_broker := jsonb_set(v_broker, ARRAY[v_knob.knob], to_jsonb(v_next::text));
    END IF;
    v_applied := v_applied || jsonb_build_object(
      'knob', v_knob.knob, 'scope', v_knob.scope,
      'previous', v_current::text, 'next', v_next::text
    );
  END LOOP;

  IF jsonb_array_length(v_applied) = 0 THEN
    RAISE EXCEPTION 'no parameter changed';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_applied) a
             WHERE a ->> 'scope' = 'strategy') THEN
    -- The hash IS the configuration's identity, so a set of parameters that
    -- has been in force before is not a new config — it is that one again.
    -- Minting a second row for it would collide on the hash, which made
    -- returning any knob to a previous value permanently impossible.
    SELECT id INTO v_new_strategy_id
    FROM solana_strategy_configs WHERE config_hash = solana_config_hash(v_strategy);
    UPDATE solana_strategy_configs SET active = false WHERE active;
    IF v_new_strategy_id IS NULL THEN
      v_new_strategy_id := 'solana-wallet-flow-v'
        || (SELECT count(*) + 1 FROM solana_strategy_configs)::text;
      INSERT INTO solana_strategy_configs (id, config_hash, config_json, frozen, active)
      VALUES (v_new_strategy_id, solana_config_hash(v_strategy), v_strategy, true, true);
    ELSE
      UPDATE solana_strategy_configs SET active = true WHERE id = v_new_strategy_id;
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_applied) a
             WHERE a ->> 'scope' = 'broker') THEN
    SELECT id INTO v_new_broker_id
    FROM solana_paper_broker_configs WHERE config_hash = solana_config_hash(v_broker);
    UPDATE solana_paper_broker_configs SET active = false WHERE active;
    IF v_new_broker_id IS NULL THEN
      v_new_broker_id := 'solana-paper-broker-v'
        || (SELECT count(*) + 1 FROM solana_paper_broker_configs)::text;
      INSERT INTO solana_paper_broker_configs (id, config_hash, config_json, frozen, active)
      VALUES (v_new_broker_id, solana_config_hash(v_broker), v_broker, true, true);
    ELSE
      UPDATE solana_paper_broker_configs SET active = true WHERE id = v_new_broker_id;
    END IF;
  END IF;

  INSERT INTO solana_tuning_changes
    (knob, scope, previous_value, next_value, config_id, reason, idempotency_key, changed_at_ms)
  SELECT
    a ->> 'knob', a ->> 'scope', (a ->> 'previous')::bigint, (a ->> 'next')::bigint,
    CASE a ->> 'scope' WHEN 'strategy' THEN v_new_strategy_id ELSE v_new_broker_id END,
    p_reason, p_idempotency_key, v_now_ms
  FROM jsonb_array_elements(v_applied) a;

  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'status', 'applied',
    'duplicate', false,
    'changes', v_applied,
    'strategyConfigId', COALESCE(v_new_strategy_id, v_strategy_id),
    'brokerConfigId', COALESCE(v_new_broker_id, v_broker_id)
  );
  INSERT INTO operator_commands (
    id, action, target, idempotency_key, reason, request_hash, control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key, 'solana_tuning', 'solana_wallet_flow_quant',
    p_idempotency_key, p_reason, p_request_hash,
    (SELECT version FROM control_state WHERE singleton), v_result
  );
  RETURN v_result;
END;
$function$;

INSERT INTO schema_meta(version) VALUES (60);

COMMIT;
