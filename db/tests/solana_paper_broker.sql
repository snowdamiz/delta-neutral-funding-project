BEGIN;

-- v2 exit-engine contract: recoup-then-ride, trailing stop, debounced flow
-- and liquidity exits, migration hold, multi-slot cap, and restart idempotency.

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
CREATE FUNCTION pg_temp.monitor_event(
  p_index integer, p_suffix text, p_at_ms bigint,
  p_atoms text, p_value text, p_overrides jsonb
) RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT pg_temp.snapshot_event(p_index, p_suffix, p_at_ms, jsonb_build_object(
    'paperPositionAtoms', p_atoms,
    'positionSellInputAtoms', p_atoms,
    'positionSellOutputUsdMicros', p_value,
    'positionSellImpactBps', CASE WHEN p_value = '0' THEN '10000' ELSE '200' END
  ) || p_overrides);
$$;

CREATE PROCEDURE pg_temp.open_position(p_index integer, p_at_ms bigint)
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(p_index, p_at_ms));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(p_index, 'a', p_at_ms + 1000, '{}'::jsonb));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(p_index, 'b', p_at_ms + 2000, '{}'::jsonb));
END;
$$;

DO $$
DECLARE
  v_plan jsonb;
  v_position solana_paper_positions%ROWTYPE;
  v_index integer;
