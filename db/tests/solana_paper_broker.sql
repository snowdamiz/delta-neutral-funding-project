BEGIN;

DO $$
DECLARE
  v_snapshot jsonb;
  v_plan jsonb;
BEGIN
  PERFORM record_solana_wallet_flow_event('{
    "schemaVersion":1,
    "eventId":"broker-acquisition",
    "eventType":"SolanaWalletAcquisition",
    "source":"solana-wallet:11111111111111111111111111111111:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
    "observedAtMs":"200000",
    "sourceSlot":"12",
    "sourceSequence":"broker-swap",
    "idempotencyKey":"broker-acquisition",
    "rawPayloadHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "payload":{
      "wallet":"11111111111111111111111111111111",
      "signature":"broker-swap",
      "confirmedAtMs":"100000",
      "inputMint":"So11111111111111111111111111111111111111112",
      "inputAmountAtoms":"100000",
      "outputMint":"4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
      "outputAmountAtoms":"250000",
      "outputDecimals":"6",
      "routePrograms":["JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"]
    }
  }'::jsonb);

  v_snapshot := '{
    "schemaVersion":1,
    "eventId":"broker-snapshot-1",
    "eventType":"SolanaCandidateSnapshot",
    "source":"solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
    "observedAtMs":"201000",
    "sourceSlot":"12",
    "sourceSequence":"broker-swap",
    "idempotencyKey":"broker-snapshot-1",
    "rawPayloadHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "payload":{
      "acquisitionEventId":"broker-acquisition",
      "wallet":"11111111111111111111111111111111",
      "signature":"broker-swap",
      "mint":"4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
      "snapshotStatus":"complete",
      "rejectReason":"",
      "sourceObservedAtMs":"201000",
      "tokenProgram":"spl-token",
      "tokenExtensions":[],
      "mintAuthorityDisabled":true,
      "freezeAuthorityDisabled":true,
      "transferFeeBps":"0",
      "transferFeeMaximumAtoms":"0",
      "transferFeeBuyAtoms":"0",
      "transferFeeSellAtoms":"0",
      "supplyAtoms":"1000000",
      "decimals":"6",
      "marketCapUsdMicros":"40000000",
      "topTenHolderConcentrationBps":"4000",
      "creator":"2Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
      "creatorInventoryAtoms":"300000",
      "clusterInventoryAtoms":"100000",
      "marketAgeSlots":"12",
      "migrationStatus":"pre_migration",
      "routeLabels":["Pump.fun"],
      "buyInputUsdMicros":"10000000",
      "buyOutputAtoms":"250000",
      "sellOutputUsdMicros":"9500000",
      "entryPriceImpactBps":"100",
      "roundTripLossBps":"500",
      "exitDepthUsdMicros":"100000000",
      "exitDepthImpactBps":"900",
      "quoteContextSlot":"13",
      "flowCoverageComplete":true,
      "unlinkedBuyerCount":"10",
      "unlinkedBuyerCount1m":"2",
      "unlinkedBuyerCount5m":"10",
      "unlinkedBuyerCount1h":"12",
      "netQuoteInflowUsdMicros":"20000000",
      "netQuoteInflowUsdMicros1m":"4000000",
      "netQuoteInflowUsdMicros1h":"24000000",
      "volumeUsdMicros1m":"5000000",
      "volumeUsdMicros5m":"25000000",
      "volumeUsdMicros1h":"30000000",
      "creatorSold":false,
      "clusterSold":false,
      "sanctionsHit":false,
      "paperPositionAtoms":"0",
      "positionTransferFeeAtoms":"0",
      "positionSellInputAtoms":"0",
      "positionSellOutputUsdMicros":"0",
      "positionSellImpactBps":"10000"
    }
  }'::jsonb;

  PERFORM record_solana_candidate_snapshot(v_snapshot);
  IF EXISTS (SELECT 1 FROM solana_paper_positions) THEN
    RAISE EXCEPTION 'broker entered on the decision quote without latency';
  END IF;
  UPDATE strategy_controls
  SET enabled = false
  WHERE strategy_id = 'solana_wallet_flow_quant';
  v_plan := plan_solana_paper_action('broker-snapshot-1', 201001);
  IF v_plan->>'status' <> 'REJECTED' OR v_plan->>'reason' <> 'STRATEGY_STOPPED' THEN
    RAISE EXCEPTION 'stopped Solana strategy planned an entry: %', v_plan;
  END IF;
  UPDATE strategy_controls
  SET enabled = true
  WHERE strategy_id = 'solana_wallet_flow_quant';
  v_plan := plan_solana_paper_action('broker-snapshot-1', 231001);
  IF v_plan->>'status' <> 'REJECTED' OR v_plan->>'reason' <> 'QUOTE_EXPIRED' THEN
    RAISE EXCEPTION 'expired entry quote was not rejected: %', v_plan;
  END IF;

  v_snapshot := jsonb_set(v_snapshot, '{eventId}', '"broker-snapshot-2"');
  v_snapshot := jsonb_set(v_snapshot, '{observedAtMs}', '"202000"');
  v_snapshot := jsonb_set(v_snapshot, '{idempotencyKey}', '"broker-snapshot-2"');
  v_snapshot := jsonb_set(v_snapshot, '{rawPayloadHash}', '"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"');
  v_snapshot := jsonb_set(v_snapshot, '{payload,sourceObservedAtMs}', '"202000"');
  PERFORM record_solana_candidate_snapshot(v_snapshot);
  IF (SELECT status FROM solana_paper_positions
      WHERE acquisition_event_id = 'broker-acquisition') <> 'open' THEN
    RAISE EXCEPTION 'latency-qualified paper entry was not filled';
  END IF;
  IF (SELECT quantity_atoms FROM solana_paper_positions
      WHERE acquisition_event_id = 'broker-acquisition') <> 247500 THEN
    RAISE EXCEPTION 'entry did not include transfer fee and paper slippage';
  END IF;

  v_snapshot := jsonb_set(v_snapshot, '{eventId}', '"broker-snapshot-3"');
  v_snapshot := jsonb_set(v_snapshot, '{observedAtMs}', '"203000"');
  v_snapshot := jsonb_set(v_snapshot, '{idempotencyKey}', '"broker-snapshot-3"');
  v_snapshot := jsonb_set(v_snapshot, '{rawPayloadHash}', '"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"');
  v_snapshot := jsonb_set(v_snapshot, '{payload,sourceObservedAtMs}', '"203000"');
  v_snapshot := jsonb_set(v_snapshot, '{payload,creatorSold}', 'true');
  v_snapshot := jsonb_set(v_snapshot, '{payload,paperPositionAtoms}', '"247500"');
  v_snapshot := jsonb_set(v_snapshot, '{payload,positionSellInputAtoms}', '"247500"');
  PERFORM record_solana_candidate_snapshot(v_snapshot);
  IF (SELECT status FROM solana_paper_positions
      WHERE acquisition_event_id = 'broker-acquisition') <> 'closed' THEN
    RAISE EXCEPTION 'creator sell did not close the paper position';
  END IF;
  IF (SELECT exit_reason FROM solana_paper_positions
      WHERE acquisition_event_id = 'broker-acquisition') <> 'CREATOR_SOLD' THEN
    RAISE EXCEPTION 'paper exit reason was not preserved';
  END IF;
  IF (SELECT realized_pnl_usd_micros FROM solana_paper_positions
      WHERE acquisition_event_id = 'broker-acquisition') <> -10520000 THEN
    RAISE EXCEPTION 'zero-liquidity loss did not include entry costs';
  END IF;
  IF solana_wallet_flow_read_model()->'paperAccount'->>'cashBalanceUsdMicros'
      <> '989480000' THEN
    RAISE EXCEPTION 'paper account read model did not preserve realized cash';
  END IF;
  IF (SELECT count(*) FROM solana_paper_actions
      WHERE acquisition_event_id = 'broker-acquisition') <> 3 THEN
    RAISE EXCEPTION 'paper actions were not restart-idempotent';
  END IF;
  PERFORM record_solana_candidate_snapshot(v_snapshot);
  IF (SELECT count(*) FROM solana_paper_actions
      WHERE acquisition_event_id = 'broker-acquisition') <> 3 THEN
    RAISE EXCEPTION 'snapshot retry duplicated a paper action';
  END IF;
END;
$$;

ROLLBACK;
