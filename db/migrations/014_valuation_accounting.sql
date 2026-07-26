BEGIN;

ALTER TABLE valuation_events
  ADD CONSTRAINT valuation_events_source_unique
    UNIQUE (portfolio_run_id, source_event_id),
  ADD CONSTRAINT valuation_events_values_canonical CHECK (
    quantity_atoms ~ '^(0|[1-9][0-9]*)$'
    AND protocol_nav_rate_atoms ~ '^[1-9][0-9]*$'
    AND market_sell_rate_atoms ~ '^[1-9][0-9]*$'
    AND reward_accrual_sol_atoms ~ '^(0|-?[1-9][0-9]*)$'
    AND basis_change_sol_atoms ~ '^(0|-?[1-9][0-9]*)$'
    AND reward_accrual_usd_atoms ~ '^(0|-?[1-9][0-9]*)$'
    AND basis_change_usd_atoms ~ '^(0|-?[1-9][0-9]*)$'
    AND (
      reward_accrual_usd_atoms::numeric = 0
      OR sign(reward_accrual_usd_atoms::numeric)
         = sign(reward_accrual_sol_atoms::numeric)
    )
    AND (
      basis_change_usd_atoms::numeric = 0
      OR sign(basis_change_usd_atoms::numeric)
         = sign(basis_change_sol_atoms::numeric)
    )
  );

CREATE FUNCTION account_paper_valuation() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_strategy_run_id text;
  v_variant strategy_variant;
  v_batch_hash char(64);