BEGIN
  -- S1: entry gates, ladder recoup, trailing stop.
  PERFORM record_solana_wallet_flow_event(pg_temp.acquisition_event(1, 200000));
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(1, 'a', 201000, '{}'::jsonb));
  IF EXISTS (SELECT 1 FROM solana_paper_positions) THEN
    RAISE EXCEPTION 'broker entered on the decision quote without latency';
  END IF;
  UPDATE strategy_controls SET enabled = false
  WHERE strategy_id = 'solana_wallet_flow_quant';
  v_plan := plan_solana_paper_action('snap-1a', 201001);
  IF v_plan->>'status' <> 'REJECTED' OR v_plan->>'reason' <> 'STRATEGY_STOPPED' THEN
    RAISE EXCEPTION 'stopped Solana strategy planned an entry: %', v_plan;
  END IF;
  UPDATE strategy_controls SET enabled = true
  WHERE strategy_id = 'solana_wallet_flow_quant';
  v_plan := plan_solana_paper_action('snap-1a', 231001);
  IF v_plan->>'status' <> 'REJECTED' OR v_plan->>'reason' <> 'QUOTE_EXPIRED' THEN
    RAISE EXCEPTION 'expired entry quote was not rejected: %', v_plan;
  END IF;
  PERFORM record_solana_candidate_snapshot(
    pg_temp.snapshot_event(1, 'b', 202000, '{}'::jsonb));
  SELECT * INTO v_position FROM solana_paper_positions
  WHERE acquisition_event_id = 'acq-1';
  IF v_position.status <> 'open' OR v_position.quantity_atoms <> 2475000
     OR v_position.remaining_quantity_atoms <> 2475000
     OR v_position.entry_cost_usd_micros <> 100520000 THEN
    RAISE EXCEPTION 'entry fill did not include transfer fee, slippage, and fixed costs';
  END IF;

  -- Ladder: 2.5x the entry cost triggers a partial exit that recoups cost.
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(1, 'c', 203000, '2475000', '250000000', '{}'::jsonb));
  SELECT * INTO v_position FROM solana_paper_positions
  WHERE acquisition_event_id = 'acq-1';
  IF v_position.status <> 'open' OR NOT v_position.recouped
     OR v_position.remaining_quantity_atoms <> 1469600
     OR v_position.exit_leg_count <> 1 THEN
    RAISE EXCEPTION 'take-profit ladder did not recoup cost basis: %',
      to_jsonb(v_position);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM solana_paper_exit_legs
    WHERE position_id = v_position.id AND leg_no = 1
      AND reason = 'RECOUP' AND proceeds_usd_micros = 100519999
  ) THEN
    RAISE EXCEPTION 'recoup leg accounting is wrong';
  END IF;

  -- A pullback above the trailing threshold holds.
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(1, 'd', 204000, '1469600', '140000000', '{}'::jsonb));
  IF (SELECT status FROM solana_paper_positions WHERE acquisition_event_id = 'acq-1')
      <> 'open' THEN
    RAISE EXCEPTION 'pullback above the trailing threshold exited';
  END IF;
  -- A 30% drop from the high-water mark exits the remainder.
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(1, 'e', 205000, '1469600', '100000000', '{}'::jsonb));
  SELECT * INTO v_position FROM solana_paper_positions
  WHERE acquisition_event_id = 'acq-1';
  IF v_position.status <> 'closed' OR v_position.exit_reason <> 'TRAILING_STOP'
     OR v_position.realized_pnl_usd_micros <> 98979999
     OR v_position.exit_leg_count <> 2 THEN
    RAISE EXCEPTION 'trailing stop did not realize the ride: %', to_jsonb(v_position);
  END IF;

  -- S2: a creator sell exits immediately, no debounce.
  CALL pg_temp.open_position(2, 210000);
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(2, 'c', 213000, '2475000', '50000000',
      '{"creatorSold":true}'::jsonb));
  SELECT * INTO v_position FROM solana_paper_positions
  WHERE acquisition_event_id = 'acq-2';
  IF v_position.status <> 'closed' OR v_position.exit_reason <> 'CREATOR_SOLD'
     OR v_position.realized_pnl_usd_micros <> -51040000 THEN
    RAISE EXCEPTION 'creator sell did not exit immediately: %', to_jsonb(v_position);
  END IF;

  -- S3: organic-flow collapse requires the configured consecutive breaches.
  CALL pg_temp.open_position(3, 220000);
  FOR v_index IN 1..2 LOOP
    PERFORM record_solana_candidate_snapshot(
      pg_temp.monitor_event(3, 'c' || v_index, 222000 + v_index * 1000,
        '2475000', '100000000', '{"netQuoteInflowUsdMicros":"0"}'::jsonb));
    IF (SELECT status FROM solana_paper_positions WHERE acquisition_event_id = 'acq-3')
        <> 'open' THEN
      RAISE EXCEPTION 'flow breach % exited before the debounce', v_index;
    END IF;
    IF (SELECT flow_breach_count FROM solana_paper_positions
        WHERE acquisition_event_id = 'acq-3') <> v_index THEN
      RAISE EXCEPTION 'flow breach counter did not persist';
    END IF;
  END LOOP;
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(3, 'c3', 225000, '2475000', '100000000',
      '{"netQuoteInflowUsdMicros":"0"}'::jsonb));
  IF (SELECT exit_reason FROM solana_paper_positions WHERE acquisition_event_id = 'acq-3')
      <> 'ORGANIC_FLOW_COLLAPSE' THEN
    RAISE EXCEPTION 'third consecutive flow breach did not exit';
  END IF;

  -- S4: a vanished exit quote realizes zero only after the debounce.
  CALL pg_temp.open_position(4, 230000);
  FOR v_index IN 1..2 LOOP
    PERFORM record_solana_candidate_snapshot(
      pg_temp.monitor_event(4, 'c' || v_index, 232000 + v_index * 1000,
        '2475000', '0', '{}'::jsonb));
    IF (SELECT status FROM solana_paper_positions WHERE acquisition_event_id = 'acq-4')
        <> 'open' THEN
      RAISE EXCEPTION 'quote blip % realized a premature total loss', v_index;
    END IF;
  END LOOP;
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(4, 'c3', 235000, '2475000', '0', '{}'::jsonb));
  SELECT * INTO v_position FROM solana_paper_positions
  WHERE acquisition_event_id = 'acq-4';
  IF v_position.status <> 'closed' OR v_position.exit_reason <> 'EXIT_NO_LIQUIDITY'
     OR v_position.realized_pnl_usd_micros <> -100520000 THEN
    RAISE EXCEPTION 'no-liquidity exit did not realize the total loss: %',
      to_jsonb(v_position);
  END IF;

  -- S5: three concurrent slots fill; the fourth candidate is capped.
  CALL pg_temp.open_position(5, 240000);
  CALL pg_temp.open_position(6, 242000);
  CALL pg_temp.open_position(7, 244000);
  IF (SELECT count(*) FROM solana_paper_positions WHERE status = 'open') <> 3 THEN
    RAISE EXCEPTION 'multi-slot entries did not open';
  END IF;
  CALL pg_temp.open_position(8, 246000);
  IF EXISTS (SELECT 1 FROM solana_paper_positions WHERE acquisition_event_id = 'acq-8') THEN
    RAISE EXCEPTION 'position limit did not cap the fourth slot';
  END IF;
  IF (SELECT reason FROM solana_paper_actions WHERE snapshot_event_id = 'snap-8b')
      <> 'POSITION_LIMIT' THEN
    RAISE EXCEPTION 'position limit was not recorded';
  END IF;

  -- S6: migration is a recorded observation, not an exit; a stale-quantity
  -- quote holds instead of exiting.
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(5, 'c', 248000, '2475000', '110000000',
      '{"migrationStatus":"post_migration","routeLabels":["PumpSwap"]}'::jsonb));
  SELECT * INTO v_position FROM solana_paper_positions
  WHERE acquisition_event_id = 'acq-5';
  IF v_position.status <> 'open' OR NOT v_position.migration_crossed THEN
    RAISE EXCEPTION 'migration crossing was not held and recorded: %',
      to_jsonb(v_position);
  END IF;
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(6, 'c', 249000, '1', '110000000', '{}'::jsonb));
  IF (SELECT status FROM solana_paper_positions WHERE acquisition_event_id = 'acq-6')
      <> 'open' THEN
    RAISE EXCEPTION 'stale-quantity quote exited the position';
  END IF;
  IF (SELECT reason FROM solana_paper_actions WHERE snapshot_event_id = 'snap-6c')
      <> 'POSITION_QUOTE_STALE' THEN
    RAISE EXCEPTION 'stale-quantity quote was not held';
  END IF;

  -- S7: the flat time stop kills a position that never went anywhere.
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(7, 'c', 246000 + 1800001, '2475000', '101000000',
      '{}'::jsonb));
  SELECT * INTO v_position FROM solana_paper_positions
  WHERE acquisition_event_id = 'acq-7';
  IF v_position.status <> 'closed' OR v_position.exit_reason <> 'TIME_STOP_FLAT' THEN
    RAISE EXCEPTION 'flat time stop did not fire: %', to_jsonb(v_position);
  END IF;

  -- Restart idempotency: replaying a snapshot cannot duplicate an action.
  IF (SELECT count(*) FROM solana_paper_actions
      WHERE acquisition_event_id = 'acq-1') <> 5 THEN
    RAISE EXCEPTION 'paper actions were not complete';
  END IF;
  PERFORM record_solana_candidate_snapshot(
    pg_temp.monitor_event(1, 'e', 205000, '1469600', '100000000', '{}'::jsonb));
  IF (SELECT count(*) FROM solana_paper_actions
      WHERE acquisition_event_id = 'acq-1') <> 5 THEN
    RAISE EXCEPTION 'snapshot retry duplicated a paper action';
  END IF;

  -- Account totals across every scenario.
  IF solana_wallet_flow_read_model()->'paperAccount'->>'cashBalanceUsdMicros'
      <> (1000000000 + 98979999 - 51040000 - 1540000 - 100520000
          - 301560000 + 99970000)::text THEN
    RAISE EXCEPTION 'paper account cash drifted: %',
      solana_wallet_flow_read_model()->'paperAccount';
  END IF;
END;
$$;

ROLLBACK;
