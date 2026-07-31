BEGIN;

DO $$
DECLARE
  hour_ms bigint := 3600000;
  started_at bigint := 1784419200000;
  result jsonb;
  leaderboard jsonb;
  btc jsonb;
  sol jsonb;
  i integer;
  event jsonb;
BEGIN
  INSERT INTO build_manifests (
    id, code_commit, mesh_commit, schema_version, config_hash
  ) VALUES (
    'funding-test-build', 'code', 'mesh', 33, repeat('1', 64)
  );
  INSERT INTO strategy_runs (
    id, execution_mode, config_hash, build_manifest_id,
    prng_seed, prng_version
  ) VALUES (
    'funding-test-run', 'paper', repeat('1', 64),
    'funding-test-build', 1, 'test'
  );
  INSERT INTO comparison_groups (
    id, strategy_run_id, mode, target_notional_usd_micros,
    entry_policy_version, exit_policy_version
  ) VALUES
    ('funding-test-independent', 'funding-test-run', 'independent',
      500000000, 'funding-v1', 'funding-v1'),
    ('funding-test-controlled', 'funding-test-run', 'synchronized',
      500000000, 'funding-v1', 'funding-v1');
  INSERT INTO portfolio_runs (
    id, strategy_run_id, comparison_group_id, variant,
    execution_mode, initial_capital_usd_micros
  ) VALUES
    ('funding-test-independent', 'funding-test-run',
      'funding-test-independent', 'cross_asset_funding', 'paper', 1000000000),
    ('funding-test-controlled', 'funding-test-run',
      'funding-test-controlled', 'cross_asset_funding', 'paper', 1000000000),
    ('funding-test-sol-independent', 'funding-test-run',
      'funding-test-independent', 'sol_control', 'paper', 1000000000),
    ('funding-test-sol-controlled', 'funding-test-run',
      'funding-test-controlled', 'sol_control', 'paper', 1000000000);
  UPDATE portfolio_runs
  SET state = 'hedged'
  WHERE id = 'funding-test-sol-controlled';

  FOR i IN 0..169 LOOP
    event := jsonb_build_object(
      'schemaVersion', 1,
      'eventId', 'funding-btc-' || i,
      'eventType', 'FundingObservation',
      'source', 'hyperliquid-funding:BTC',
      'observedAtMs', (started_at + i * hour_ms)::text,
      'sourceSlot', (started_at + i * hour_ms)::text,
      'sourceSequence', 'scan-' || i,
      'idempotencyKey', 'funding-btc-' || i,
      'rawPayloadHash', repeat('a', 64),
      'payload', jsonb_build_object(
        'scanId', 'funding-scan-' || i,
        'scanIndex', '0',
        'scanSize', '2',
        'venue', 'hyperliquid',
        'asset', 'BTC',
        'instrument', 'BTC-PERP',
        'sourceObservedAtMs', (started_at + i * hour_ms)::text,
        'sourceStatus', 'valid',
        'fundingRatePpmPerHour', '20',
        'realizedFundingRatePpm', '20',
        'realizedFundingAtMs', (started_at + i * hour_ms)::text,
        'markPriceUsdMicros', '50000000000',
        'openInterestUsdMicros', '1000000000000',
        'spotBidPriceUsdMicros', '49990000000',
        'spotAskPriceUsdMicros', '50010000000',
        'perpBidPriceUsdMicros', '49995000000',
        'perpAskPriceUsdMicros', '50005000000',
        'spotExitDepthAtoms', '100000000',
        'perpExitDepthAtoms', '100000000',
        'depthQualified', true
      )
    );
    result := record_funding_observation(event, 7200000);
    IF (result->>'inserted')::boolean <> true
       OR (result->>'scanComplete')::boolean <> false THEN
      RAISE EXCEPTION 'first scan member should be inserted but incomplete: %', result;
    END IF;

    event := jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            jsonb_set(
              jsonb_set(
                event,
                '{eventId}',
                to_jsonb(('funding-sol-' || i)::text)
              ),
              '{source}',
              to_jsonb('hyperliquid-funding:SOL'::text)
            ),
            '{idempotencyKey}',
            to_jsonb(('funding-sol-' || i)::text)
          ),
          '{payload,scanIndex}',
          '"1"'
        ),
        '{payload,asset}',
        '"SOL"'
      ),
      '{payload,instrument}',
      '"SOL-PERP"'
    );
    event := jsonb_set(event, '{payload,fundingRatePpmPerHour}', '"1"');
    result := record_funding_observation(event, 7200000);
    IF (result->>'inserted')::boolean <> true
       OR (result->>'scanComplete')::boolean <> true THEN
      RAISE EXCEPTION 'second scan member should complete the scan: %', result;
    END IF;

    IF i = 168 THEN
      result := run_cross_asset_paper_scan(
        'funding-scan-168',
        started_at + 168 * hour_ms,
        7200000,
        500000000,
        200000,
        50000,
        72
      );
      IF result->>'opened' <> '2' OR result->>'held' <> '0' THEN
        RAISE EXCEPTION 'top-ranked paper positions did not open: %', result;
      END IF;
    END IF;
  END LOOP;

  result := record_funding_observation(event, 7200000);
  IF (result->>'inserted')::boolean <> false
     OR (result->>'scanComplete')::boolean <> true THEN
    RAISE EXCEPTION 'duplicate observation was not idempotent: %', result;
  END IF;

  leaderboard := funding_leaderboard(
    started_at + 169 * hour_ms,
    7200000,
    500000000,
    200000,
    50000,
    72
  );
  SELECT value INTO btc
  FROM jsonb_array_elements(leaderboard->'items')
  WHERE value->>'asset' = 'BTC';
  SELECT value INTO sol
  FROM jsonb_array_elements(leaderboard->'items')
  WHERE value->>'asset' = 'SOL';

  IF leaderboard->>'historyRequiredHours' <> '168'
     OR leaderboard->>'minimumSamples24h' <> '24'
     OR btc->>'rank' <> '1'
     OR btc->>'fundingRatePpmPerHour' <> '20'
     OR btc->>'funding24hAveragePpm' <> '20'
     OR btc->>'fundingEmaPpm' <> '20'
     OR btc->>'percentilePpm' <> '1000000'
     OR btc->>'gateDistancePpm' <> '13'
     OR btc->>'historyReady' <> 'true'
     OR btc->>'eligible' <> 'true'
     OR sol->>'eligible' <> 'false' THEN
    RAISE EXCEPTION 'unexpected funding leaderboard: %', leaderboard;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM funding_observations
    WHERE venue = 'hyperliquid'
      AND asset = 'BTC'
      AND samples_24h = 24
      AND funding_24h_average_ppm = 20
  ) THEN
    RAISE EXCEPTION '24h funding state was not persisted';
  END IF;

  result := run_cross_asset_paper_scan(
    'funding-scan-169',
    started_at + 169 * hour_ms,
    7200000,
    500000000,
    200000,
    50000,
    72
  );
  IF result->>'opened' <> '0' OR result->>'held' <> '2'
     OR (SELECT count(*) FROM cross_asset_paper_positions
         WHERE status = 'open' AND asset = 'BTC') <> 2
     OR (SELECT count(*) FROM cross_asset_paper_decisions) <> 4
     OR (SELECT count(*) FROM funding_payments
         WHERE realization_status = 'realized') <> 2
     OR (SELECT COALESCE(sum(usd_value_atoms::numeric), 0)
         FROM funding_payments) <> 19996 THEN
    RAISE EXCEPTION 'unexpected cross-asset paper state: %', result;
  END IF;
END;
$$;

ROLLBACK;
