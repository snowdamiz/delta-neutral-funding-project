\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  started_at bigint := 1780272000000;
  observed_at bigint;
  event jsonb;
  result jsonb;
  scores jsonb;
  assessment jsonb;
  i integer;
BEGIN
  INSERT INTO build_manifests (
    id, code_commit, mesh_commit, schema_version, config_hash
  ) VALUES (
    'wallet-test-build', 'code', 'mesh', 37, repeat('5', 64)
  );
  INSERT INTO strategy_runs (
    id, execution_mode, config_hash, build_manifest_id,
    prng_seed, prng_version
  ) VALUES (
    'wallet-test-run', 'paper', repeat('5', 64),
    'wallet-test-build', 1, 'test'
  );
  INSERT INTO comparison_groups (
    id, strategy_run_id, mode, target_notional_usd_micros,
    entry_policy_version, exit_policy_version
  ) VALUES (
    'wallet-test-group', 'wallet-test-run', 'independent',
    500000000, 'wallet-v1', 'wallet-v1'
  );
  INSERT INTO portfolio_runs (
    id, strategy_run_id, comparison_group_id, variant,
    execution_mode, initial_capital_usd_micros
  ) VALUES
    ('wallet-flow', 'wallet-test-run', 'wallet-test-group',
      'hyperliquid_wallet_flow', 'paper', 1000000000),
    ('wallet-mirror', 'wallet-test-run', 'wallet-test-group',
      'hyperliquid_wallet_mirror', 'paper', 1000000000),
    ('wallet-fade', 'wallet-test-run', 'wallet-test-group',
      'hyperliquid_wallet_fade', 'paper', 1000000000),
    ('wallet-phase1', 'wallet-test-run', 'wallet-test-group',
      'cross_asset_funding', 'paper', 1000000000),
    ('wallet-phase2', 'wallet-test-run', 'wallet-test-group',
      'negative_funding_reverse', 'paper', 1000000000);

  FOR i IN 0..43 LOOP
    observed_at := started_at + i * 3600000;
    event := jsonb_build_object(
      'schemaVersion', 1,
      'eventId', 'wallet-event-' || i,
      'eventType', 'WalletObservation',
      'source', 'hyperliquid-wallet:0x1111111111111111111111111111111111111111',
      'observedAtMs', observed_at::text,
      'sourceSlot', observed_at::text,
      'sourceSequence', 'wallet-scan-' || i,
      'idempotencyKey', 'wallet-event-' || i,
      'rawPayloadHash', repeat('a', 64),
      'payload', jsonb_build_object(
        'wallet', '0x1111111111111111111111111111111111111111',
        'sourceObservedAtMs', observed_at::text,
        'accountValueUsdMicros', (10000000000 + i * 10000000)::text,
        'totalNotionalUsdMicros', '500000000',
        'apiLatencyMs', '25',
        'positions', CASE WHEN i IN (21, 43) THEN '[]'::jsonb ELSE jsonb_build_array(
          jsonb_build_object(
            'asset', 'BTC',
            'side', CASE WHEN i = 42 THEN 'short' ELSE 'long' END,
            'quantityAtoms', '10000000',
            'entryPriceUsdMicros', '50000000000',
            'markPriceUsdMicros', '50000000000',
            'leveragePpm', '5000000',
            'unrealizedPnlUsdMicros', '0'
          )
        ) END,
        'fills', jsonb_build_array(jsonb_build_object(
          'fillId', 'wallet-fill-' || i,
          'asset', 'BTC',
          'side', CASE
            WHEN i = 20 OR i = 43 THEN 'buy'
            ELSE 'sell'
          END,
          'direction', CASE
            WHEN i IN (20, 42) THEN 'open'
            ELSE 'close'
          END,
          'quantityAtoms', '10000000',
          'leaderPriceUsdMicros', CASE
            WHEN i IN (21, 43) THEN '50100000000'
            ELSE '50000000000'
          END,
          'copyBidPriceUsdMicros', CASE
            WHEN i IN (21, 43) THEN '50090000000'
            ELSE '49990000000'
          END,
          'copyAskPriceUsdMicros', CASE
            WHEN i IN (21, 43) THEN '50110000000'
            ELSE '50010000000'
          END,
          'closedPnlUsdMicros', CASE
            WHEN i < 20 THEN '10000000'
            WHEN i BETWEEN 22 AND 41 THEN '-30000000'
            ELSE '0'
          END,
          'feeUsdMicros', '1000000',
          'filledAtMs', (observed_at - 250)::text,
          'copyObservedAtMs', observed_at::text,
          'copyLatencyMs', '275',
          'copyBidDepthQualified', true,
          'copyAskDepthQualified', true
        ))
      )
    );
    result := record_wallet_observation(
      event, 7200000, 500000000, 200000
    );
  END LOOP;

  IF (SELECT count(*) FROM wallet_observations) <> 44
     OR (SELECT count(*) FROM wallet_fills) <> 44 THEN
    RAISE EXCEPTION 'wallet evidence was not indexed exactly once';
  END IF;

  scores := wallet_consistency_scores(started_at + 20 * 3600000 - 251, 20);
  IF jsonb_array_length(scores->'items') <> 1
     OR scores#>>'{items,0,closedDecisions}' <> '20'
     OR scores#>>'{items,0,qualified}' <> 'true'
     OR (scores#>>'{items,0,scorePpm}')::bigint <= 0 THEN
    RAISE EXCEPTION 'wallet score used future evidence or omitted costs: %', scores;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM wallet_paper_decisions
    WHERE fill_id = 'wallet-fill-20'
      AND mode = 'mirror'
      AND eligible
      AND score_as_of_ms = started_at + 20 * 3600000 - 251
  ) OR EXISTS (
    SELECT 1
    FROM wallet_paper_decisions
    WHERE fill_id = 'wallet-fill-20'
      AND mode = 'fade'
      AND eligible
  ) THEN
    RAISE EXCEPTION 'mirror/fade qualification did not use prior evidence';
  END IF;

  IF (SELECT count(*)
      FROM wallet_paper_positions
      WHERE mode IN ('flow', 'mirror')
        AND status = 'closed'
        AND realized_net_usd_micros > 0
        AND opened_fill_id = 'wallet-fill-20'
        AND closed_fill_id = 'wallet-fill-21') <> 2
     OR NOT EXISTS (
    SELECT 1
    FROM wallet_paper_positions
    WHERE mode = 'mirror'
      AND status = 'closed'
      AND realized_net_usd_micros > 0
      AND opened_fill_id = 'wallet-fill-20'
      AND closed_fill_id = 'wallet-fill-21'
  ) THEN
    RAISE EXCEPTION 'latency-priced wallet positions were not closed profitably';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM wallet_paper_positions
    WHERE mode = 'fade'
      AND status = 'closed'
      AND realized_net_usd_micros > 0
      AND opened_fill_id = 'wallet-fill-42'
      AND closed_fill_id = 'wallet-fill-43'
      AND entry_price_usd_micros = 50010000000
      AND exit_price_usd_micros = 50090000000
  ) THEN
    RAISE EXCEPTION 'fade did not invert the leader on the executable side';
  END IF;

  IF (SELECT signal_ppm FROM wallet_flow_signals
      WHERE asset = 'BTC'
        AND observed_at_ms = started_at + 20 * 3600000) <= 0 THEN
    RAISE EXCEPTION 'qualified wallet flow did not produce a long signal';
  END IF;

  INSERT INTO cross_asset_paper_decisions (
    id, scan_id, portfolio_run_id, source_event_id, venue, asset, rank,
    funding_24h_average_ppm, funding_ema_ppm, gate_distance_ppm,
    expected_funding_usd_micros, net_carry_usd_micros,
    eligible, action, reason_code
  ) VALUES (
    'wallet-phase1-decision', 'wallet-shadow-scan', 'wallet-phase1',
    'wallet-event-20', 'hyperliquid', 'BTC', 1, 20, 20, 10,
    1000000, 500000, true, 'open', 'test'
  );
  INSERT INTO reverse_carry_paper_decisions (
    id, scan_id, portfolio_run_id, source_event_id, venue, asset, rank,
    funding_24h_average_ppm, borrow_rate_ppm_per_hour, gate_distance_ppm,
    expected_funding_usd_micros, projected_borrow_usd_micros,
    net_carry_usd_micros, eligible, action, reason_code
  ) VALUES (
    'wallet-phase2-decision', 'wallet-shadow-scan', 'wallet-phase2',
    'wallet-event-20', 'hyperliquid', 'BTC', 1, -20, 5, 10,
    1000000, 200000, 500000, true, 'open', 'test'
  );
  IF NOT (SELECT wallet_signal_qualified AND wallet_signal_would_allow
          FROM cross_asset_paper_decisions
          WHERE id = 'wallet-phase1-decision')
     OR (SELECT wallet_signal_would_allow
         FROM reverse_carry_paper_decisions
         WHERE id = 'wallet-phase2-decision') THEN
    RAISE EXCEPTION 'wallet flow shadow filter did not follow spot direction';
  END IF;

  assessment := wallet_mode_assessment(started_at + 43 * 3600000);
  IF assessment#>>'{modes,mirror,verdict}' <> 'pending'
     OR assessment#>>'{modes,mirror,minimumDays}' <> '60'
     OR assessment#>>'{modes,mirror,minimumDecisions}' <> '20'
     OR assessment#>>'{benchmarks,holdingSol,ready}' IS DISTINCT FROM 'false'
     OR assessment#>>'{benchmarks,phase1,ready}' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION '60-day gate was not pinned: %', assessment;
  END IF;

  result := record_wallet_observation(
    event, 7200000, 500000000, 200000
  );
  IF result->>'inserted' <> 'false'
     OR (SELECT count(*) FROM wallet_fills) <> 44 THEN
    RAISE EXCEPTION 'duplicate wallet event changed evidence: %', result;
  END IF;
END;
$$;

ROLLBACK;
