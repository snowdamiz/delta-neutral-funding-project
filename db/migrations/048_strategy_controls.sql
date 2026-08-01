BEGIN;

CREATE TABLE strategy_controls (
  strategy_id text PRIMARY KEY CHECK (strategy_id ~ '^[a-z0-9_]{1,64}$'),
  enabled boolean NOT NULL DEFAULT false,
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- The collector disables these again before it starts serving. Keeping the
-- migration compatible with pre-control database contracts lets those tests
-- exercise their strategy directly; runtime safety lives at the app boundary.
INSERT INTO strategy_controls(strategy_id, enabled) VALUES
  ('sol_control', true),
  ('jitosol_carry', true),
  ('cross_asset_funding', true),
  ('negative_funding_reverse', true),
  ('jitosol_nav_discount', true),
  ('cross_venue_funding', true),
  ('hyperliquid_wallet_flow', true),
  ('hyperliquid_wallet_mirror', true),
  ('hyperliquid_wallet_fade', true),
  ('solana_wallet_flow_quant', true);

CREATE FUNCTION strategy_enabled(p_strategy text) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT enabled FROM strategy_controls WHERE strategy_id = p_strategy),
    false
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
      'strategy_stop'
    )
  );

CREATE FUNCTION apply_strategy_control(
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

  UPDATE strategy_controls
  SET enabled = p_enabled,
      version = version + 1,
      updated_at = now()
  WHERE strategy_id = p_strategy
  RETURNING * INTO v_control;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown strategy';
  END IF;

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

-- These functions already share the global entry gate. Patch only their entry
-- predicate, leaving held-position exits and risk management untouched.
-- ponytail: ordered schema-47 source patches avoid duplicating ~2,000 lines;
-- replace them with normal CREATE OR REPLACE bodies if those functions move.
DO $$
DECLARE
  v_definition text;
  v_patched text;
BEGIN
  SELECT pg_get_functiondef(
    'run_cross_asset_paper_scan(text,bigint,bigint,bigint,bigint,bigint,integer)'::regprocedure
  ) INTO v_definition;
  IF regexp_count(v_definition, 'IF NOT v_has_position AND v_candidate_eligible THEN') <> 1 THEN
    RAISE EXCEPTION 'cross-asset entry predicate changed';
  END IF;
  v_patched := replace(
    v_definition,
    'IF NOT v_has_position AND v_candidate_eligible THEN',
    'IF NOT v_has_position AND v_candidate_eligible AND strategy_enabled(''cross_asset_funding'') THEN'
  );
  EXECUTE v_patched;

  SELECT pg_get_functiondef(
    'run_reverse_carry_paper_scan(text,bigint,bigint,bigint,bigint,bigint,bigint,integer,integer,bigint,bigint)'::regprocedure
  ) INTO v_definition;
  IF regexp_count(v_definition, 'IF NOT v_has_position AND v_candidate_eligible THEN') <> 1 THEN
    RAISE EXCEPTION 'reverse-carry entry predicate changed';
  END IF;
  v_patched := replace(
    v_definition,
    'IF NOT v_has_position AND v_candidate_eligible THEN',
    'IF NOT v_has_position AND v_candidate_eligible AND strategy_enabled(''negative_funding_reverse'') THEN'
  );
  EXECUTE v_patched;

  SELECT pg_get_functiondef(
    'run_nav_discount_paper_cycle(text,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,integer)'::regprocedure
  ) INTO v_definition;
  IF regexp_count(v_definition, 'v_eligible :=[[:space:]]+NOT v_entries_paused[[:space:]]+AND v_control_ready') <> 1 THEN
    RAISE EXCEPTION 'NAV-discount entry predicate changed';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    'v_eligible :=[[:space:]]+NOT v_entries_paused[[:space:]]+AND v_control_ready',
    E'v_eligible :=\n      strategy_enabled(''jitosol_nav_discount'')\n      AND NOT v_entries_paused\n      AND v_control_ready'
  );
  EXECUTE v_patched;

  SELECT pg_get_functiondef(
    'run_cross_venue_paper_scan(text,bigint,bigint,bigint,bigint,bigint,integer,bigint,bigint,bigint)'::regprocedure
  ) INTO v_definition;
  IF regexp_count(v_definition, 'v_eligible :=[[:space:]]+NOT v_has_position[[:space:]]+AND \(v_top->>''eligible''\)::boolean') <> 1 THEN
    RAISE EXCEPTION 'cross-venue entry predicate changed';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    'v_eligible :=[[:space:]]+NOT v_has_position[[:space:]]+AND \(v_top->>''eligible''\)::boolean',
    E'v_eligible :=\n      strategy_enabled(''cross_venue_funding'')\n      AND NOT v_has_position\n      AND (v_top->>''eligible'')::boolean'
  );
  EXECUTE v_patched;

  SELECT pg_get_functiondef(
    'process_wallet_paper_fill(text,bigint,bigint)'::regprocedure
  ) INTO v_definition;
  IF regexp_count(v_definition, 'v_eligible :=[[:space:]]+v_gate_eligible[[:space:]]+AND v_depth_qualified') <> 1 THEN
    RAISE EXCEPTION 'wallet entry predicate changed';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    'v_eligible :=[[:space:]]+v_gate_eligible[[:space:]]+AND v_depth_qualified',
    E'v_eligible :=\n          strategy_enabled(v_variant)\n          AND v_gate_eligible\n          AND v_depth_qualified'
  );
  EXECUTE v_patched;

  SELECT pg_get_functiondef(
    'plan_solana_paper_action(text,bigint)'::regprocedure
  ) INTO v_definition;
  IF regexp_count(v_definition, 'ELSIF v_decision.decision = ''REJECT'' THEN') <> 1 THEN
    RAISE EXCEPTION 'Solana entry predicate changed';
  END IF;
  v_patched := replace(
    v_definition,
    'ELSIF v_decision.decision = ''REJECT'' THEN',
    E'ELSIF NOT strategy_enabled(''solana_wallet_flow_quant'') THEN\n      v_action := ''SKIP''; v_status := ''REJECTED''; v_reason := ''STRATEGY_STOPPED'';\n    ELSIF v_decision.decision = ''REJECT'' THEN'
  );
  EXECUTE v_patched;
END;
$$;

INSERT INTO schema_meta(version) VALUES (48);

COMMIT;
