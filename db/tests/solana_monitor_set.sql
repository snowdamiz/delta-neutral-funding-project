\set ON_ERROR_STOP on
BEGIN;

-- What the read model lists is what the observer re-quotes, so what leaves the
-- list is as load-bearing as what enters it. A candidate that stayed listed
-- forever was re-quoted every few seconds forever: 65 mints, 17,180 snapshots,
-- and enough Jupiter traffic to provoke the throttling that was then recorded
-- as those same mints being untradeable.
--
-- Fixtures are the broker test's, verbatim, so the payload shape stays honest.

CREATE FUNCTION pg_temp.mint_for(p_index integer) RETURNS text
LANGUAGE sql
AS $$
  SELECT '4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHi'
    || substr('JKLMNPQR', p_index, 1);
$$;

CREATE FUNCTION pg_temp.acquisition_event(p_index integer, p_at_ms bigint)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'schemaVersion', '1',
    'eventId', 'acq-' || p_index,
    'eventType', 'SolanaWalletAcquisition',
    'source', 'solana-wallet:11111111111111111111111111111111:swap-' || p_index,
    'observedAtMs', p_at_ms::text,
    'sourceSlot', '12',
    'sourceSequence', 'swap-' || p_index,
    'idempotencyKey', 'acq-' || p_index,
    'rawPayloadHash', repeat(substr('abcdef12', p_index, 1), 64),
    'payload', jsonb_build_object(
      'wallet', '11111111111111111111111111111111',
      'signature', 'swap-' || p_index,
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

-- A complete, organically-confirmed $100 candidate snapshot; p_overrides is
-- merged into the payload so each scenario states only what it changes.
CREATE FUNCTION pg_temp.snapshot_event(
  p_index integer, p_suffix text, p_at_ms bigint, p_overrides jsonb
) RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'schemaVersion', '1',
    'eventId', 'snap-' || p_index || p_suffix,
    'eventType', 'SolanaCandidateSnapshot',
    'source', 'solana-candidate:' || pg_temp.mint_for(p_index),
    'observedAtMs', p_at_ms::text,
    'sourceSlot', '12',
    'sourceSequence', 'swap-' || p_index,
    'idempotencyKey', 'snap-' || p_index || p_suffix,
    'rawPayloadHash', repeat(substr('12345678', p_index, 1), 64),
    'payload', jsonb_build_object(
      'acquisitionEventId', 'acq-' || p_index,
      'wallet', '11111111111111111111111111111111',
      'signature', 'swap-' || p_index,
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
      'buyOutputAtoms', '2500000',
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
      'positionSellImpactBps', '10000'
    ) || p_overrides
  );
$$;

-- A monitor pass quoting the open position's remaining quantity.

CREATE FUNCTION pg_temp.listed(p_acquisition text) RETURNS boolean
LANGUAGE sql
AS $$
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(solana_wallet_flow_read_model()->'openMints') o
    WHERE o->'acquisition'->>'eventId' = p_acquisition
  );
$$;

DO $$
DECLARE
  v_flat_ms bigint := (SELECT (config_json->>'flatTimeStopMs')::bigint
                       FROM solana_paper_broker_configs WHERE active);
BEGIN
  -- Watched moments ago, no organic flow yet: entering it is still the trade.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(1, 500000));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(
    1, 'a', 560000, jsonb_build_object('unlinkedBuyerCount', '0')));
  IF NOT pg_temp.listed('acq-1') THEN
    RAISE EXCEPTION 'a live watched candidate was dropped from the monitor set';
  END IF;

  -- Rejected on its newest snapshot. Selecting it on the older WATCH row is
  -- what kept every once-watched candidate in the set permanently.
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(
    1, 'b', 570000, jsonb_build_object('entryPriceImpactBps', '900')));
  IF pg_temp.listed('acq-1') THEN
    RAISE EXCEPTION 'a rejected candidate stayed listed on its stale WATCH row';
  END IF;

  -- Still only watched, but past the horizon the broker uses to give up on a
  -- position going nowhere. Re-quoting it buys nothing but rate limiting.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(2, 600000));
  PERFORM record_solana_candidate_snapshot(pg_temp.snapshot_event(
    2, 'a', 600000 + v_flat_ms + 1, jsonb_build_object('unlinkedBuyerCount', '0')));
  IF pg_temp.listed('acq-2') THEN
    RAISE EXCEPTION 'a candidate past the entry horizon is still being re-quoted';
  END IF;
END;
$$;

ROLLBACK;
