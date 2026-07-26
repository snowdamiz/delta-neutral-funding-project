\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'comparison-build', 'test', 'test', 16, repeat('0', 64)
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
INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'comparison-entry-event', 1, 'MarketSnapshot', 'comparison-test', 1, 1,
  '1', 'comparison-test:1', repeat('a', 64), '{}'::jsonb
);

SELECT apply_synchronized_paper_entries(
  'comparison-synchronized',
  'comparison-entry-event',
  '{
    "portfolioRunId":"comparison-synchronized-sol",
    "expectedStateVersion":"0",
    "plan":{
      "variant":"sol_control",
      "outcome":"hedged",
      "reason":"paper_entry_hedged",
      "nextState":"hedged",
      "nextRandomState":"99",
      "spotPlaced":true,
      "spotStatus":"filled",
      "spotAsset":"SOL",
      "spotRequestedQuantityAtoms":"1000000000",
      "spotFilledQuantityAtoms":"1000000000",
      "spotPriceAtoms":"150100000",
      "spotGrossUsdAtoms":"150100000",
      "spotFeeUsdAtoms":"75050",
      "perpPlaced":true,
      "perpStatus":"filled",
      "perpRequestedQuantityAtoms":"1000000000",
      "perpFilledQuantityAtoms":"1000000000",
      "perpPriceAtoms":"149900000",
      "perpGrossUsdAtoms":"149900000",
      "perpFeeUsdAtoms":"59960"
    },
    "spotIntent":{"leg":"SPOT"},
    "spotIntentHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "perpIntent":{"leg":"PERP"},
    "perpIntentHash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }'::jsonb,
  '{
    "portfolioRunId":"comparison-synchronized-jito",
    "expectedStateVersion":"0",
    "plan":{
      "variant":"jitosol_carry",
      "outcome":"hedged",
      "reason":"paper_entry_hedged",
      "nextState":"hedged",
      "nextRandomState":"99",
      "spotPlaced":true,
      "spotStatus":"filled",
      "spotAsset":"JitoSOL",
      "spotRequestedQuantityAtoms":"800000000",
      "spotFilledQuantityAtoms":"800000000",
      "spotPriceAtoms":"187625000",
      "spotGrossUsdAtoms":"150100000",
      "spotFeeUsdAtoms":"75050",
      "perpPlaced":true,
      "perpStatus":"filled",
      "perpRequestedQuantityAtoms":"1000000000",
      "perpFilledQuantityAtoms":"1000000000",
      "perpPriceAtoms":"149900000",
      "perpGrossUsdAtoms":"149900000",
      "perpFeeUsdAtoms":"59960"
    },
    "spotIntent":{"leg":"SPOT"},
    "spotIntentHash":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "perpIntent":{"leg":"PERP"},
    "perpIntentHash":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  }'::jsonb
);

DO $$
BEGIN
  IF (SELECT count(*) FROM portfolio_runs
      WHERE strategy_run_id = 'comparison-run') <> 4 THEN
    RAISE EXCEPTION 'comparison portfolios were not isolated';
  END IF;
  IF (SELECT count(*) FROM portfolio_runs
      WHERE comparison_group_id = 'comparison-synchronized'
        AND state = 'hedged') <> 2 THEN
    RAISE EXCEPTION 'synchronized entry did not commit both portfolios';
  END IF;

  BEGIN
    PERFORM apply_synchronized_paper_entries(
      'comparison-synchronized',
      'comparison-entry-event',
      '{"portfolioRunId":"comparison-synchronized-sol","plan":{"variant":"sol_control","perpRequestedQuantityAtoms":"1"}}'::jsonb,
      '{"portfolioRunId":"comparison-synchronized-jito","plan":{"variant":"jitosol_carry","perpRequestedQuantityAtoms":"2"}}'::jsonb
    );
    RAISE EXCEPTION 'mismatched synchronized notional was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'synchronized entries must share positive SOL notional' THEN
        RAISE;
      END IF;
  END;

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
