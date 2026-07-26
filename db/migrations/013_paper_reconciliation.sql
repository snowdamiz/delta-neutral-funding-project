BEGIN;

ALTER TABLE ledger_batches
  ADD CONSTRAINT ledger_batches_hash_canonical CHECK (
    batch_hash ~ '^[0-9a-f]{64}$'
  );
ALTER TABLE ledger_entries
  ADD CONSTRAINT ledger_entries_values_canonical CHECK (
    amount_atoms ~ '^[1-9][0-9]*$'
    AND usd_value_atoms ~ '^(0|[1-9][0-9]*)$'
  );

CREATE FUNCTION record_paper_reconciliation(
  p_id text,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_existing reconciliations%ROWTYPE;
  v_differences jsonb;
  v_recovery_count integer;
  v_result text;
BEGIN
  IF length(p_id) = 0 OR length(p_id) > 300
     OR p_id !~ '^[A-Za-z0-9:_-]+$' THEN
    RAISE EXCEPTION 'invalid reconciliation identity';
  END IF;
  IF length(p_reason) = 0 OR length(p_reason) > 500 THEN
    RAISE EXCEPTION 'invalid reconciliation reason';
  END IF;

  LOCK TABLE reconciliations IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM reconciliations
  WHERE id = p_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'id', v_existing.id,
      'result', v_existing.result,
      'differences', v_existing.differences,
      'duplicate', true
    );
  END IF;

  PERFORM 1
  FROM portfolio_runs
  WHERE strategy_run_id = 'local-paper-run'
  FOR UPDATE;

  WITH balances AS (
    SELECT
      p.id,
      p.state,
      p.state_version,
      COALESCE(sum(CASE
        WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY'
          THEN f.quantity_atoms::numeric
        WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL'
          THEN -f.quantity_atoms::numeric
        ELSE 0
      END), 0) AS spot,
      COALESCE(sum(CASE
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL'
          THEN f.quantity_atoms::numeric
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY'
          THEN -f.quantity_atoms::numeric
        ELSE 0
      END), 0) AS perp
    FROM portfolio_runs p
    LEFT JOIN fills f ON f.portfolio_run_id = p.id
    LEFT JOIN orders o ON o.id = f.order_id
    LEFT JOIN execution_intents ei ON ei.id = o.intent_id
    WHERE p.strategy_run_id = 'local-paper-run'
    GROUP BY p.id, p.state, p.state_version
  ),
  targets AS (
    SELECT
      id,
      state AS from_state,
      state_version,
      CASE
        WHEN state = 'idle' AND (spot <> 0 OR perp <> 0)
          THEN 'emergency_flatten'::portfolio_state
        WHEN state = 'hedged' AND (spot <= 0 OR perp <= 0)
          THEN 'emergency_flatten'::portfolio_state
        WHEN state IN (
          'opening_spot', 'opening_perp', 'rebalancing',
          'exiting_perp', 'exiting_spot'
        ) THEN 'emergency_flatten'::portfolio_state
        WHEN state IN ('bootstrapping', 'candidate', 'reconciling')
          THEN CASE WHEN spot = 0 AND perp = 0
            THEN 'idle'::portfolio_state
            ELSE 'emergency_flatten'::portfolio_state
          END
        ELSE state
      END AS to_state
    FROM balances
  ),
  transitions AS (
    INSERT INTO state_transitions (
      id, portfolio_run_id, from_state, to_state, state_version, reason
    )
    SELECT
      p_id || ':' || id || ':state',
      id,
      from_state,
      to_state,
      state_version + 1,
      'paper_reconciliation:' || p_reason
    FROM targets
    WHERE to_state <> from_state
    RETURNING portfolio_run_id, to_state, state_version
  )
  UPDATE portfolio_runs p
  SET state = t.to_state,
      state_version = t.state_version,
      ended_at = CASE WHEN t.to_state = 'idle' THEN now() ELSE p.ended_at END
  FROM transitions t
  WHERE p.id = t.portfolio_run_id;

  WITH fill_totals AS (
    SELECT order_id, sum(quantity_atoms::numeric) AS quantity
    FROM fills
    GROUP BY order_id
  ),
  balances AS (
    SELECT
      p.id,
      p.state,
      COALESCE(sum(CASE
        WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY'
          THEN f.quantity_atoms::numeric
        WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL'
          THEN -f.quantity_atoms::numeric
        ELSE 0
      END), 0) AS spot,
      COALESCE(sum(CASE
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL'
          THEN f.quantity_atoms::numeric
        WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY'
          THEN -f.quantity_atoms::numeric
        ELSE 0
      END), 0) AS perp
    FROM portfolio_runs p
    LEFT JOIN fills f ON f.portfolio_run_id = p.id
    LEFT JOIN orders o ON o.id = f.order_id
    LEFT JOIN execution_intents ei ON ei.id = o.intent_id
    WHERE p.strategy_run_id = 'local-paper-run'
    GROUP BY p.id, p.state
  ),
  differences AS (
    SELECT jsonb_build_object(
      'type', 'order_fill_quantity',
      'orderId', o.id,
      'recordedAtoms', o.filled_quantity_atoms,
      'derivedAtoms', COALESCE(ft.quantity, 0)::text
    ) AS item
    FROM orders o
    JOIN portfolio_runs p ON p.id = o.portfolio_run_id
    LEFT JOIN fill_totals ft ON ft.order_id = o.id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND o.filled_quantity_atoms::numeric <> COALESCE(ft.quantity, 0)

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'order_status',
      'orderId', o.id,
      'status', o.status,
      'requestedAtoms', o.requested_quantity_atoms,
      'filledAtoms', o.filled_quantity_atoms
    )
    FROM orders o
    JOIN portfolio_runs p ON p.id = o.portfolio_run_id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND NOT (
        (o.status = 'filled'
          AND o.filled_quantity_atoms::numeric = o.requested_quantity_atoms::numeric)
        OR (o.status = 'partial'
          AND o.filled_quantity_atoms::numeric > 0
          AND o.filled_quantity_atoms::numeric < o.requested_quantity_atoms::numeric)
        OR (o.status = 'rejected' AND o.filled_quantity_atoms::numeric = 0)
      )

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'execution_linkage',
      'orderId', o.id
    )
    FROM orders o
    JOIN execution_intents ei ON ei.id = o.intent_id
    JOIN portfolio_runs p ON p.id = o.portfolio_run_id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND (
        o.portfolio_run_id <> ei.portfolio_run_id
        OR o.execution_mode <> ei.execution_mode
        OR o.variant <> ei.variant
        OR o.execution_mode <> p.execution_mode
        OR o.variant <> p.variant
      )

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'fill_linkage',
      'fillId', f.id
    )
    FROM fills f
    JOIN orders o ON o.id = f.order_id
    JOIN portfolio_runs p ON p.id = f.portfolio_run_id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND (
        f.portfolio_run_id <> o.portfolio_run_id
        OR f.execution_mode <> o.execution_mode
        OR f.variant <> o.variant
        OR f.execution_mode <> p.execution_mode
        OR f.variant <> p.variant
      )

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'outbox_unprocessed',
      'commandId', c.id,
      'status', c.status
    )
    FROM outbox_commands c
    JOIN portfolio_runs p ON p.id = c.portfolio_run_id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND (c.status <> 'processed' OR c.processed_at IS NULL)

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'fill_ledger_missing',
      'fillId', f.id
    )
    FROM fills f
    JOIN portfolio_runs p ON p.id = f.portfolio_run_id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND NOT EXISTS (
        SELECT 1
        FROM ledger_batches lb
        JOIN ledger_entries le ON le.ledger_batch_id = lb.id
        WHERE lb.portfolio_run_id = f.portfolio_run_id
          AND lb.event_id = f.id
          AND le.amount_atoms = f.quantity_atoms
          AND le.account_debit <> 'trading_fees'
      )

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'fill_fee_ledger_missing',
      'fillId', f.id
    )
    FROM fills f
    JOIN portfolio_runs p ON p.id = f.portfolio_run_id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND f.fee_atoms::numeric > 0
      AND NOT EXISTS (
        SELECT 1
        FROM ledger_batches lb
        JOIN ledger_entries le ON le.ledger_batch_id = lb.id
        WHERE lb.portfolio_run_id = f.portfolio_run_id
          AND lb.event_id = f.id
          AND le.account_debit = 'trading_fees'
          AND le.usd_value_atoms = f.fee_atoms
      )

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'funding_ledger_missing',
      'fundingPaymentId', fp.id
    )
    FROM funding_payments fp
    JOIN portfolio_runs p ON p.id = fp.portfolio_run_id
    WHERE p.strategy_run_id = 'local-paper-run'
      AND fp.amount_atoms::numeric <> 0
      AND NOT EXISTS (
        SELECT 1
        FROM ledger_batches lb
        JOIN ledger_entries le ON le.ledger_batch_id = lb.id
        WHERE lb.portfolio_run_id = fp.portfolio_run_id
          AND lb.event_id = fp.id
          AND le.usd_value_atoms::numeric = abs(fp.usd_value_atoms::numeric)
      )

    UNION ALL

    SELECT jsonb_build_object(
      'type', 'portfolio_balance_state',
      'portfolioRunId', id,
      'state', state::text,
      'spotAtoms', spot::text,
      'perpAtoms', perp::text
    )
    FROM balances
    WHERE spot < 0
       OR perp < 0
       OR (state = 'idle' AND (spot <> 0 OR perp <> 0))
       OR (state = 'hedged' AND (spot <= 0 OR perp <= 0))
  )
  SELECT COALESCE(jsonb_agg(item ORDER BY item::text), '[]'::jsonb)
  INTO v_differences
  FROM differences;

  SELECT count(*)
  INTO v_recovery_count
  FROM portfolio_runs
  WHERE strategy_run_id = 'local-paper-run'
    AND state = 'emergency_flatten';

  v_result := CASE
    WHEN jsonb_array_length(v_differences) > 0 THEN 'mismatch'
    WHEN v_recovery_count > 0 THEN 'recovery_required'
    ELSE 'matched'
  END;

  INSERT INTO reconciliations (
    id, strategy_run_id, execution_mode, completed_at,
    wallet_snapshot, venue_snapshot, executor_snapshot, database_snapshot,
    differences, result
  ) VALUES (
    p_id,
    'local-paper-run',
    'paper',
    now(),
    jsonb_build_object(
      'derivedFrom', 'persisted_fills',
      'portfolios', COALESCE((
        WITH balances AS (
          SELECT
            p.id,
            p.variant,
            COALESCE(sum(CASE
              WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY'
                THEN f.quantity_atoms::numeric
              WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL'
                THEN -f.quantity_atoms::numeric
              ELSE 0
            END), 0) AS spot
          FROM portfolio_runs p
          LEFT JOIN fills f ON f.portfolio_run_id = p.id
          LEFT JOIN orders o ON o.id = f.order_id
          LEFT JOIN execution_intents ei ON ei.id = o.intent_id
          WHERE p.strategy_run_id = 'local-paper-run'
          GROUP BY p.id, p.variant
        )
        SELECT jsonb_agg(jsonb_build_object(
          'portfolioRunId', id,
          'variant', variant::text,
          'spotQuantityAtoms', spot::text
        ) ORDER BY variant)
        FROM balances
      ), '[]'::jsonb)
    ),
    jsonb_build_object(
      'derivedFrom', 'persisted_fills',
      'portfolios', COALESCE((
        WITH balances AS (
          SELECT
            p.id,
            p.variant,
            COALESCE(sum(CASE
              WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL'
                THEN f.quantity_atoms::numeric
              WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY'
                THEN -f.quantity_atoms::numeric
              ELSE 0
            END), 0) AS perp
          FROM portfolio_runs p
          LEFT JOIN fills f ON f.portfolio_run_id = p.id
          LEFT JOIN orders o ON o.id = f.order_id
          LEFT JOIN execution_intents ei ON ei.id = o.intent_id
          WHERE p.strategy_run_id = 'local-paper-run'
          GROUP BY p.id, p.variant
        )
        SELECT jsonb_agg(jsonb_build_object(
          'portfolioRunId', id,
          'variant', variant::text,
          'perpShortQuantityAtoms', perp::text
        ) ORDER BY variant)
        FROM balances
      ), '[]'::jsonb)
    ),
    jsonb_build_object(
      'broker', 'deterministic_paper_v1',
      'pendingOutboxCommands', (
        SELECT count(*)::text
        FROM outbox_commands c
        JOIN portfolio_runs p ON p.id = c.portfolio_run_id
        WHERE p.strategy_run_id = 'local-paper-run'
          AND (c.status <> 'processed' OR c.processed_at IS NULL)
      ),
      'signerReachable', false
    ),
    jsonb_build_object(
      'reason', p_reason,
      'portfolios', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', id,
          'state', state::text,
          'stateVersion', state_version::text
        ) ORDER BY variant)
        FROM portfolio_runs
        WHERE strategy_run_id = 'local-paper-run'
      ), '[]'::jsonb),
      'orders', (
        SELECT count(*)::text
        FROM orders o
        JOIN portfolio_runs p ON p.id = o.portfolio_run_id
        WHERE p.strategy_run_id = 'local-paper-run'
      ),
      'fills', (
        SELECT count(*)::text
        FROM fills f
        JOIN portfolio_runs p ON p.id = f.portfolio_run_id
        WHERE p.strategy_run_id = 'local-paper-run'
      ),
      'ledgerBatches', (
        SELECT count(*)::text
        FROM ledger_batches lb
        JOIN portfolio_runs p ON p.id = lb.portfolio_run_id
        WHERE p.strategy_run_id = 'local-paper-run'
      )
    ),
    v_differences,
    v_result
  );

  IF v_result = 'mismatch' THEN
    UPDATE control_state
    SET pause_entries = true,
        pause_all = true,
        reason = 'paper_reconciliation_mismatch',
        version = version + 1,
        updated_at = now()
    WHERE singleton
      AND NOT (pause_entries AND pause_all
               AND reason = 'paper_reconciliation_mismatch');

    INSERT INTO risk_events (
      id, strategy_run_id, severity, code, message,
      observed_value, limit_value, action_taken
    ) VALUES (
      p_id || ':risk',
      'local-paper-run',
      'critical',
      'paper_reconciliation_mismatch',
      'persisted paper execution and accounting records do not reconcile',
      v_differences,
      jsonb_build_object('differences', 0),
      'pause_all'
    );
  ELSIF v_result = 'recovery_required' THEN
    UPDATE control_state
    SET pause_entries = true,
        reason = 'paper_recovery_required',
        version = version + 1,
        updated_at = now()
    WHERE singleton
      AND NOT pause_entries;

    INSERT INTO risk_events (
      id, strategy_run_id, severity, code, message,
      observed_value, limit_value, action_taken
    ) VALUES (
      p_id || ':risk',
      'local-paper-run',
      'warning',
      'paper_recovery_required',
      'paper exposure requires bounded compensation after reconciliation',
      jsonb_build_object('portfolios', v_recovery_count::text),
      jsonb_build_object('requiredPortfolios', '0'),
      'pause_entries_and_recover'
    );
  ELSE
    UPDATE risk_events
    SET resolved_at = now()
    WHERE strategy_run_id = 'local-paper-run'
      AND code IN ('paper_recovery_required', 'paper_reconciliation_mismatch')
      AND resolved_at IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', p_id,
    'result', v_result,
    'differences', v_differences,
    'duplicate', false
  );
