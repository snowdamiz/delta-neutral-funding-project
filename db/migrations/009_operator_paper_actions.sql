BEGIN;

ALTER TABLE operator_commands
  DROP CONSTRAINT operator_commands_action_check,
  ADD COLUMN target text NOT NULL DEFAULT '',
  ADD CONSTRAINT operator_commands_action_check CHECK (
    action IN (
      'pause_entries',
      'pause_all',
      'resume',
      'reconcile',
      'exit_position',
      'emergency_flatten',
      'alerts_test'
    )
  );

CREATE TABLE operator_portfolio_actions (
  command_id text NOT NULL REFERENCES operator_commands(id),
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  action text NOT NULL CHECK (action IN ('exit_position', 'emergency_flatten')),
  reason text NOT NULL,
  status text NOT NULL CHECK (status IN ('pending', 'applied', 'failed', 'superseded')),
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  PRIMARY KEY (command_id, portfolio_run_id)
);
CREATE UNIQUE INDEX operator_portfolio_actions_one_pending
  ON operator_portfolio_actions(portfolio_run_id)
  WHERE status = 'pending';

CREATE FUNCTION complete_operator_portfolio_action() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.state = 'hedged' AND NEW.state <> 'hedged' THEN
    UPDATE operator_portfolio_actions
    SET status = CASE WHEN NEW.state = 'idle' THEN 'applied' ELSE 'failed' END,
        completed_at = now()
    WHERE portfolio_run_id = NEW.id
      AND status = 'pending';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER portfolio_operator_action_completion
AFTER UPDATE OF state ON portfolio_runs
FOR EACH ROW
EXECUTE FUNCTION complete_operator_portfolio_action();

DROP FUNCTION apply_operator_command(text, text, text, character);

CREATE FUNCTION apply_operator_command(
  p_action text,
  p_target text,
  p_idempotency_key text,
  p_reason text,
  p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_existing operator_commands%ROWTYPE;
  v_control control_state%ROWTYPE;
  v_reconciliation_id text := '';
  v_requested integer := 0;
  v_status text := 'applied';
  v_result jsonb;
BEGIN
  IF p_action NOT IN (
    'pause_entries',
    'pause_all',
    'resume',
    'reconcile',
    'exit_position',
    'emergency_flatten',
    'alerts_test'
  ) THEN
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
  IF p_action = 'exit_position'
     AND p_target NOT IN ('local-sol-control', 'local-jitosol-carry') THEN
    RAISE EXCEPTION 'invalid paper portfolio target';
  END IF;
  IF p_action = 'emergency_flatten' AND p_target <> '*' THEN
    RAISE EXCEPTION 'emergency flatten target must be all portfolios';
  END IF;
  IF p_action NOT IN ('exit_position', 'emergency_flatten') AND p_target <> '' THEN
    RAISE EXCEPTION 'operator command does not accept a target';
  END IF;

  LOCK TABLE operator_commands IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM operator_commands
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.action <> p_action
       OR v_existing.target <> p_target
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
  ELSIF p_action = 'emergency_flatten' THEN
    UPDATE control_state
    SET pause_entries = true,
        pause_all = true,
        reason = p_reason,
        version = version + 1,
        updated_at = now()
    WHERE singleton;
  END IF;

  SELECT * INTO v_control FROM control_state WHERE singleton;
  IF p_action IN ('exit_position', 'emergency_flatten') THEN
    v_status := 'accepted';
  END IF;
  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'action', p_action,
    'target', p_target,
    'status', v_status,
    'duplicate', false,
    'controlVersion', v_control.version::text,
    'pauseEntries', v_control.pause_entries,
    'pauseAll', v_control.pause_all,
    'reconciliationId', v_reconciliation_id,
    'requestedActions', 0
  );

  INSERT INTO operator_commands (
    id, action, target, idempotency_key, reason, request_hash,
    control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key,
    p_action,
    p_target,
    p_idempotency_key,
    p_reason,
    p_request_hash,
    v_control.version,
    v_result
  );

  IF p_action = 'emergency_flatten' THEN
    UPDATE operator_portfolio_actions
    SET status = 'superseded',
        completed_at = now()
    WHERE status = 'pending';
  END IF;

  IF p_action = 'exit_position' THEN
    INSERT INTO operator_portfolio_actions (
      command_id, portfolio_run_id, action, reason, status
    )
    SELECT
      'operator:' || p_idempotency_key,
      id,
      p_action,
      p_reason,
      'pending'
    FROM portfolio_runs
    WHERE id = p_target
      AND state = 'hedged';
    GET DIAGNOSTICS v_requested = ROW_COUNT;
  ELSIF p_action = 'emergency_flatten' THEN
    INSERT INTO operator_portfolio_actions (
      command_id, portfolio_run_id, action, reason, status
    )
    SELECT
      'operator:' || p_idempotency_key,
      id,
      p_action,
      p_reason,
      'pending'
    FROM portfolio_runs
    WHERE strategy_run_id = 'local-paper-run'
      AND state = 'hedged';
    GET DIAGNOSTICS v_requested = ROW_COUNT;

    INSERT INTO risk_events (
      id, strategy_run_id, severity, code, message,
      observed_value, limit_value, action_taken
    ) VALUES (
      'operator:' || p_idempotency_key || ':risk',
      'local-paper-run',
      'critical',
      'operator_emergency_flatten',
      p_reason,
      jsonb_build_object('requestedPortfolios', v_requested::text),
      jsonb_build_object('target', 'all'),
      'pause_all_and_flatten'
    );
  ELSIF p_action = 'alerts_test' THEN
    INSERT INTO risk_events (
      id, strategy_run_id, severity, code, message,
      observed_value, limit_value, action_taken, resolved_at
    ) VALUES (
      'operator:' || p_idempotency_key || ':risk',
      'local-paper-run',
      'info',
      'operator_alert_test',
      p_reason,
      jsonb_build_object('test', true),
      jsonb_build_object('expected', 'operator_visible'),
      'test_alert_emitted',
      now()
    );
  END IF;

  IF p_action IN ('exit_position', 'emergency_flatten') AND v_requested = 0 THEN
    v_status := 'no_position';
  END IF;
  v_result := v_result || jsonb_build_object(
    'status', v_status,
    'requestedActions', v_requested
  );
  UPDATE operator_commands
  SET result = v_result
  WHERE id = 'operator:' || p_idempotency_key;

  RETURN v_result;
END;
$$;

INSERT INTO schema_meta(version) VALUES (9);

COMMIT;
