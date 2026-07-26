\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'valuation-build', 'test', 'test', 14, repeat('0', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'valuation-run', 'paper', repeat('0', 64),
  'valuation-build', 42, 'xorshift64star-v1'
);
INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, state, state_version,
  initial_capital_usd_micros
) VALUES
  ('valuation-jito', 'valuation-run', 'jitosol_carry', 'paper', 'hedged', 4,
   1000000000),
  ('valuation-sol', 'valuation-run', 'sol_control', 'paper', 'hedged', 4,
   1000000000);
INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES
  ('valuation-event-1', 1, 'MarketSnapshot', 'valuation-test', 1, 1,
   '1', 'valuation-test:1', repeat('a', 64), '{}'::jsonb),
  ('valuation-event-2', 1, 'MarketSnapshot', 'valuation-test', 2, 2,
   '2', 'valuation-test:2', repeat('b', 64), '{}'::jsonb),
  ('valuation-event-3', 1, 'MarketSnapshot', 'valuation-test', 3, 3,
   '3', 'valuation-test:3', repeat('c', 64), '{}'::jsonb);

INSERT INTO valuation_events (
  id, portfolio_run_id, source_event_id, quantity_atoms,
  protocol_nav_rate_atoms, market_sell_rate_atoms,
  reward_accrual_sol_atoms, basis_change_sol_atoms,
  reward_accrual_usd_atoms, basis_change_usd_atoms
) VALUES (
  'valuation-positive',
  'valuation-jito',
  'valuation-event-1',
  '1000000000',
  '1010000000',
  '1005000000',
  '10000000',
  '-5000000',
  '1500000',
  '-750000'
);

INSERT INTO valuation_events (
  id, portfolio_run_id, source_event_id, quantity_atoms,
  protocol_nav_rate_atoms, market_sell_rate_atoms,
  reward_accrual_sol_atoms, basis_change_sol_atoms,
  reward_accrual_usd_atoms, basis_change_usd_atoms
) VALUES (
  'valuation-nav-decrease',
  'valuation-jito',
  'valuation-event-2',
  '1000000000',
  '1000000000',
  '1005000000',
  '-10000000',
  '0',
  '-1500000',
  '0'
);

DO $$
BEGIN
  BEGIN
    INSERT INTO valuation_events (
      id, portfolio_run_id, source_event_id, quantity_atoms,
      protocol_nav_rate_atoms, market_sell_rate_atoms,
      reward_accrual_sol_atoms, basis_change_sol_atoms,
      reward_accrual_usd_atoms, basis_change_usd_atoms
    ) VALUES (
      'valuation-usd-without-sol',
      'valuation-jito',
      'valuation-event-3',
      '1000000000',
      '1000000000',
      '1000000000',
      '0',
      '0',
      '1',
      '0'
    );
    RAISE EXCEPTION 'unbacked valuation USD attribution was accepted';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO valuation_events (
      id, portfolio_run_id, source_event_id, quantity_atoms,
      protocol_nav_rate_atoms, market_sell_rate_atoms,
      reward_accrual_sol_atoms, basis_change_sol_atoms,
      reward_accrual_usd_atoms, basis_change_usd_atoms
    ) VALUES (
      'valuation-negative-zero',
      'valuation-jito',
      'valuation-event-3',
      '1000000000',
      '1000000000',
      '1000000000',
      '-0',
      '0',
      '0',
      '0'
    );
    RAISE EXCEPTION 'non-canonical negative zero was accepted';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO valuation_events (
      id, portfolio_run_id, source_event_id, quantity_atoms,
      protocol_nav_rate_atoms, market_sell_rate_atoms,
      reward_accrual_sol_atoms, basis_change_sol_atoms,
      reward_accrual_usd_atoms, basis_change_usd_atoms
    ) VALUES (
      'valuation-sol-contaminated',
      'valuation-sol',
      'valuation-event-3',
      '1000000000',
      '1000000000',
      '1000000000',
      '1',
      '0',
      '1',
      '0'
    );
    RAISE EXCEPTION 'SOL control JitoSOL attribution was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'SOL control valuation cannot contain JitoSOL attribution' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    INSERT INTO valuation_events (
      id, portfolio_run_id, source_event_id, quantity_atoms,
      protocol_nav_rate_atoms, market_sell_rate_atoms,
      reward_accrual_sol_atoms, basis_change_sol_atoms,
      reward_accrual_usd_atoms, basis_change_usd_atoms
    ) VALUES (
      'valuation-conflicting-duplicate',
      'valuation-jito',
      'valuation-event-2',
      '1000000000',
      '1000000000',
      '1005000000',
      '-10000000',
      '0',
      '-1500000',
      '0'
    );
    RAISE EXCEPTION 'duplicate valuation source was accepted';
  EXCEPTION
    WHEN unique_violation THEN NULL;
  END;

  IF (SELECT count(*) FROM ledger_batches
      WHERE portfolio_run_id = 'valuation-jito'
        AND event_type = 'valuation') <> 2
     OR (SELECT count(*) FROM ledger_entries le
         JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
         WHERE lb.portfolio_run_id = 'valuation-jito'
           AND lb.event_type = 'valuation') <> 3 THEN
    RAISE EXCEPTION 'valuation ledger batches are incomplete';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM ledger_entries
    WHERE ledger_batch_id = 'valuation-positive:ledger'
      AND account_debit = 'jitosol_protocol_value'
      AND account_credit = 'jitosol_reward_income'
      AND amount_atoms = '10000000'
      AND usd_value_atoms = '1500000'
  ) OR NOT EXISTS (
    SELECT 1
    FROM ledger_entries
    WHERE ledger_batch_id = 'valuation-positive:ledger'
      AND account_debit = 'jitosol_basis_pnl'
      AND account_credit = 'jitosol_market_value'
      AND amount_atoms = '5000000'
      AND usd_value_atoms = '750000'
  ) THEN
    RAISE EXCEPTION 'reward or market-basis direction is wrong';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM risk_events
    WHERE id = 'valuation-nav-decrease:risk'
      AND severity = 'critical'
      AND code = 'jitosol_nav_decrease'
      AND resolved_at IS NULL
  ) OR NOT (SELECT pause_entries FROM control_state WHERE singleton) THEN
    RAISE EXCEPTION 'negative JitoSOL NAV change did not fail closed';
  END IF;
END;
$$;

ROLLBACK;
