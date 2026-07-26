\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'comparison-build', 'test', 'test', 18, repeat('0', 64)
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
) VALUES
  (
    'comparison-entry-event', 1, 'MarketSnapshot', 'comparison-test', 1, 1,
    '1', 'comparison-test:1', repeat('a', 64), '{}'::jsonb
  ),
  (
    'comparison-atomic-event', 1, 'MarketSnapshot', 'comparison-test', 2, 2,
    '2', 'comparison-test:2', repeat('b', 64), '{}'::jsonb
  ),
  (
    'comparison-hold-event', 1, 'MarketSnapshot', 'comparison-test', 3, 3,
    '3', 'comparison-test:3', repeat('c', 64), '{}'::jsonb
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
DECLARE
  v_sol_hold jsonb := '{
    "portfolioRunId":"comparison-synchronized-sol",
    "expectedStateVersion":"4",
    "plan":{
      "variant":"sol_control",
      "action":"hold",
      "reason":"within_delta_band",
      "nextState":"hedged",
      "nextRandomState":"99",
      "observedAtMs":"3",
      "spotAsset":"SOL",
      "currentSpotQuantityAtoms":"1000000000",
      "nextSpotQuantityAtoms":"1000000000",
      "nextPerpShortQuantityAtoms":"1000000000",
      "protocolNavLamports":"1000000000",
      "marketRateLamports":"1000000000",
      "spotEquivalentLamports":"1000000000",
      "deltaLamports":"0",
      "deltaBps":"0",
      "rewardSolLamports":"0",
      "basisSolLamports":"0",
      "rewardUsdMicros":"0",
      "basisUsdMicros":"0",
      "spotPlaced":false,
      "spotStatus":"rejected",
      "spotRequestedQuantityAtoms":"0",
      "spotFilledQuantityAtoms":"0",
      "spotPriceAtoms":"0",
      "spotGrossUsdAtoms":"0",
      "spotFeeUsdAtoms":"0",
      "perpPlaced":false,
      "perpSide":"",
      "perpStatus":"rejected",
      "perpRequestedQuantityAtoms":"0",
      "perpFilledQuantityAtoms":"0",
      "perpPriceAtoms":"0",
      "perpGrossUsdAtoms":"0",
      "perpFeeUsdAtoms":"0"
    },
    "spotIntent":{},
    "spotIntentHash":"1111111111111111111111111111111111111111111111111111111111111111",
    "perpIntent":{},
    "perpIntentHash":"2222222222222222222222222222222222222222222222222222222222222222"
  }'::jsonb;
  v_jito_hold jsonb := '{
    "portfolioRunId":"comparison-synchronized-jito",
    "expectedStateVersion":"4",
    "plan":{
      "variant":"jitosol_carry",
      "action":"hold",
      "reason":"within_delta_band",
      "nextState":"hedged",
      "nextRandomState":"99",
      "observedAtMs":"3",
      "spotAsset":"JitoSOL",
      "currentSpotQuantityAtoms":"800000000",
      "nextSpotQuantityAtoms":"800000000",
      "nextPerpShortQuantityAtoms":"1000000000",
      "protocolNavLamports":"1250000000",
      "marketRateLamports":"1250000000",
      "spotEquivalentLamports":"1000000000",
      "deltaLamports":"0",
      "deltaBps":"0",
      "rewardSolLamports":"0",
      "basisSolLamports":"0",
      "rewardUsdMicros":"0",
      "basisUsdMicros":"0",
      "spotPlaced":false,
      "spotStatus":"rejected",
      "spotRequestedQuantityAtoms":"0",
      "spotFilledQuantityAtoms":"0",
      "spotPriceAtoms":"0",
      "spotGrossUsdAtoms":"0",
      "spotFeeUsdAtoms":"0",
      "perpPlaced":false,
      "perpSide":"",
      "perpStatus":"rejected",
      "perpRequestedQuantityAtoms":"0",
      "perpFilledQuantityAtoms":"0",
      "perpPriceAtoms":"0",
      "perpGrossUsdAtoms":"0",
      "perpFeeUsdAtoms":"0"
    },
    "spotIntent":{},
    "spotIntentHash":"3333333333333333333333333333333333333333333333333333333333333333",
    "perpIntent":{},
    "perpIntentHash":"4444444444444444444444444444444444444444444444444444444444444444"
  }'::jsonb;
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
  IF EXISTS (
    SELECT 1
    FROM execution_intents
    WHERE portfolio_run_id LIKE 'comparison-synchronized-%'
      AND jsonb_typeof(intent_json) <> 'object'
  ) THEN
    RAISE EXCEPTION 'synchronized intent was not stored as an object';
  END IF;

  BEGIN
    PERFORM apply_synchronized_paper_position_plans(
      'comparison-synchronized',
      'comparison-atomic-event',
      jsonb_set(v_sol_hold, '{plan,action}', '"exit"'),
      v_jito_hold
    );
    RAISE EXCEPTION 'mismatched synchronized exit schedule was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'synchronized position plans must share exit schedule' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    PERFORM apply_synchronized_paper_position_plans(
      'comparison-synchronized',
      'comparison-atomic-event',
      v_sol_hold,
      jsonb_set(v_jito_hold, '{expectedStateVersion}', '"999"')
    );
    RAISE EXCEPTION 'partial synchronized position transaction was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'JitoSOL comparison portfolio state changed' THEN
        RAISE;
      END IF;
  END;
  IF EXISTS (
    SELECT 1
    FROM position_snapshots
    WHERE source_event_id = 'comparison-atomic-event'
  ) THEN
    RAISE EXCEPTION 'failed synchronized position transaction was not atomic';
  END IF;

  PERFORM apply_synchronized_paper_position_plans(
    'comparison-synchronized',
    'comparison-hold-event',
    v_sol_hold,
    v_jito_hold
  );
  IF (
    SELECT count(*)
    FROM position_snapshots
    WHERE source_event_id = 'comparison-hold-event'
  ) <> 2 THEN
    RAISE EXCEPTION 'synchronized position update did not commit both books';
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
