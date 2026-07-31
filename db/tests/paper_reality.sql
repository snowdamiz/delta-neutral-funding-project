BEGIN;

DO $$
DECLARE
  hour_ms bigint := 3600000;
  started_at bigint := 1784419200000;
  -- Exchange funding samples land on the hour; scans do not.
  now_ms bigint := started_at + 168 * hour_ms + hour_ms / 2;
  history jsonb;
  event jsonb;
  board jsonb;
  result jsonb;
BEGIN
  INSERT INTO build_manifests (
    id, code_commit, mesh_commit, schema_version, config_hash
  ) VALUES ('paper-reality-build', 'code', 'mesh', 39, repeat('8', 64));
  INSERT INTO strategy_runs (
    id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
  ) VALUES (
    'paper-reality-run', 'paper', repeat('8', 64),
    'paper-reality-build', 1, 'test'
  );
  INSERT INTO comparison_groups (
    id, strategy_run_id, mode, target_notional_usd_micros,
    entry_policy_version, exit_policy_version
  ) VALUES (
    'paper-reality-group', 'paper-reality-run', 'independent',
    500000000, 'funding-v1', 'funding-v1'
  );
  INSERT INTO portfolio_runs (
    id, strategy_run_id, comparison_group_id, variant,
    execution_mode, initial_capital_usd_micros
  ) VALUES (
    'paper-reality-portfolio', 'paper-reality-run',
    'paper-reality-group', 'cross_asset_funding', 'paper', 1000000000
  );

  SELECT jsonb_agg(jsonb_build_object(
    'observedAtMs', (started_at + i * hour_ms)::text,
    'ratePpm', '20'
  ) ORDER BY i)
  INTO history
  FROM generate_series(0, 167) AS i;

  event := jsonb_build_object(
    'schemaVersion', 1,
    'eventId', 'paper-reality-btc',
    'eventType', 'FundingObservation',
    'source', 'hyperliquid-funding:BTC',
    'observedAtMs', now_ms::text,
    'sourceSlot', now_ms::text,
    'sourceSequence', 'paper-reality-scan',
    'idempotencyKey', 'paper-reality-btc',
    'rawPayloadHash', repeat('8', 64),
    'payload', jsonb_build_object(
      'scanId', 'paper-reality-scan',
      'scanIndex', '0',
      'scanSize', '2',
      'venue', 'hyperliquid',
      'asset', 'BTC',
      'instrument', 'BTC-PERP',
      'sourceObservedAtMs', now_ms::text,
      'sourceStatus', 'valid',
      'fundingRatePpmPerHour', '30',
      'fundingHistory', history,
      'realizedFundingRatePpm', '20',
      'realizedFundingAtMs', now_ms::text,
      'markPriceUsdMicros', '50000000000',
      'openInterestUsdMicros', '1000000000000',
      'spotBidPriceUsdMicros', '0',
      'spotAskPriceUsdMicros', '0',
      'perpBidPriceUsdMicros', '49995000000',
      'perpAskPriceUsdMicros', '50005000000',
      'spotExitDepthAtoms', '0',
      'perpExitDepthAtoms', '100000000',
      'depthQualified', false
    )
  );
  PERFORM record_funding_observation(event, 7200000);

  event := jsonb_set(event, '{eventId}', '"paper-reality-purr"');
  event := jsonb_set(event, '{source}', '"hyperliquid-funding:PURR"');
  event := jsonb_set(event, '{idempotencyKey}', '"paper-reality-purr"');
  event := jsonb_set(event, '{payload,scanIndex}', '"1"');
  event := jsonb_set(event, '{payload,asset}', '"PURR"');
  event := jsonb_set(event, '{payload,instrument}', '"PURR-PERP"');
  event := jsonb_set(event, '{payload,fundingRatePpmPerHour}', '"20"');
  event := jsonb_set(event, '{payload,spotBidPriceUsdMicros}', '"199000"');
  event := jsonb_set(event, '{payload,spotAskPriceUsdMicros}', '"201000"');
  event := jsonb_set(event, '{payload,spotExitDepthAtoms}', '"10000000000000"');
  event := jsonb_set(event, '{payload,depthQualified}', 'true');
  PERFORM record_funding_observation(event, 7200000);

  board := funding_leaderboard(
    now_ms, 7200000, 500000000, 200000, 50000, 72
  );
  IF board#>>'{items,0,asset}' <> 'BTC'
     OR board#>>'{items,0,eligible}' <> 'false'
     OR board#>>'{items,1,asset}' <> 'PURR'
     OR board#>>'{items,1,historyReady}' <> 'true'
     OR board#>>'{items,1,eligible}' <> 'true' THEN
    RAISE EXCEPTION 'historical warm-up was not applied: %', board;
  END IF;

  result := run_cross_asset_paper_scan(
    'paper-reality-scan', now_ms, 7200000,
    500000000, 200000, 50000, 72
  );
  IF result->>'opened' <> '1'
     OR NOT EXISTS (
       SELECT 1 FROM cross_asset_paper_positions
       WHERE status = 'open' AND asset = 'PURR'
     ) THEN
    RAISE EXCEPTION 'eligible market was skipped for raw rank one: %', result;
  END IF;
END;
$$;

ROLLBACK;
