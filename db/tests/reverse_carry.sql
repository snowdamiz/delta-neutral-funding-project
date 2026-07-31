BEGIN;

DO $$
DECLARE
  hour_ms bigint := 3600000;
  started_at bigint := 1784419200000;
  event jsonb;
  result jsonb;
  i integer;
BEGIN
  INSERT INTO build_manifests (
    id, code_commit, mesh_commit, schema_version, config_hash
  ) VALUES (
    'reverse-test-build', 'code', 'mesh', 34, repeat('2', 64)
  );
  INSERT INTO strategy_runs (
    id, execution_mode, config_hash, build_manifest_id,
    prng_seed, prng_version
  ) VALUES (
    'reverse-test-run', 'paper', repeat('2', 64),
    'reverse-test-build', 1, 'test'
  );
  INSERT INTO comparison_groups (
    id, strategy_run_id, mode, target_notional_usd_micros,
    entry_policy_version, exit_policy_version
  ) VALUES
    ('reverse-test-independent', 'reverse-test-run', 'independent',
      500000000, 'reverse-v1', 'reverse-v1'),
    ('reverse-test-controlled', 'reverse-test-run', 'synchronized',
      500000000, 'reverse-v1', 'reverse-v1');
  INSERT INTO portfolio_runs (
    id, strategy_run_id, comparison_group_id, variant,
    execution_mode, initial_capital_usd_micros
  ) VALUES
    ('reverse-test-independent', 'reverse-test-run',
      'reverse-test-independent', 'negative_funding_reverse', 'paper', 1000000000),
    ('reverse-test-controlled', 'reverse-test-run',
      'reverse-test-controlled', 'negative_funding_reverse', 'paper', 1000000000),
    ('reverse-test-sol-independent', 'reverse-test-run',
      'reverse-test-independent', 'sol_control', 'paper', 1000000000),
    ('reverse-test-sol-controlled', 'reverse-test-run',
      'reverse-test-controlled', 'sol_control', 'paper', 1000000000);
  UPDATE portfolio_runs
  SET state = 'hedged'
  WHERE id = 'reverse-test-sol-controlled';

  FOR i IN 0..170 LOOP
    event := jsonb_build_object(
      'schemaVersion', 1,
      'eventId', 'reverse-sol-' || i,
      'eventType', 'FundingObservation',
      'source', 'hyperliquid-funding:SOL',
      'observedAtMs', (started_at + i * hour_ms)::text,
      'sourceSlot', (started_at + i * hour_ms)::text,
      'sourceSequence', 'scan-' || i,
      'idempotencyKey', 'reverse-sol-' || i,
      'rawPayloadHash', repeat('b', 64),
      'payload', jsonb_build_object(
        'scanId', 'reverse-scan-' || i,
        'scanIndex', '0',
        'scanSize', '1',
        'venue', 'hyperliquid',
        'asset', 'SOL',
        'instrument', 'SOL-PERP',
        'sourceObservedAtMs', (started_at + i * hour_ms)::text,
        'sourceStatus', 'valid',
        'fundingRatePpmPerHour', CASE WHEN i = 170 THEN '-4' ELSE '-30' END,
        'realizedFundingRatePpm', CASE WHEN i = 170 THEN '-4' ELSE '-30' END,
        'realizedFundingAtMs', (started_at + i * hour_ms)::text,
        'markPriceUsdMicros', '100000000',
        'openInterestUsdMicros', '1000000000000',
        'spotBidPriceUsdMicros', '99900000',
        'spotAskPriceUsdMicros', '100100000',
        'perpBidPriceUsdMicros', '99950000',
        'perpAskPriceUsdMicros', '100050000',
        'spotExitDepthAtoms', '20000000000',
        'perpExitDepthAtoms', '20000000000',
        'depthQualified', true,
        'borrowVenue', 'kamino',
        'borrowMarket', '7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF',
        'borrowReserve', 'd4A2prbA2whesmvHaL88BH6Ewn5N4bTSU2Ze8P6Bc4Q',
        'borrowMint', 'So11111111111111111111111111111111111111112',
        'borrowSourceObservedAtMs', (started_at + i * hour_ms)::text,
        'borrowSourceStatus', 'valid',
        'borrowRatePpmPerHour', '5',
        'borrowAvailableUsdMicros', '2000000000',
        'borrowUtilizationPpm', '500000'
      )
    );
    result := record_funding_observation(event, 7200000);
    PERFORM record_borrow_snapshot(event, 7200000);

    IF result->>'scanComplete' <> 'true' THEN
      RAISE EXCEPTION 'single-member reverse scan was incomplete: %', result;
    END IF;
    IF i = 168 THEN
      result := run_reverse_carry_paper_scan(
        'reverse-scan-168', started_at + 168 * hour_ms,
        7200000, 7200000, 500000000, 200000, 50000,
        72, 48, 10, 950000
      );
      IF result->>'opened' <> '2' THEN
        RAISE EXCEPTION 'eligible reverse positions did not open: %', result;
      END IF;
    ELSIF i = 169 THEN
      result := run_reverse_carry_paper_scan(
        'reverse-scan-169', started_at + 169 * hour_ms,
        7200000, 7200000, 500000000, 200000, 50000,
        72, 48, 10, 950000
      );
      IF result->>'held' <> '2'
         OR (SELECT COALESCE(sum(usd_value_atoms::numeric), 0)
             FROM funding_payments
             WHERE portfolio_run_id LIKE 'reverse-test-%'
               AND realization_status = 'realized') <> 30030
         OR (SELECT COALESCE(sum(le.usd_value_atoms::numeric), 0)
             FROM ledger_entries le
             JOIN ledger_batches lb ON lb.id = le.ledger_batch_id
             WHERE lb.portfolio_run_id LIKE 'reverse-test-%'
               AND le.account_debit = 'borrow_interest_expense') <> 5004 THEN
        RAISE EXCEPTION 'reverse carry accrual was not net of live borrow: %', result;
      END IF;
    ELSIF i = 170 THEN
      result := run_reverse_carry_paper_scan(
        'reverse-scan-170', started_at + 170 * hour_ms,
        7200000, 7200000, 500000000, 200000, 50000,
        72, 48, 10, 950000
      );
      IF result->>'closed' <> '2'
         OR EXISTS (
           SELECT 1 FROM reverse_carry_paper_positions
           WHERE status IN ('open', 'exit_blocked')
         )
         OR (SELECT count(*) FROM reverse_carry_paper_decisions
             WHERE reason_code = 'borrow_rate_spike') <> 2 THEN
        RAISE EXCEPTION 'borrow spike was averaged away instead of exited: %', result;
      END IF;
    END IF;
  END LOOP;

  result := reverse_carry_leaderboard(
    started_at + 170 * hour_ms,
    7200000, 7200000, 500000000, 200000, 50000,
    72, 48, 10, 950000
  );
  IF result->>'minimumNegativeFundingPpm' <> '10'
     OR result->>'maximumBorrowUtilizationPpm' <> '950000'
     OR result#>>'{items,0,borrowRatePpmPerHour}' <> '5'
     OR result#>>'{items,0,eligible}' <> 'true' THEN
    RAISE EXCEPTION 'unexpected reverse carry leaderboard: %', result;
  END IF;
END;
$$;

ROLLBACK;
