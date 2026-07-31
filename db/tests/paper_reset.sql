\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'local-paper-build', 'test', 'test', 32, repeat('a', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'local-paper-run', 'paper', repeat('a', 64),
  'local-paper-build', 42, 'xorshift64star-v1'
);
INSERT INTO comparison_groups (
  id, strategy_run_id, mode, target_notional_usd_micros,
  entry_policy_version, exit_policy_version
) VALUES
  (
    'local-paper-run:independent', 'local-paper-run', 'independent',
    500000000, 'paper-entry-v1', 'paper-exit-v1'
  ),
  (
    'local-paper-run:synchronized', 'local-paper-run', 'synchronized',
    500000000, 'paper-entry-v1', 'paper-exit-v1'
  );
INSERT INTO portfolio_runs (
  id, strategy_run_id, comparison_group_id, variant, execution_mode,
  initial_capital_usd_micros
) VALUES
  (
    'local-sol-control', 'local-paper-run',
    'local-paper-run:independent', 'sol_control', 'paper', 1000000000
  ),
  (
    'local-jitosol-carry', 'local-paper-run',
    'local-paper-run:independent', 'jitosol_carry', 'paper', 1000000000
  ),
  (
    'local-sync-sol-control', 'local-paper-run',
    'local-paper-run:synchronized', 'sol_control', 'paper', 1000000000
  ),
  (
    'local-sync-jitosol-carry', 'local-paper-run',
    'local-paper-run:synchronized', 'jitosol_carry', 'paper', 1000000000
  );
INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'reset-event', 1, 'MarketSnapshot', 'paper', 1, 1,
  '1', 'reset-event', repeat('b', 64), '{}'::jsonb
);

DO $$
DECLARE
  v_result jsonb;
  v_approval_expires_at_ms bigint;
BEGIN
  v_approval_expires_at_ms :=
    floor(extract(epoch FROM clock_timestamp()) * 1000) + 60000;
  BEGIN
    PERFORM apply_paper_reset(
      5000000000, 2500000000, v_approval_expires_at_ms - 60001,
      'expired-reset-test', 'expired paper reset', repeat('e', 64)
    );
    RAISE EXCEPTION 'paper reset accepted an expired approval';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'paper reset approval is expired or too far in the future' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    PERFORM apply_paper_reset(
      5000000000, 2500000000, v_approval_expires_at_ms,
      'reset-test', 'new paper run', repeat('c', 64)
    );
    RAISE EXCEPTION 'paper reset succeeded while entries were not paused';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'paper reset requires pause-all' THEN
        RAISE;
      END IF;
  END;

  UPDATE control_state
  SET pause_entries = true, pause_all = true, reason = 'reset test'
  WHERE singleton;
  UPDATE portfolio_runs
  SET id = 'unexpected-sol-control'
  WHERE id = 'local-sol-control';
  BEGIN
    PERFORM apply_paper_reset(
      5000000000, 2500000000, v_approval_expires_at_ms,
      'identity-reset-test', 'invalid paper identities', repeat('f', 64)
    );
    RAISE EXCEPTION 'paper reset accepted altered portfolio identities';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'paper reset requires the exact four paper portfolios' THEN
        RAISE;
      END IF;
  END;
  UPDATE portfolio_runs
  SET id = 'local-sol-control'
  WHERE id = 'unexpected-sol-control';

  UPDATE portfolio_runs SET state = 'hedged' WHERE id = 'local-sol-control';

  BEGIN
    PERFORM apply_paper_reset(
      5000000000, 2500000000, v_approval_expires_at_ms,
      'reset-test', 'new paper run', repeat('c', 64)
    );
    RAISE EXCEPTION 'paper reset succeeded with an exposed portfolio';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'paper reset requires every portfolio to be idle' THEN
        RAISE;
      END IF;
  END;

  UPDATE portfolio_runs SET state = 'idle' WHERE id = 'local-sol-control';
  v_result := apply_paper_reset(
    5000000000, 2500000000, v_approval_expires_at_ms,
    'reset-test', 'new paper run', repeat('c', 64)
  );

  IF v_result->>'status' <> 'applied'
     OR (v_result->>'duplicate')::boolean
     OR v_result->>'initialUsdcMicros' <> '5000000000'
     OR v_result->>'initialCollateralUsdMicros' <> '2500000000' THEN
    RAISE EXCEPTION 'paper reset result is invalid: %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM normalized_events) THEN
    RAISE EXCEPTION 'paper reset retained source evidence';
  END IF;
  IF (
    SELECT count(*)
    FROM portfolio_runs
    WHERE strategy_run_id = 'local-paper-run'
      AND state = 'idle'
      AND state_version = 0
      AND random_state = 42
      AND initial_capital_usd_micros = 5000000000
  ) <> 4 THEN
    RAISE EXCEPTION 'paper reset did not restore four clean portfolios';
  END IF;
  IF (
    SELECT count(*)
    FROM ledger_batches lb
    JOIN ledger_entries le ON le.ledger_batch_id = lb.id
    WHERE lb.event_type = 'opening_capital'
      AND le.amount_atoms = '5000000000'
      AND le.usd_value_atoms = '5000000000'
  ) <> 4 THEN
    RAISE EXCEPTION 'paper reset did not restore four opening ledgers';
  END IF;
  IF NOT (SELECT pause_entries AND pause_all FROM control_state WHERE singleton) THEN
    RAISE EXCEPTION 'paper reset resumed execution';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM operator_commands
    WHERE idempotency_key = 'reset-test'
      AND action = 'paper_reset'
  ) THEN
    RAISE EXCEPTION 'paper reset audit command is missing';
  END IF;

  v_result := apply_paper_reset(
    5000000000, 2500000000, v_approval_expires_at_ms,
    'reset-test', 'new paper run', repeat('c', 64)
  );
  IF NOT (v_result->>'duplicate')::boolean
     OR (SELECT count(*) FROM operator_commands
         WHERE idempotency_key = 'reset-test') <> 1 THEN
    RAISE EXCEPTION 'exact paper reset retry was not idempotent';
  END IF;

  BEGIN
    PERFORM apply_paper_reset(
      6000000000, 2500000000, v_approval_expires_at_ms,
      'reset-test', 'new paper run', repeat('d', 64)
    );
    RAISE EXCEPTION 'conflicting paper reset retry was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'idempotency key reused for a different operator command' THEN
        RAISE;
      END IF;
  END;
END;
$$;

ROLLBACK;
