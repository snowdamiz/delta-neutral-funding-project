BEGIN;

-- Live-mode contract: arming is precondition-guarded and approval-gated,
-- FILLED paper actions mirror into capped live intents only while armed, the
-- executor claim/report lifecycle is idempotent, and stopping the strategy
-- disarms live mode.

CREATE FUNCTION pg_temp.mint_for(p_index integer) RETURNS text
LANGUAGE sql
AS $$
  SELECT '4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHi'
    || substr('STU', p_index, 1);
$$;

CREATE FUNCTION pg_temp.acquisition_event(p_index integer, p_at_ms bigint)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'schemaVersion', '1',
    'eventId', 'lv-acq-' || p_index,
    'eventType', 'SolanaWalletAcquisition',
    'source', 'solana-wallet:11111111111111111111111111111111:lv-swap-' || p_index,
    'observedAtMs', p_at_ms::text,
    'sourceSlot', '12',
    'sourceSequence', 'lv-swap-' || p_index,
    'idempotencyKey', 'lv-acq-' || p_index,
    'rawPayloadHash', repeat(substr('abc', p_index, 1), 64),
    'payload', jsonb_build_object(
      'wallet', '11111111111111111111111111111111',
      'signature', 'lv-swap-' || p_index,
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
  p_index integer, p_suffix text, p_at_ms bigint, p_overrides jsonb
) RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'schemaVersion', '1',
    'eventId', 'lv-snap-' || p_index || p_suffix,
    'eventType', 'SolanaCandidateSnapshot',
    'source', 'solana-candidate:' || pg_temp.mint_for(p_index),
    'observedAtMs', p_at_ms::text,
    'sourceSlot', '12',
    'sourceSequence', 'lv-swap-' || p_index,
    'idempotencyKey', 'lv-snap-' || p_index || p_suffix,
    'rawPayloadHash', repeat(substr('123', p_index, 1), 64),
    'payload', jsonb_build_object(
      'acquisitionEventId', 'lv-acq-' || p_index,
      'wallet', '11111111111111111111111111111111',
      'signature', 'lv-swap-' || p_index,
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

CREATE FUNCTION pg_temp.monitor_event(
  p_index integer, p_suffix text, p_at_ms bigint,
  p_atoms text, p_value text
) RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT pg_temp.snapshot_event(p_index, p_suffix, p_at_ms, jsonb_build_object(
    'paperPositionAtoms', p_atoms,
    'positionSellInputAtoms', p_atoms,
    'positionSellOutputUsdMicros', p_value,
    'positionSellImpactBps', '200'
  ));
$$;

DO $$
DECLARE
  v_result jsonb;
  v_claimed jsonb;
  v_intent solana_live_intents%ROWTYPE;
BEGIN
  UPDATE strategy_controls SET enabled = true
  WHERE strategy_id = 'solana_wallet_flow_quant';

  -- Arming fails closed without the approval string or a configured cohort.
  BEGIN
    PERFORM apply_strategy_execution_mode('solana_wallet_flow_quant', 'live',
      'yes', 'lv-arm-noapproval', 'arm live', repeat('a', 64));
    RAISE EXCEPTION 'live armed without the approval string';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'live arming requires the explicit approval string' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    PERFORM apply_strategy_execution_mode('solana_wallet_flow_quant', 'live',
      'ARM LIVE TRADING', 'lv-arm-nowallets', 'arm live', repeat('a', 64));
    RAISE EXCEPTION 'live armed without a configured cohort';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'live arming requires at least one configured Solana wallet' THEN
      RAISE;
    END IF;
  END;
  PERFORM apply_solana_wallet_config('lv-cohort', 'live test cohort',
    repeat('b', 64), '["11111111111111111111111111111111"]'::jsonb);
  v_result := apply_strategy_execution_mode('solana_wallet_flow_quant', 'live',
    'ARM LIVE TRADING', 'lv-arm', 'arm live', repeat('c', 64));
  IF v_result->>'mode' <> 'live' THEN
    RAISE EXCEPTION 'live arming failed: %', v_result;
  END IF;
  IF strategy_execution_mode('solana_wallet_flow_quant') <> 'live' THEN
    RAISE EXCEPTION 'execution mode did not persist';
  END IF;

  -- A paper entry mirrors into a live ENTRY intent.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(1, 200000));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(1, 'a', 201000, '{}'::jsonb));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(1, 'b', 202000, '{}'::jsonb));
  SELECT * INTO STRICT v_intent FROM solana_live_intents
  WHERE acquisition_event_id = 'lv-acq-1' AND kind = 'ENTRY';
  IF v_intent.status <> 'pending' OR v_intent.input_usd_micros <> 100000000 THEN
    RAISE EXCEPTION 'live entry intent is wrong: %', to_jsonb(v_intent);
  END IF;

  -- Claim delivers the intent once; the fill report opens a live position.
  v_claimed := claim_solana_live_intents('executor-test', 202500, 10);
  IF jsonb_array_length(v_claimed) <> 1
     OR v_claimed->0->>'kind' <> 'ENTRY'
     OR v_claimed->0->>'inputUsdMicros' <> '100000000' THEN
    RAISE EXCEPTION 'claim did not deliver the entry intent: %', v_claimed;
  END IF;
  IF jsonb_array_length(claim_solana_live_intents('executor-test', 202600, 10))
      <> 0 THEN
    RAISE EXCEPTION 'claim was not exclusive';
  END IF;
  v_result := record_solana_live_report(jsonb_build_object(
    'intentId', v_claimed->0->>'intentId',
    'status', 'filled',
    'signature', 'LiveFi11Signature111111111111111111111111112',
    'inputAmount', '100000000',
    'outputAmount', '2400000',
    'feeLamports', '5000',
    'slot', '14',
    'resolvedAtMs', '203000'
  ));
  IF (v_result->>'recorded')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'fill report was not recorded: %', v_result;
  END IF;
  IF (SELECT remaining_atoms FROM solana_live_positions
      WHERE acquisition_event_id = 'lv-acq-1') <> 2400000 THEN
    RAISE EXCEPTION 'live position did not open from the fill';
  END IF;
  -- Replaying the same signature is idempotent.
  v_result := record_solana_live_report(jsonb_build_object(
    'intentId', v_claimed->0->>'intentId',
    'status', 'filled',
    'signature', 'LiveFi11Signature111111111111111111111111112',
    'inputAmount', '100000000',
    'outputAmount', '2400000',
    'feeLamports', '5000',
    'slot', '14',
    'resolvedAtMs', '203000'
  ));
  IF (v_result->>'recorded')::boolean THEN
    RAISE EXCEPTION 'duplicate fill signature was recorded twice';
  END IF;

  -- The paper recoup mirrors a partial live exit at the same fraction.
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(1, 'c', 204000, '2475000', '250000000'));
  SELECT * INTO STRICT v_intent FROM solana_live_intents
  WHERE acquisition_event_id = 'lv-acq-1' AND kind = 'EXIT';
  IF v_intent.fraction_bps <> 4062 THEN
    RAISE EXCEPTION 'partial exit fraction is wrong: %', to_jsonb(v_intent);
  END IF;
  v_claimed := claim_solana_live_intents('executor-test', 204500, 10);
  v_result := record_solana_live_report(jsonb_build_object(
    'intentId', v_claimed->0->>'intentId',
    'status', 'filled',
    'signature', 'LiveFi11Signature211111111111111111111111112',
    'inputAmount', '974880',
    'outputAmount', '101000000',
    'feeLamports', '5000',
    'slot', '15',
    'resolvedAtMs', '205000'
  ));
  IF (SELECT (status, remaining_atoms) = ('open', 1425120::numeric)
      FROM solana_live_positions
      WHERE acquisition_event_id = 'lv-acq-1') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'partial live exit accounting is wrong';
  END IF;

  -- The paper trailing exit mirrors a full live exit and closes the position.
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(1, 'd', 206000, '1469600', '100000000'));
  SELECT * INTO STRICT v_intent FROM solana_live_intents
  WHERE snapshot_event_id = 'lv-snap-1d';
  IF v_intent.kind <> 'EXIT' OR v_intent.fraction_bps <> 10000 THEN
    RAISE EXCEPTION 'full exit intent is wrong: %', to_jsonb(v_intent);
  END IF;
  v_claimed := claim_solana_live_intents('executor-test', 206500, 10);
  PERFORM record_solana_live_report(jsonb_build_object(
    'intentId', v_claimed->0->>'intentId',
    'status', 'filled',
    'signature', 'LiveFi11Signature311111111111111111111111112',
    'inputAmount', '1425120',
    'outputAmount', '97000000',
    'feeLamports', '5000',
    'slot', '16',
    'resolvedAtMs', '207000'
  ));
  IF (SELECT (status, remaining_atoms) = ('closed', 0::numeric)
      FROM solana_live_positions
      WHERE acquisition_event_id = 'lv-acq-1') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'full live exit did not close the position';
  END IF;

  -- An unclaimed intent expires after its TTL.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(2, 210000));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(2, 'a', 211000, '{}'::jsonb));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(2, 'b', 212000, '{}'::jsonb));
  IF jsonb_array_length(claim_solana_live_intents('executor-test', 500000, 10))
      <> 0 THEN
    RAISE EXCEPTION 'expired intent was claimable';
  END IF;
  IF (SELECT status FROM solana_live_intents
      WHERE acquisition_event_id = 'lv-acq-2') <> 'expired' THEN
    RAISE EXCEPTION 'stale intent did not expire';
  END IF;

  -- A failure report resolves an intent without touching positions.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(3, 220000));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(3, 'a', 221000, '{}'::jsonb));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(3, 'b', 222000, '{}'::jsonb));
  v_claimed := claim_solana_live_intents('executor-test', 222500, 10);
  v_result := record_solana_live_report(jsonb_build_object(
    'intentId', v_claimed->0->>'intentId',
    'status', 'failed',
    'failureReason', 'slippage exceeded the configured bound',
    'resolvedAtMs', '223000'
  ));
  IF (v_result->>'status') <> 'failed'
     OR EXISTS (SELECT 1 FROM solana_live_positions
                WHERE acquisition_event_id = 'lv-acq-3') THEN
    RAISE EXCEPTION 'failure report handling is wrong: %', v_result;
  END IF;

  -- Stopping the strategy disarms live mode; no further intents mirror.
  PERFORM apply_strategy_control('solana_wallet_flow_quant', false,
    'lv-stop', 'stop for disarm test', repeat('d', 64));
  IF strategy_execution_mode('solana_wallet_flow_quant') <> 'paper' THEN
    RAISE EXCEPTION 'strategy stop did not disarm live mode';
  END IF;
  UPDATE strategy_controls SET enabled = true
  WHERE strategy_id = 'solana_wallet_flow_quant';
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(3, 'c', 224000, '2475000', '30000000'));
  IF EXISTS (
    SELECT 1 FROM solana_live_intents WHERE snapshot_event_id = 'lv-snap-3c'
  ) THEN
    RAISE EXCEPTION 'disarmed strategy still mirrored a live intent';
  END IF;
END;
$$;

ROLLBACK;
