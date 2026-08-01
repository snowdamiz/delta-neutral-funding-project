BEGIN;

-- Discovery contract: early buyers persist with earliest-seen upsert, runner
-- mints nominate their early unlinked buyers, repeat early buyers rank first,
-- flat mints nominate nobody, and followed wallets are marked.

CREATE FUNCTION pg_temp.mint_for(p_index integer) RETURNS text
LANGUAGE sql
AS $$
  SELECT '4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHi'
    || substr('JKL', p_index, 1);
$$;

CREATE FUNCTION pg_temp.acquisition_event(p_index integer, p_at_ms bigint)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'schemaVersion', '1',
    'eventId', 'disc-acq-' || p_index,
    'eventType', 'SolanaWalletAcquisition',
    'source', 'solana-wallet:11111111111111111111111111111111:disc-swap-' || p_index,
    'observedAtMs', p_at_ms::text,
    'sourceSlot', '12',
    'sourceSequence', 'disc-swap-' || p_index,
    'idempotencyKey', 'disc-acq-' || p_index,
    'rawPayloadHash', repeat(substr('abc', p_index, 1), 64),
    'payload', jsonb_build_object(
      'wallet', '11111111111111111111111111111111',
      'signature', 'disc-swap-' || p_index,
      'confirmedAtMs', (p_at_ms - 1000)::text,
      'inputMint', 'So11111111111111111111111111111111111111112',
      'inputAmountAtoms', '100000',
      'outputMint', pg_temp.mint_for(p_index),
      'outputAmountAtoms', '2500000',
      'outputDecimals', '6',
      'routePrograms', jsonb_build_array('JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4')
    )
  );
$$;

CREATE FUNCTION pg_temp.snapshot_event(
  p_index integer, p_suffix text, p_at_ms bigint,
  p_buy_output text, p_buyers jsonb
) RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'schemaVersion', '1',
    'eventId', 'disc-snap-' || p_index || p_suffix,
    'eventType', 'SolanaCandidateSnapshot',
    'source', 'solana-candidate:' || pg_temp.mint_for(p_index),
    'observedAtMs', p_at_ms::text,
    'sourceSlot', '12',
    'sourceSequence', 'disc-swap-' || p_index,
    'idempotencyKey', 'disc-snap-' || p_index || p_suffix,
    'rawPayloadHash', repeat(substr('123', p_index, 1), 64),
    'payload', jsonb_build_object(
      'acquisitionEventId', 'disc-acq-' || p_index,
      'wallet', '11111111111111111111111111111111',
      'signature', 'disc-swap-' || p_index,
      'mint', pg_temp.mint_for(p_index),
      'snapshotStatus', 'complete',
      'rejectReason', '',
      'sourceObservedAtMs', p_at_ms::text,
      'tokenProgram', 'spl-token',
      'tokenExtensions', '[]'::jsonb,
      'mintAuthorityDisabled', true,
      'freezeAuthorityDisabled', true,
      'transferFeeBps', '0',
      'transferFeeMaximumAtoms', '0',
      'transferFeeBuyAtoms', '0',
      'transferFeeSellAtoms', '0',
      'supplyAtoms', '1000000000',
      'decimals', '6',
      'marketCapUsdMicros', '40000000000',
      'topTenHolderConcentrationBps', '4000',
      'creator', '2Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ',
      'creatorInventoryAtoms', '300000',
      'clusterInventoryAtoms', '100000',
      'marketAgeSlots', '12',
      'migrationStatus', 'pre_migration',
      'routeLabels', jsonb_build_array('Pump.fun'),
      'buyInputUsdMicros', '100000000',
      'buyOutputAtoms', p_buy_output,
      'sellOutputUsdMicros', '95000000',
      'entryPriceImpactBps', '100',
      'roundTripLossBps', '500',
      'exitDepthUsdMicros', '1000000000',
      'exitDepthImpactBps', '900',
      'quoteContextSlot', '13'
    ) || jsonb_build_object(
      'flowCoverageComplete', true,
      'unlinkedBuyerCount', '10',
      'unlinkedBuyerCount1m', '2',
      'unlinkedBuyerCount5m', '10',
      'unlinkedBuyerCount1h', '12',
      'netQuoteInflowUsdMicros', '20000000',
      'netQuoteInflowUsdMicros1m', '4000000',
      'netQuoteInflowUsdMicros1h', '24000000',
      'volumeUsdMicros1m', '5000000',
      'volumeUsdMicros5m', '25000000',
      'volumeUsdMicros1h', '30000000',
      'creatorSold', false,
      'clusterSold', false,
      'sanctionsHit', false,
      'paperPositionAtoms', '0',
      'positionTransferFeeAtoms', '0',
      'positionSellInputAtoms', '0',
      'positionSellOutputUsdMicros', '0',
      'positionSellImpactBps', '10000',
      'flowBuyers', p_buyers
    )
  );