END;
$$;

CREATE FUNCTION apply_reconciled_operator_command(
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
  v_reconciliation jsonb;
  v_reconciliation_id text;
  v_placeholder_id text;
  v_status text;
  v_result jsonb;
BEGIN
  IF p_action NOT IN ('resume', 'reconcile') THEN
    RETURN apply_operator_command(
      p_action,
      p_target,
      p_idempotency_key,
      p_reason,
      p_request_hash
    );
  END IF;
  IF p_target <> ''
     OR p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR length(p_reason) = 0
     OR length(p_reason) > 500
     OR p_request_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid reconciled operator command';
  END IF;

  LOCK TABLE operator_commands IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM operator_commands
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN apply_operator_command(
      p_action,
      p_target,
      p_idempotency_key,
      p_reason,
      p_request_hash
    );
  END IF;

  v_reconciliation_id :=
    'operator:' || p_idempotency_key || ':verified-reconciliation';
  v_placeholder_id :=
    'operator:' || p_idempotency_key || ':reconciliation';
  v_reconciliation := record_paper_reconciliation(
    v_reconciliation_id,
    'operator_' || p_action
  );
  v_status := v_reconciliation->>'result';

  IF p_action = 'resume' AND v_status <> 'matched' THEN
    SELECT * INTO v_control
    FROM control_state
    WHERE singleton
    FOR UPDATE;

    v_result := jsonb_build_object(
      'commandId', 'operator:' || p_idempotency_key,
      'action', p_action,
      'target', p_target,
      'status', 'blocked',
      'duplicate', false,
      'controlVersion', v_control.version::text,
      'pauseEntries', v_control.pause_entries,
      'pauseAll', v_control.pause_all,
      'reconciliationId', v_reconciliation_id,
      'reconciliationResult', v_status,
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
    RETURN v_result;
  END IF;

  v_result := apply_operator_command(
    p_action,
    p_target,
    p_idempotency_key,
    p_reason,
    p_request_hash
  );
  DELETE FROM reconciliations WHERE id = v_placeholder_id;

  v_result := v_result || jsonb_build_object(
    'status', CASE WHEN p_action = 'reconcile' THEN v_status ELSE 'applied' END,
    'reconciliationId', v_reconciliation_id,
    'reconciliationResult', v_status
  );
  UPDATE operator_commands
  SET result = v_result
  WHERE id = 'operator:' || p_idempotency_key;

  RETURN v_result;
END;
$$;

INSERT INTO schema_meta(version) VALUES (13);

COMMIT;
