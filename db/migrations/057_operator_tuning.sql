BEGIN;

-- Tuning the strategy without unfreezing it.
--
-- Every candidate decision names the config it was scored under, and a
-- validation window pins both config hashes, so a config can never be edited
-- in place — the trigger enforces that and should keep enforcing it. An
-- operator adjustment therefore mints a NEW frozen config and promotes it:
-- the old rows stay exactly as they were, and every past decision keeps
-- pointing at the parameters that actually produced it.
--
-- What makes this safe to expose is the guardrail catalogue below. A knob is
-- tunable only if it appears there, only inside its stated bounds, only by a
-- bounded step per adjustment, and only after its cooldown has elapsed. The
-- limits live in the database rather than the console because the console is
-- not the only thing that can call this.

-- Tuning is an audited operator command like every other one.
ALTER TABLE operator_commands DROP CONSTRAINT operator_commands_action_check;
ALTER TABLE operator_commands ADD CONSTRAINT operator_commands_action_check
  CHECK (action = ANY (ARRAY[
    'pause_entries', 'pause_all', 'resume', 'reconcile', 'exit_position',
    'emergency_flatten', 'alerts_test', 'paper_reset', 'wallet_config',
    'solana_wallet_config', 'strategy_start', 'strategy_stop',
    'strategy_arm_live', 'strategy_disarm_live', 'solana_tuning'
  ]));

CREATE TABLE solana_tunable_knobs (
  knob text PRIMARY KEY CHECK (knob ~ '^[a-zA-Z][a-zA-Z0-9]{0,60}$'),
  scope text NOT NULL CHECK (scope IN ('strategy', 'broker')),
  label text NOT NULL,
  -- What moving it does, in the operator's terms, and which way is riskier.
  helper text NOT NULL,
  unit text NOT NULL CHECK (unit IN ('usdMicros', 'bps', 'count', 'ms', 'multiple')),
  minimum bigint NOT NULL,
  maximum bigint NOT NULL CHECK (maximum > minimum),
  -- The guardrail against over-adjustment: the largest single move, relative
  -- to the value in force, in basis points. 5000 = "at most half again".
  max_change_bps integer NOT NULL CHECK (max_change_bps BETWEEN 100 AND 10000),
  cooldown_ms bigint NOT NULL CHECK (cooldown_ms >= 0),
  -- Higher is looser: raising it admits more candidates or more risk. Drives
  -- the console's warning, and nothing else.
  raising_loosens boolean NOT NULL,
  ordinal integer NOT NULL UNIQUE
);

INSERT INTO solana_tunable_knobs
  (knob, scope, label, helper, unit, minimum, maximum, max_change_bps, cooldown_ms, raising_loosens, ordinal)
VALUES
  ('positionUsdMicros', 'strategy', 'Position size',
   'What one entry commits. Larger positions move the price more on the way in and out, so raising this also raises measured entry impact and needs deeper exit liquidity.',
   'usdMicros', 25000000, 500000000, 5000, 900000, true, 1),
  ('maxEntryImpactBps', 'strategy', 'Maximum entry impact',
   'How far the quoted buy may move the price before a candidate is refused. This is the cost of getting in, paid on every entry. Raising it admits thinner markets.',
   'bps', 50, 600, 5000, 900000, true, 2),
  ('maxRoundTripLossBps', 'strategy', 'Maximum round-trip loss',
   'What buying and immediately selling is allowed to cost. It is the floor under every trade: the position must gain more than this before it is worth anything.',
   'bps', 200, 1500, 5000, 900000, true, 3),
  ('minimumExitDepthMultiple', 'strategy', 'Minimum exit depth',
   'How many times the position size must be exitable within the impact bound. This is what stops the strategy becoming exit liquidity, so lowering it is the riskiest move here.',
   'multiple', 3, 20, 5000, 900000, false, 4),
  ('minimumOrganicBuyerCount', 'strategy', 'Minimum organic buyers',
   'How many unlinked buyers must already be in the mint. Evidence the move is not the creator and their cluster trading with themselves.',
   'count', 3, 50, 5000, 900000, false, 5),
  ('maxTopTenHolderConcentrationBps', 'strategy', 'Maximum top-10 concentration',
   'How much of supply the ten largest holders may control. High concentration means a handful of wallets can end the move in one transaction.',
   'bps', 1500, 7000, 3000, 900000, true, 6),
  ('maxOpenPositions', 'broker', 'Concurrent positions',
   'How many entries may be open at once. Total capital at risk is this times the position size.',
   'count', 1, 10, 5000, 900000, true, 7),
  ('takeProfitMultipleBps', 'broker', 'Recoup multiple',
   'The multiple at which the ladder sells enough to recover the entry cost. Lower recoups sooner and rides less; higher risks giving back the move before anything is banked.',
   'bps', 12000, 50000, 5000, 900000, true, 8),
  ('trailingStopBps', 'broker', 'Trailing stop',
   'How far below the high-water mark the remainder is allowed to fall. Tighter exits sooner and cuts runners short; wider gives back more of the peak.',
   'bps', 1000, 6000, 5000, 900000, true, 9),
  ('stopLossBps', 'broker', 'Stop loss',
   'How far a position may fall from entry before it is closed. This is the worst case on any single trade.',
   'bps', 2000, 8000, 5000, 900000, true, 10);