$$;

DO $$
DECLARE
  v_nominations jsonb;
  v_top jsonb;
BEGIN
  -- Stop the broker from trading these fixtures; discovery is capture-only.
  UPDATE strategy_controls SET enabled = false
  WHERE strategy_id = 'solana_wallet_flow_quant';

  -- Mint 1 runs 4x; wallets W-one and W-two are early, W-one seen again
  -- earlier in a later scan (upsert keeps the earliest sighting).
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(1, 100000));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(1, 'a', 101000,
    '2500000', '[
      {"owner":"D1scWa11etAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1","firstSeenMs":"100200","boughtAtoms":"5000"},
      {"owner":"D1scWa11etBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2","firstSeenMs":"100400","boughtAtoms":"3000"}
    ]'::jsonb));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(1, 'b', 102000,
    '625000', '[
      {"owner":"D1scWa11etAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1","firstSeenMs":"100100","boughtAtoms":"6000"}
    ]'::jsonb));

  -- Mint 2 runs 3x; W-one is early again.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(2, 110000));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(2, 'a', 111000,
    '3000000', '[
      {"owner":"D1scWa11etAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1","firstSeenMs":"110100","boughtAtoms":"4000"}
    ]'::jsonb));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(2, 'b', 112000,
    '1000000', '[]'::jsonb));

  -- Mint 3 stays flat; its buyers are never nominated.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(3, 120000));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(3, 'a', 121000,
    '2500000', '[
      {"owner":"D1scWa11etFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF3","firstSeenMs":"120100","boughtAtoms":"9000"}
    ]'::jsonb));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(3, 'b', 122000,
    '2400000', '[]'::jsonb));

  IF (SELECT first_seen_ms FROM solana_candidate_buyers
      WHERE owner = 'D1scWa11etAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1'
        AND mint = pg_temp.mint_for(1)) <> 100100 THEN
    RAISE EXCEPTION 'buyer upsert did not keep the earliest sighting';
  END IF;

  v_nominations := solana_wallet_discovery(30000, 10, 50);
  IF jsonb_array_length(v_nominations) <> 2 THEN
    RAISE EXCEPTION 'discovery nominated the wrong wallets: %', v_nominations;
  END IF;
  v_top := v_nominations->0;
  IF v_top->>'wallet' <> 'D1scWa11etAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1'
     OR (v_top->>'runnerCount')::integer <> 2
     OR (v_top->>'alreadyFollowed')::boolean THEN
    RAISE EXCEPTION 'repeat early buyer did not rank first: %', v_top;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_nominations) item
    WHERE item->>'wallet' = 'D1scWa11etFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF3'
  ) THEN
    RAISE EXCEPTION 'flat mint produced a nomination';
  END IF;

  -- A promoted wallet is marked as already followed.
  PERFORM apply_solana_wallet_config(
    'discovery-test-promote', 'promote discovered wallet',
    repeat('a', 64),
    '["D1scWa11etBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2"]'::jsonb
  );
  v_nominations := solana_wallet_discovery(30000, 10, 50);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_nominations) item
    WHERE item->>'wallet' = 'D1scWa11etBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2'
      AND (item->>'alreadyFollowed')::boolean
  ) THEN
    RAISE EXCEPTION 'promoted wallet was not marked followed: %', v_nominations;
  END IF;
END;
$$;

ROLLBACK;
