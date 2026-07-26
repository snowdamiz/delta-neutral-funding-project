BEGIN;

CREATE TABLE operator_commands (
  id text PRIMARY KEY,
  action text NOT NULL CHECK (
    action IN ('pause_entries', 'pause_all', 'resume', 'reconcile')
  ),
  idempotency_key text NOT NULL UNIQUE,
  reason text NOT NULL,
  request_hash char(64) NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  control_version bigint NOT NULL CHECK (control_version >= 0),
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION apply_operator_command(
  p_action text,
  p_idempotency_key text,
  p_reason text,
  p_request_hash char(64)
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_existing operator_commands%ROWTYPE;
  v_control control_state%ROWTYPE;
  v_reconciliation_id text := '';
  v_result jsonb;
BEGIN
  IF p_action NOT IN ('pause_entries', 'pause_all', 'resume', 'reconcile') THEN
    RAISE EXCEPTION 'unsupported operator command';
  END IF;
  IF p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$' THEN
    RAISE EXCEPTION 'invalid operator idempotency key';
  END IF;
  IF length(p_reason) = 0 OR length(p_reason) > 500 THEN
    RAISE EXCEPTION 'invalid operator reason';
  END IF;
  IF p_request_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid operator request hash';
  END IF;

  LOCK TABLE operator_commands IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM operator_commands
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.action <> p_action
       OR v_existing.reason <> p_reason
       OR v_existing.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'idempotency key reused for a different operator command';
    END IF;
    RETURN v_existing.result || jsonb_build_object('duplicate', true);
  END IF;

  SELECT * INTO v_control
  FROM control_state
  WHERE singleton
  FOR UPDATE;

  IF p_action IN ('resume', 'reconcile') THEN
    v_reconciliation_id := 'operator:' || p_idempotency_key || ':reconciliation';
    INSERT INTO reconciliations (
      id, execution_mode, completed_at, wallet_snapshot, venue_snapshot,
      executor_snapshot, database_snapshot, differences, result
    ) VALUES (
      v_reconciliation_id,
      'paper',
      now(),
      jsonb_build_object('notApplicable', true, 'reason', 'paper_mode'),
      jsonb_build_object('notApplicable', true, 'reason', 'deterministic_paper_broker'),
      jsonb_build_object('enabled', false, 'signerReachable', false),
      jsonb_build_object(
        'controlVersion', v_control.version::text,
        'portfolios', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', id,
            'state', state::text,
            'stateVersion', state_version::text
          ) ORDER BY variant)
          FROM portfolio_runs
          WHERE strategy_run_id = 'local-paper-run'
        ), '[]'::jsonb)
      ),
      '[]'::jsonb,
      'matched'
    );
  END IF;

  IF p_action = 'pause_entries' THEN
    UPDATE control_state
    SET pause_entries = true,
        reason = p_reason,
        version = version + 1,
        updated_at = now()
    WHERE singleton;
  ELSIF p_action = 'pause_all' THEN
    UPDATE control_state
    SET pause_entries = true,
        pause_all = true,
        reason = p_reason,
        version = version + 1,
        updated_at = now()
    WHERE singleton;
  ELSIF p_action = 'resume' THEN
    UPDATE control_state
    SET pause_entries = false,
        pause_all = false,
        reason = p_reason,
        version = version + 1,
        updated_at = now()
    WHERE singleton;
  END IF;

  SELECT * INTO v_control FROM control_state WHERE singleton;
  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'action', p_action,
    'status', 'applied',
    'duplicate', false,
    'controlVersion', v_control.version::text,
    'pauseEntries', v_control.pause_entries,
    'pauseAll', v_control.pause_all,
    'reconciliationId', v_reconciliation_id
  );

  INSERT INTO operator_commands (
    id, action, idempotency_key, reason, request_hash, control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key,
    p_action,
    p_idempotency_key,
    p_reason,
    p_request_hash,
    v_control.version,
    v_result
  );

  RETURN v_result;
END;
$$;

INSERT INTO schema_meta(version) VALUES (7);

COMMIT;