-- Every adjustment, with what it moved from and to. Also the cooldown clock.
CREATE TABLE solana_tuning_changes (
  id bigserial PRIMARY KEY,
  knob text NOT NULL REFERENCES solana_tunable_knobs(knob),
  scope text NOT NULL,
  previous_value bigint NOT NULL,
  next_value bigint NOT NULL CHECK (next_value <> previous_value),
  config_id text NOT NULL,
  reason text NOT NULL,
  idempotency_key text NOT NULL,
  changed_at_ms bigint NOT NULL
);
CREATE INDEX solana_tuning_changes_knob ON solana_tuning_changes(knob, changed_at_ms DESC);

-- The one canonicalisation, shared by the migrations that author configs by
-- hand and by the tuning path that mints them at runtime: compact, keys in
-- byte order, values as authored. Verified to reproduce every config hash
-- already in this database.
CREATE FUNCTION solana_config_hash(p_config jsonb) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(sha256((
    '{' || string_agg('"' || key || '":' || to_json(value)::text, ','
                       ORDER BY key COLLATE "C") || '}'
  )::bytea), 'hex')
  FROM jsonb_each_text(p_config);
$$;

CREATE FUNCTION apply_solana_tuning(
  p_idempotency_key text,
  p_reason text,
  p_request_hash text,
  p_changes jsonb,
  p_now_ms bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
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
    v_new_strategy_id := 'solana-wallet-flow-v'
      || (SELECT count(*) + 1 FROM solana_strategy_configs)::text;
    UPDATE solana_strategy_configs SET active = false WHERE active;
    INSERT INTO solana_strategy_configs (id, config_hash, config_json, frozen, active)
    VALUES (v_new_strategy_id, solana_config_hash(v_strategy), v_strategy, true, true);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_applied) a
             WHERE a ->> 'scope' = 'broker') THEN
    v_new_broker_id := 'solana-paper-broker-v'
      || (SELECT count(*) + 1 FROM solana_paper_broker_configs)::text;
    UPDATE solana_paper_broker_configs SET active = false WHERE active;
    INSERT INTO solana_paper_broker_configs (id, config_hash, config_json, frozen, active)
    VALUES (v_new_broker_id, solana_config_hash(v_broker), v_broker, true, true);
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
$$;

-- What the console needs to render a knob: where it stands, how far it may
-- move right now, and when it may move again.
CREATE FUNCTION solana_tuning_read_model(p_now_ms bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH now_ms AS (
    SELECT COALESCE(p_now_ms, (extract(epoch FROM now()) * 1000)::bigint) AS value
  ), active AS (
    SELECT
      (SELECT config_json FROM solana_strategy_configs WHERE active) AS strategy,
      (SELECT config_json FROM solana_paper_broker_configs WHERE active) AS broker
  ), current AS (
    SELECT
      k.*,
      (CASE k.scope
         WHEN 'strategy' THEN a.strategy ->> k.knob
         ELSE a.broker ->> k.knob
       END)::bigint AS value,
      (SELECT max(changed_at_ms) FROM solana_tuning_changes c WHERE c.knob = k.knob) AS last_ms
    FROM solana_tunable_knobs k CROSS JOIN active a
  )
  SELECT jsonb_build_object(
    'knobs', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'knob', knob,
        'scope', scope,
        'label', label,
        'helper', helper,
        'unit', unit,
        'value', value::text,
        'minimum', minimum::text,
        'maximum', maximum::text,
        'maxChangeBps', max_change_bps,
        'raisingLoosens', raising_loosens,
        -- The window this knob may move within on THIS adjustment, already
        -- clamped to its absolute bounds: the console renders it directly
        -- rather than re-deriving the rule.
        'allowedMinimum', greatest(
          minimum, value - (value * max_change_bps) / 10000)::text,
        'allowedMaximum', least(
          maximum, value + (value * max_change_bps) / 10000)::text,
        'readyInMs', greatest(0, COALESCE(
          cooldown_ms - ((SELECT value FROM now_ms) - last_ms), 0))::text
      ) ORDER BY ordinal)
      FROM current), '[]'::jsonb),
    'history', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'knob', knob, 'previous', previous_value::text, 'next', next_value::text,
        'configId', config_id, 'reason', reason, 'changedAtMs', changed_at_ms::text
      ) ORDER BY changed_at_ms DESC, id DESC)
      FROM (SELECT * FROM solana_tuning_changes ORDER BY changed_at_ms DESC, id DESC LIMIT 20) recent
    ), '[]'::jsonb),
    'lockedReason', CASE
      WHEN EXISTS (SELECT 1 FROM strategy_execution_modes
                   WHERE strategy_id = 'solana_wallet_flow_quant' AND mode = 'live')
        THEN 'live trading is armed'
      WHEN EXISTS (SELECT 1 FROM solana_validation_windows
                   WHERE (SELECT value FROM now_ms) BETWEEN start_at_ms AND end_at_ms)
        THEN 'a validation window is open'
      ELSE NULL
    END
  );
$$;

INSERT INTO schema_meta(version) VALUES (57);

COMMIT;
