BEGIN;

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
      'paper_reset'
    )
  );

CREATE FUNCTION apply_paper_reset(
  p_initial_usdc_micros bigint,
  p_initial_collateral_usd_micros bigint,
  p_approval_expires_at_ms bigint,
  p_idempotency_key text,
  p_reason text,
  p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_existing operator_commands%ROWTYPE;
  v_control control_state%ROWTYPE;
  v_now_ms bigint;
  v_reconciliation_result text;
  v_result jsonb;
BEGIN
  IF p_initial_usdc_micros <= 0
     OR p_initial_collateral_usd_micros <= 0
     OR p_approval_expires_at_ms <= 0 THEN
    RAISE EXCEPTION 'paper reset amounts must be positive';
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
    IF v_existing.action <> 'paper_reset'
       OR v_existing.target <> ''
       OR v_existing.reason <> p_reason
       OR v_existing.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'idempotency key reused for a different operator command';
    END IF;
    RETURN v_existing.result || jsonb_build_object('duplicate', true);
  END IF;

  v_now_ms := floor(extract(epoch FROM clock_timestamp()) * 1000);
  IF p_approval_expires_at_ms < v_now_ms
     OR p_approval_expires_at_ms > v_now_ms + 60000 THEN
    RAISE EXCEPTION 'paper reset approval is expired or too far in the future';
  END IF;

  SELECT * INTO v_control
  FROM control_state
  WHERE singleton
  FOR UPDATE;
  IF NOT v_control.pause_all THEN
    RAISE EXCEPTION 'paper reset requires pause-all';
  END IF;
  LOCK TABLE normalized_events, shadow_execution_results
    IN ACCESS EXCLUSIVE MODE;
  IF (
    SELECT count(*)
    FROM portfolio_runs
    WHERE strategy_run_id = 'local-paper-run'
      AND execution_mode = 'paper'
      AND id IN (
        'local-sol-control',
        'local-jitosol-carry',
        'local-sync-sol-control',
        'local-sync-jitosol-carry'
      )
  ) <> 4 THEN
    RAISE EXCEPTION 'paper reset requires the exact four paper portfolios';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM portfolio_runs
    WHERE strategy_run_id = 'local-paper-run'
      AND state <> 'idle'
  ) THEN
    RAISE EXCEPTION 'paper reset requires every portfolio to be idle';
  END IF;

  v_reconciliation_result := (
    record_paper_reconciliation(
      'paper-reset:' || p_idempotency_key || ':reconciliation',
      p_reason
    )->>'result'
  );
  IF v_reconciliation_result <> 'matched' THEN
    RAISE EXCEPTION 'paper reset reconciliation failed: %',
      v_reconciliation_result;
  END IF;

  DELETE FROM shadow_execution_results;
  DELETE FROM direct_unstake_ledger_entries;
  DELETE FROM direct_unstake_events;
  DELETE FROM direct_unstake_counterfactuals;
  DELETE FROM risk_decisions;
  DELETE FROM operator_portfolio_actions;
  DELETE FROM ledger_entries;
  DELETE FROM ledger_batches;
  DELETE FROM fills;
  DELETE FROM orders;
  DELETE FROM outbox_commands;
  DELETE FROM execution_intents;
  DELETE FROM paper_event_applications;
  DELETE FROM position_snapshots;
  DELETE FROM funding_payments;
  DELETE FROM valuation_events;
  DELETE FROM state_transitions;
  DELETE FROM opportunity_decisions;
  DELETE FROM reconciliations;
  DELETE FROM risk_events;
  DELETE FROM normalized_events;

  UPDATE strategy_runs
  SET started_at = now(),
      stopped_at = NULL,
      prng_seed = 42,
      prng_version = 'xorshift64star-v1'
  WHERE id = 'local-paper-run'
    AND execution_mode = 'paper';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'paper strategy run is missing';
  END IF;

  UPDATE portfolio_runs
  SET state = 'idle',
      state_version = 0,
      random_state = 42,
      initial_capital_usd_micros = p_initial_usdc_micros,
      started_at = now(),
      ended_at = NULL
  WHERE strategy_run_id = 'local-paper-run';

  INSERT INTO ledger_batches (
    id, portfolio_run_id, event_type, event_id, batch_hash
  )
  SELECT
    id || ':opening',
    id,
    'opening_capital',
    id || ':opening',
    repeat('0', 64)
  FROM portfolio_runs
  WHERE strategy_run_id = 'local-paper-run';
  INSERT INTO ledger_entries (
    ledger_batch_id, account_debit, account_credit,
    asset, amount_atoms, usd_value_atoms
  )
  SELECT
    id || ':opening',
    'paper_cash',
    'paper_equity',
    'USDC',
    p_initial_usdc_micros::text,
    p_initial_usdc_micros::text
  FROM portfolio_runs
  WHERE strategy_run_id = 'local-paper-run';

  UPDATE control_state
  SET pause_entries = true,
      pause_all = true,
      reason = p_reason,
      version = version + 1,
      updated_at = now()
  WHERE singleton
  RETURNING * INTO v_control;

  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'action', 'paper_reset',
    'status', 'applied',
    'duplicate', false,
    'controlVersion', v_control.version::text,
    'portfolioStateVersion', '0',
    'pauseEntries', v_control.pause_entries,
    'pauseAll', v_control.pause_all,
    'initialUsdcMicros', p_initial_usdc_micros::text,
    'initialCollateralUsdMicros', p_initial_collateral_usd_micros::text,
    'approvalExpiresAtMs', p_approval_expires_at_ms::text
  );

  INSERT INTO operator_commands (
    id, action, target, idempotency_key, reason, request_hash,
    control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key,
    'paper_reset',
    '',
    p_idempotency_key,
    p_reason,
    p_request_hash,
    v_control.version,
    v_result
  );

  RETURN v_result;
END;
$$;

INSERT INTO schema_meta(version) VALUES (30);

COMMIT;
