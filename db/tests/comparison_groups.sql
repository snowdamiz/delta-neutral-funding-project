\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'comparison-build', 'test', 'test', 15, repeat('0', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'comparison-run', 'paper', repeat('0', 64),
  'comparison-build', 42, 'xorshift64star-v1'
);
INSERT INTO comparison_groups (
  id, strategy_run_id, mode, target_notional_usd_micros,
  entry_policy_version, exit_policy_version
) VALUES
  (
    'comparison-independent', 'comparison-run', 'independent', 500000000,
    'paper-entry-v1', 'paper-exit-v1'
  ),
  (
    'comparison-synchronized', 'comparison-run', 'synchronized', 500000000,
    'paper-entry-v1', 'paper-exit-v1'
  );
INSERT INTO portfolio_runs (
  id, strategy_run_id, comparison_group_id, variant, execution_mode,
  initial_capital_usd_micros
) VALUES
  (
    'comparison-independent-sol', 'comparison-run',
    'comparison-independent', 'sol_control', 'paper', 1000000000
  ),
  (
    'comparison-independent-jito', 'comparison-run',
    'comparison-independent', 'jitosol_carry', 'paper', 1000000000
  ),
  (
    'comparison-synchronized-sol', 'comparison-run',
    'comparison-synchronized', 'sol_control', 'paper', 1000000000
  ),
  (
    'comparison-synchronized-jito', 'comparison-run',
    'comparison-synchronized', 'jitosol_carry', 'paper', 1000000000
  );

DO $$
BEGIN
  IF (SELECT count(*) FROM portfolio_runs
      WHERE strategy_run_id = 'comparison-run') <> 4 THEN
    RAISE EXCEPTION 'comparison portfolios were not isolated';
  END IF;

  BEGIN
    INSERT INTO portfolio_runs (
      id, strategy_run_id, comparison_group_id, variant, execution_mode,
      initial_capital_usd_micros
    ) VALUES (
      'comparison-duplicate-sol', 'comparison-run',
      'comparison-synchronized', 'sol_control', 'paper', 1000000000
    );
    RAISE EXCEPTION 'duplicate comparison variant was accepted';
  EXCEPTION
    WHEN unique_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO strategy_runs (
      id, execution_mode, config_hash, build_manifest_id,
      prng_seed, prng_version
    ) VALUES (
      'comparison-other-run', 'paper', repeat('0', 64),
      'comparison-build', 42, 'xorshift64star-v1'
    );
    INSERT INTO portfolio_runs (
      id, strategy_run_id, comparison_group_id, variant, execution_mode,
      initial_capital_usd_micros
    ) VALUES (
      'comparison-wrong-run', 'comparison-other-run',
      'comparison-synchronized', 'sol_control', 'paper', 1000000000
    );
    RAISE EXCEPTION 'cross-run comparison portfolio was accepted';
  EXCEPTION
    WHEN foreign_key_violation THEN NULL;
  END;
END;
$$;

ROLLBACK;