BEGIN
  SELECT p.strategy_run_id, p.variant, ne.raw_payload_hash
  INTO v_strategy_run_id, v_variant, v_batch_hash
  FROM portfolio_runs p
  JOIN normalized_events ne ON ne.id = NEW.source_event_id
  WHERE p.id = NEW.portfolio_run_id;

  IF v_variant <> 'jitosol_carry'
     AND (
       NEW.reward_accrual_sol_atoms::numeric <> 0
       OR NEW.basis_change_sol_atoms::numeric <> 0
       OR NEW.reward_accrual_usd_atoms::numeric <> 0
       OR NEW.basis_change_usd_atoms::numeric <> 0
     ) THEN
    RAISE EXCEPTION 'SOL control valuation cannot contain JitoSOL attribution';
  END IF;

  IF NEW.reward_accrual_sol_atoms::numeric <> 0
     OR NEW.basis_change_sol_atoms::numeric <> 0 THEN
    INSERT INTO ledger_batches (
      id, portfolio_run_id, event_type, event_id, batch_hash
    ) VALUES (
      NEW.id || ':ledger',
      NEW.portfolio_run_id,
      'valuation',
      NEW.id,
      v_batch_hash
    );

    INSERT INTO ledger_entries (
      ledger_batch_id, account_debit, account_credit, asset,
      amount_atoms, usd_value_atoms, price_reference_id
    )
    SELECT
      NEW.id || ':ledger',
      CASE WHEN NEW.reward_accrual_sol_atoms::numeric > 0
        THEN 'jitosol_protocol_value' ELSE 'jitosol_protocol_anomaly' END,
      CASE WHEN NEW.reward_accrual_sol_atoms::numeric > 0
        THEN 'jitosol_reward_income' ELSE 'jitosol_protocol_value' END,
      'SOL',
      abs(NEW.reward_accrual_sol_atoms::numeric)::text,
      abs(NEW.reward_accrual_usd_atoms::numeric)::text,
      NEW.source_event_id
    WHERE NEW.reward_accrual_sol_atoms::numeric <> 0
    UNION ALL
    SELECT
      NEW.id || ':ledger',
      CASE WHEN NEW.basis_change_sol_atoms::numeric > 0
        THEN 'jitosol_market_value' ELSE 'jitosol_basis_pnl' END,
      CASE WHEN NEW.basis_change_sol_atoms::numeric > 0
        THEN 'jitosol_basis_pnl' ELSE 'jitosol_market_value' END,
      'SOL',
      abs(NEW.basis_change_sol_atoms::numeric)::text,
      abs(NEW.basis_change_usd_atoms::numeric)::text,
      NEW.source_event_id
    WHERE NEW.basis_change_sol_atoms::numeric <> 0;
  END IF;

  IF NEW.reward_accrual_sol_atoms::numeric < 0 THEN
    UPDATE control_state
    SET pause_entries = true,
        reason = 'jitosol_nav_decrease',
        version = version + 1,
        updated_at = now()
    WHERE singleton
      AND NOT pause_entries;

    INSERT INTO risk_events (
      id, strategy_run_id, portfolio_run_id, severity, code, message,
      observed_value, limit_value, action_taken
    ) VALUES (
      NEW.id || ':risk',
      v_strategy_run_id,
      NEW.portfolio_run_id,
      'critical',
      'jitosol_nav_decrease',
      'observed JitoSOL protocol NAV attribution decreased',
      jsonb_build_object(
        'rewardAccrualSolAtoms', NEW.reward_accrual_sol_atoms,
        'rewardAccrualUsdMicros', NEW.reward_accrual_usd_atoms,
        'protocolNavRateAtoms', NEW.protocol_nav_rate_atoms
      ),
      jsonb_build_object('minimumRewardAccrualSolAtoms', '0'),
      'pause_entries_and_exit_review'
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER paper_valuation_accounting
AFTER INSERT ON valuation_events
FOR EACH ROW
EXECUTE FUNCTION account_paper_valuation();

INSERT INTO ledger_batches (
  id, portfolio_run_id, event_type, event_id, batch_hash
)
SELECT
  v.id || ':ledger',
  v.portfolio_run_id,
  'valuation',
  v.id,
  ne.raw_payload_hash
FROM valuation_events v
JOIN normalized_events ne ON ne.id = v.source_event_id
JOIN portfolio_runs p ON p.id = v.portfolio_run_id
WHERE p.variant = 'jitosol_carry'
  AND (
    v.reward_accrual_sol_atoms::numeric <> 0
    OR v.basis_change_sol_atoms::numeric <> 0
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO ledger_entries (
  ledger_batch_id, account_debit, account_credit, asset,
  amount_atoms, usd_value_atoms, price_reference_id
)
SELECT
  v.id || ':ledger',
  CASE WHEN v.reward_accrual_sol_atoms::numeric > 0
    THEN 'jitosol_protocol_value' ELSE 'jitosol_protocol_anomaly' END,
  CASE WHEN v.reward_accrual_sol_atoms::numeric > 0
    THEN 'jitosol_reward_income' ELSE 'jitosol_protocol_value' END,
  'SOL',
  abs(v.reward_accrual_sol_atoms::numeric)::text,
  abs(v.reward_accrual_usd_atoms::numeric)::text,
  v.source_event_id
FROM valuation_events v
JOIN portfolio_runs p ON p.id = v.portfolio_run_id
WHERE p.variant = 'jitosol_carry'
  AND v.reward_accrual_sol_atoms::numeric <> 0
  AND NOT EXISTS (
    SELECT 1
    FROM ledger_entries le
    WHERE le.ledger_batch_id = v.id || ':ledger'
      AND le.account_debit IN (
        'jitosol_protocol_value', 'jitosol_protocol_anomaly'
      )
  )
UNION ALL
SELECT
  v.id || ':ledger',
  CASE WHEN v.basis_change_sol_atoms::numeric > 0
    THEN 'jitosol_market_value' ELSE 'jitosol_basis_pnl' END,
  CASE WHEN v.basis_change_sol_atoms::numeric > 0
    THEN 'jitosol_basis_pnl' ELSE 'jitosol_market_value' END,
  'SOL',
  abs(v.basis_change_sol_atoms::numeric)::text,
  abs(v.basis_change_usd_atoms::numeric)::text,
  v.source_event_id
FROM valuation_events v
JOIN portfolio_runs p ON p.id = v.portfolio_run_id
WHERE p.variant = 'jitosol_carry'
  AND v.basis_change_sol_atoms::numeric <> 0
  AND NOT EXISTS (
    SELECT 1
    FROM ledger_entries le
    WHERE le.ledger_batch_id = v.id || ':ledger'
      AND (
        le.account_debit IN ('jitosol_market_value', 'jitosol_basis_pnl')
        OR le.account_credit IN ('jitosol_market_value', 'jitosol_basis_pnl')
      )
  );

INSERT INTO risk_events (
  id, strategy_run_id, portfolio_run_id, severity, code, message,
  observed_value, limit_value, action_taken
)
SELECT
  v.id || ':risk',
  p.strategy_run_id,
  v.portfolio_run_id,
  'critical',
  'jitosol_nav_decrease',
  'observed JitoSOL protocol NAV attribution decreased',
  jsonb_build_object(
    'rewardAccrualSolAtoms', v.reward_accrual_sol_atoms,
    'rewardAccrualUsdMicros', v.reward_accrual_usd_atoms,
    'protocolNavRateAtoms', v.protocol_nav_rate_atoms
  ),
  jsonb_build_object('minimumRewardAccrualSolAtoms', '0'),
  'pause_entries_and_exit_review'
FROM valuation_events v
JOIN portfolio_runs p ON p.id = v.portfolio_run_id
WHERE v.reward_accrual_sol_atoms::numeric < 0
  AND p.variant = 'jitosol_carry'
ON CONFLICT (id) DO NOTHING;

INSERT INTO risk_events (
  id, strategy_run_id, portfolio_run_id, severity, code, message,
  observed_value, limit_value, action_taken, resolved_at
)
SELECT
  v.id || ':risk',
  p.strategy_run_id,
  v.portfolio_run_id,
  'critical',
  'sol_control_attribution_contamination',
  'historical SOL-control valuation contains JitoSOL attribution',
  jsonb_build_object(
    'rewardAccrualSolAtoms', v.reward_accrual_sol_atoms,
    'basisChangeSolAtoms', v.basis_change_sol_atoms,
    'rewardAccrualUsdMicros', v.reward_accrual_usd_atoms,
    'basisChangeUsdMicros', v.basis_change_usd_atoms
  ),
  jsonb_build_object(
    'rewardAccrualSolAtoms', '0',
    'basisChangeSolAtoms', '0'
  ),
  'excluded_from_pnl_and_loader_fixed',
  now()
FROM valuation_events v
JOIN portfolio_runs p ON p.id = v.portfolio_run_id
WHERE p.variant = 'sol_control'
  AND (
    v.reward_accrual_sol_atoms::numeric <> 0
    OR v.basis_change_sol_atoms::numeric <> 0
    OR v.reward_accrual_usd_atoms::numeric <> 0
    OR v.basis_change_usd_atoms::numeric <> 0
  )
ON CONFLICT (id) DO NOTHING;

UPDATE control_state
SET pause_entries = true,
    reason = 'jitosol_nav_decrease',
    version = version + 1,
    updated_at = now()
WHERE singleton
  AND NOT pause_entries
  AND EXISTS (
    SELECT 1
    FROM valuation_events v
    JOIN portfolio_runs p ON p.id = v.portfolio_run_id
    WHERE p.variant = 'jitosol_carry'
      AND v.reward_accrual_sol_atoms::numeric < 0
  );

INSERT INTO schema_meta(version) VALUES (14);

COMMIT;
