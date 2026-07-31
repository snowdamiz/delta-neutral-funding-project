\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  hour_ms bigint := 3600000;
  started_at bigint := 1784419200000;
  result jsonb;
  leaderboard jsonb;
  top_pair jsonb;
  event jsonb;
  i integer;
  expected_funding numeric;
BEGIN
  INSERT INTO build_manifests (
    id, code_commit, mesh_commit, schema_version, config_hash
  ) VALUES (
    'cross-venue-test-build', 'code', 'mesh', 36, repeat('4', 64)
  );
  INSERT INTO strategy_runs (
    id, execution_mode, config_hash, build_manifest_id,
    prng_seed, prng_version
  ) VALUES (
    'cross-venue-test-run', 'paper', repeat('4', 64),
    'cross-venue-test-build', 1, 'test'
  );
  INSERT INTO comparison_groups (
    id, strategy_run_id, mode, target_notional_usd_micros,
    entry_policy_version, exit_policy_version
  ) VALUES
    ('cross-venue-independent', 'cross-venue-test-run', 'independent',
      500000000, 'cross-venue-v1', 'cross-venue-v1'),
    ('cross-venue-controlled', 'cross-venue-test-run', 'synchronized',
      500000000, 'cross-venue-v1', 'cross-venue-v1');
  INSERT INTO portfolio_runs (
    id, strategy_run_id, comparison_group_id, variant,
    execution_mode, initial_capital_usd_micros
  ) VALUES
    ('cross-venue-independent', 'cross-venue-test-run',
      'cross-venue-independent', 'cross_venue_funding', 'paper', 1000000000),
    ('cross-venue-controlled', 'cross-venue-test-run',
      'cross-venue-controlled', 'cross_venue_funding', 'paper', 1000000000),
    ('cross-venue-sol-independent', 'cross-venue-test-run',
      'cross-venue-independent', 'sol_control', 'paper', 1000000000),
    ('cross-venue-sol-controlled', 'cross-venue-test-run',
      'cross-venue-controlled', 'sol_control', 'paper', 1000000000);
  UPDATE portfolio_runs
  SET state = 'hedged'
  WHERE id = 'cross-venue-sol-controlled';

  FOR i IN 0..169 LOOP
    event := jsonb_build_object(
      'schemaVersion', 1,
      'eventId', 'cross-venue-high-' || i,
      'eventType', 'FundingObservation',
      'source', 'venue-high-funding:BTC',
      'observedAtMs', (started_at + i * hour_ms)::text,
      'sourceSlot', (started_at + i * hour_ms)::text,
      'sourceSequence', 'cross-venue-scan-' || i,
      'idempotencyKey', 'cross-venue-high-' || i,
      'rawPayloadHash', repeat('a', 64),
      'payload', jsonb_build_object(
        'scanId', 'cross-venue-scan-' || i,
        'scanIndex', '0',
        'scanSize', '2',
        'venue', 'venue_high',
        'asset', 'BTC',
        'instrument', 'BTC-PERP',
        'sourceObservedAtMs', (started_at + i * hour_ms)::text,
        'sourceStatus', 'valid',
        'fundingRatePpmPerHour', '1000',
        'realizedFundingRatePpm', '30',
        'realizedFundingAtMs', (started_at + i * hour_ms)::text,
        'markPriceUsdMicros', '50000000000',
        'openInterestUsdMicros', '1000000000000',
        'spotBidPriceUsdMicros', '49990000000',
        'spotAskPriceUsdMicros', '50010000000',
        'perpBidPriceUsdMicros', '49995000000',
        'perpAskPriceUsdMicros', '50005000000',
        'spotExitDepthAtoms', '100000000',
        'perpExitDepthAtoms', '100000000',
        'depthQualified', true,
        'marginStatus', 'valid',
        'maintenanceMarginPpm', '25000'
      )
    );
    PERFORM record_funding_observation(event, 7200000);

    event := jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            event,
            '{eventId}',
            to_jsonb(('cross-venue-low-' || i)::text)
          ),
          '{source}',
          to_jsonb('venue-low-funding:BTC'::text)
        ),
        '{idempotencyKey}',
        to_jsonb(('cross-venue-low-' || i)::text)
      ),
      '{payload,scanIndex}',
      '"1"'
    );
    event := jsonb_set(event, '{payload,venue}', '"venue_low"');
    event := jsonb_set(event, '{payload,fundingRatePpmPerHour}', '"-1000"');
    event := jsonb_set(event, '{payload,realizedFundingRatePpm}', '"0"');
    PERFORM record_funding_observation(event, 7200000);

    IF i = 168 THEN
      leaderboard := cross_venue_funding_leaderboard(
        started_at + i * hour_ms,
        7200000,
        500000000,
        200000,
        50000,
        72,
        500000000,
        1500000,
        1000
      );
      top_pair := leaderboard->'items'->0;
      IF top_pair->>'rank' <> '1'
         OR top_pair->>'asset' <> 'BTC'
         OR top_pair->>'shortVenue' <> 'venue_high'
         OR top_pair->>'longVenue' <> 'venue_low'
         OR top_pair->>'realizedSpreadPpmPerHour' <> '30'
         OR top_pair->>'gateDistancePpm' <> '23'
         OR top_pair->>'historyReady' <> 'true'
         OR top_pair->>'eligible' <> 'true' THEN
        RAISE EXCEPTION 'unexpected cross-venue leaderboard: %', leaderboard;
      END IF;

      result := run_cross_venue_paper_scan(
        'cross-venue-scan-' || i,
        started_at + i * hour_ms,
        7200000,
        500000000,
        200000,
        50000,
        72,
        500000000,
        1500000,
        1000
      );
      IF result->>'opened' <> '2'
         OR (SELECT count(*) FROM cross_venue_paper_positions
             WHERE status = 'open'
               AND asset = 'BTC'
               AND short_venue = 'venue_high'
               AND long_venue = 'venue_low') <> 2 THEN
        RAISE EXCEPTION 'cross-venue positions did not open: %', result;
      END IF;
    END IF;
  END LOOP;

  result := run_cross_venue_paper_scan(
    'cross-venue-scan-169',
    started_at + 169 * hour_ms,
    7200000,
    500000000,
    200000,
    50000,
    72,
    500000000,
    1500000,
    1000
  );
  SELECT sum(
    trunc(
      quantity_atoms * 50000000000::numeric / 1000000000
        * 30 / 1000000
    )
  )
  INTO expected_funding
  FROM cross_venue_paper_positions;
  IF result->>'held' <> '2'
     OR (SELECT count(*) FROM funding_payments
         WHERE portfolio_run_id LIKE 'cross-venue-%'
           AND venue_payment_id LIKE 'cross-venue:%') <> 4
     OR (SELECT sum(usd_value_atoms::numeric) FROM funding_payments
         WHERE portfolio_run_id LIKE 'cross-venue-%') <> expected_funding THEN
    RAISE EXCEPTION 'realized venue funding was not recorded once: %', result;
  END IF;

  result := run_cross_venue_paper_scan(
    'cross-venue-scan-169',
    started_at + 169 * hour_ms,
    7200000,
    500000000,
    200000,
    50000,
    72,
    500000000,
    1500000,
    1000
  );
  IF result->>'duplicate' <> 'true'
     OR (SELECT count(*) FROM funding_payments
         WHERE portfolio_run_id LIKE 'cross-venue-%'
           AND venue_payment_id LIKE 'cross-venue:%') <> 4 THEN
    RAISE EXCEPTION 'duplicate scan reapplied funding: %', result;
  END IF;

  event := jsonb_set(event, '{eventId}', '"cross-venue-high-170"');
  event := jsonb_set(event, '{source}', '"venue-high-funding:BTC"');
  event := jsonb_set(
    event, '{observedAtMs}', to_jsonb((started_at + 170 * hour_ms)::text)
  );
  event := jsonb_set(
    event, '{sourceSlot}', to_jsonb((started_at + 170 * hour_ms)::text)
  );
  event := jsonb_set(event, '{sourceSequence}', '"cross-venue-scan-170"');
  event := jsonb_set(event, '{idempotencyKey}', '"cross-venue-high-170"');
  event := jsonb_set(event, '{payload,scanId}', '"cross-venue-scan-170"');
  event := jsonb_set(event, '{payload,scanIndex}', '"0"');
  event := jsonb_set(event, '{payload,venue}', '"venue_high"');
  event := jsonb_set(
    event,
    '{payload,sourceObservedAtMs}',
    to_jsonb((started_at + 170 * hour_ms)::text)
  );
  event := jsonb_set(event, '{payload,sourceStatus}', '"invalid"');
  event := jsonb_set(event, '{payload,fundingRatePpmPerHour}', '"1000"');
  event := jsonb_set(event, '{payload,realizedFundingRatePpm}', '"30"');
  event := jsonb_set(
    event,
    '{payload,realizedFundingAtMs}',
    to_jsonb((started_at + 170 * hour_ms)::text)
  );
  event := jsonb_set(event, '{payload,depthQualified}', 'false');
  PERFORM record_funding_observation(event, 7200000);

  event := jsonb_set(event, '{eventId}', '"cross-venue-low-170"');
  event := jsonb_set(event, '{source}', '"venue-low-funding:BTC"');
  event := jsonb_set(event, '{idempotencyKey}', '"cross-venue-low-170"');
  event := jsonb_set(event, '{payload,scanIndex}', '"1"');
  event := jsonb_set(event, '{payload,venue}', '"venue_low"');
  event := jsonb_set(event, '{payload,sourceStatus}', '"valid"');
  event := jsonb_set(event, '{payload,fundingRatePpmPerHour}', '"-1000"');
  event := jsonb_set(event, '{payload,realizedFundingRatePpm}', '"0"');
  event := jsonb_set(event, '{payload,depthQualified}', 'true');
  PERFORM record_funding_observation(event, 7200000);

  result := run_cross_venue_paper_scan(
    'cross-venue-scan-170',
    started_at + 170 * hour_ms,
    7200000,
    500000000,
    200000,
    50000,
    72,
    500000000,
    1500000,
    1000
  );
  IF result->>'blocked' <> '2'
     OR (SELECT count(*) FROM cross_venue_paper_positions
         WHERE status = 'exit_blocked') <> 2
     OR (SELECT count(*) FROM portfolio_runs
         WHERE variant = 'cross_venue_funding'
           AND state = 'emergency_flatten') <> 2
     OR (SELECT count(*) FROM risk_events
         WHERE code = 'cross_venue_one_leg_uncertain'
           AND severity = 'critical'
           AND action_taken = 'emergency_flatten'
           AND resolved_at IS NULL) <> 2 THEN
    RAISE EXCEPTION 'one-leg uncertainty was not fenced: %', result;
  END IF;

  event := jsonb_set(event, '{eventId}', '"cross-venue-high-171"');
  event := jsonb_set(event, '{source}', '"venue-high-funding:BTC"');
  event := jsonb_set(
    event, '{observedAtMs}', to_jsonb((started_at + 171 * hour_ms)::text)
  );
  event := jsonb_set(
    event, '{sourceSlot}', to_jsonb((started_at + 171 * hour_ms)::text)
  );
  event := jsonb_set(event, '{sourceSequence}', '"cross-venue-scan-171"');
  event := jsonb_set(event, '{idempotencyKey}', '"cross-venue-high-171"');
  event := jsonb_set(event, '{payload,scanId}', '"cross-venue-scan-171"');
  event := jsonb_set(event, '{payload,scanIndex}', '"0"');
  event := jsonb_set(event, '{payload,venue}', '"venue_high"');
  event := jsonb_set(
    event,
    '{payload,sourceObservedAtMs}',
    to_jsonb((started_at + 171 * hour_ms)::text)
  );
  event := jsonb_set(event, '{payload,sourceStatus}', '"valid"');
  event := jsonb_set(event, '{payload,maintenanceMarginPpm}', '"1000000"');
  event := jsonb_set(event, '{payload,fundingRatePpmPerHour}', '"1000"');
  event := jsonb_set(event, '{payload,realizedFundingRatePpm}', '"30"');
  event := jsonb_set(
    event,
    '{payload,realizedFundingAtMs}',
    to_jsonb((started_at + 171 * hour_ms)::text)
  );
  event := jsonb_set(event, '{payload,depthQualified}', 'true');
  PERFORM record_funding_observation(event, 7200000);

  event := jsonb_set(event, '{eventId}', '"cross-venue-low-171"');
  event := jsonb_set(event, '{source}', '"venue-low-funding:BTC"');
  event := jsonb_set(event, '{idempotencyKey}', '"cross-venue-low-171"');
  event := jsonb_set(event, '{payload,scanIndex}', '"1"');
  event := jsonb_set(event, '{payload,venue}', '"venue_low"');
  event := jsonb_set(event, '{payload,fundingRatePpmPerHour}', '"-1000"');
  event := jsonb_set(event, '{payload,realizedFundingRatePpm}', '"0"');
  PERFORM record_funding_observation(event, 7200000);

  result := run_cross_venue_paper_scan(
    'cross-venue-scan-171',
    started_at + 171 * hour_ms,
    7200000,
    500000000,
    200000,
    50000,
    72,
    500000000,
    1500000,
    1000
  );
  IF result->>'closed' <> '2'
     OR (SELECT count(*) FROM cross_venue_paper_positions
         WHERE status = 'closed') <> 2
     OR (SELECT count(*) FROM portfolio_runs
         WHERE variant = 'cross_venue_funding' AND state = 'idle') <> 2
     OR EXISTS (
       SELECT 1 FROM risk_events
       WHERE code = 'cross_venue_one_leg_uncertain'
         AND resolved_at IS NULL
     )
     OR (SELECT count(*) FROM cross_venue_paper_decisions
         WHERE scan_id = 'cross-venue-scan-171'
           AND reason_code = 'venue_margin_breaker') <> 2
     OR (SELECT count(*) FROM cross_venue_paper_positions
         WHERE short_maintenance_margin_ppm = 1000000) <> 2
     THEN
    RAISE EXCEPTION 'emergency pair did not flatten after recovery: %', result;
  END IF;
END;
$$;

ROLLBACK;
