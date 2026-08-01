BEGIN;

DO $$
DECLARE
  v_result jsonb;
  v_snapshot jsonb;
BEGIN
  PERFORM record_solana_wallet_flow_event('{
    "schemaVersion":1,
    "eventId":"solana-acquisition-snapshot",
    "eventType":"SolanaWalletAcquisition",
    "source":"solana-wallet:11111111111111111111111111111111:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
    "observedAtMs":"200000",
    "sourceSlot":"12",
    "sourceSequence":"swap-snapshot",
    "idempotencyKey":"solana-acquisition:wallet:swap-snapshot:mint",
    "rawPayloadHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "payload":{
      "wallet":"11111111111111111111111111111111",
      "signature":"swap-snapshot",
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
    "eventId":"solana-snapshot-a",
    "eventType":"SolanaCandidateSnapshot",
    "source":"solana-candidate:4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
    "observedAtMs":"201000",
    "sourceSlot":"12",
    "sourceSequence":"swap-snapshot",
    "idempotencyKey":"solana-snapshot:swap-snapshot:mint",
    "rawPayloadHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "payload":{
      "acquisitionEventId":"solana-acquisition-snapshot",
      "wallet":"11111111111111111111111111111111",
      "signature":"swap-snapshot",
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
      "sanctionsHit":false
    }
  }'::jsonb;

  v_result := record_solana_candidate_snapshot(v_snapshot);
  IF v_result->>'inserted' <> 'true' THEN
    RAISE EXCEPTION 'snapshot was not inserted: %', v_result;
  END IF;
  IF (SELECT top_ten_holder_concentration_bps FROM solana_candidate_snapshots
      WHERE event_id = 'solana-snapshot-a') <> 4000 THEN
    RAISE EXCEPTION 'snapshot safety fields were not preserved';
  END IF;
  IF (SELECT decision FROM solana_candidate_decisions
      WHERE snapshot_event_id = 'solana-snapshot-a') <> 'ENTER' THEN
    RAISE EXCEPTION 'safe organic candidate was not selected for paper entry';
  END IF;
  IF (SELECT evidence FROM solana_candidate_decisions
      WHERE snapshot_event_id = 'solana-snapshot-a')
      <> evaluate_solana_candidate('solana-snapshot-a', 'solana-wallet-flow-v1') THEN
    RAISE EXCEPTION 'historical candidate replay changed its decision';
  END IF;
  IF record_solana_candidate_snapshot(v_snapshot)->>'inserted' <> 'false' THEN
    RAISE EXCEPTION 'snapshot retry was not idempotent';
  END IF;

  UPDATE solana_candidate_snapshots
  SET unlinked_buyer_count = 9
  WHERE event_id = 'solana-snapshot-a';
  v_result := evaluate_solana_candidate('solana-snapshot-a', 'solana-wallet-flow-v1');
  IF v_result->>'decision' <> 'WATCH'
     OR v_result->>'reason' <> 'WATCH_INDEPENDENT_CONFIRMATION' THEN
    RAISE EXCEPTION 'incomplete confirmation was not watched: %', v_result;
  END IF;
  UPDATE solana_candidate_snapshots
  SET entry_price_impact_bps = 201
  WHERE event_id = 'solana-snapshot-a';
  v_result := evaluate_solana_candidate('solana-snapshot-a', 'solana-wallet-flow-v1');
  IF v_result->>'decision' <> 'REJECT' OR v_result->>'reason' <> 'ENTRY_IMPACT' THEN
    RAISE EXCEPTION 'unsafe impact was not rejected: %', v_result;
  END IF;
  UPDATE solana_candidate_snapshots
  SET unlinked_buyer_count = 10, entry_price_impact_bps = 100
  WHERE event_id = 'solana-snapshot-a';

  BEGIN
    PERFORM record_solana_candidate_snapshot(
      jsonb_set(v_snapshot, '{payload,tokenProgram}', '"unknown"')
    );
    RAISE EXCEPTION 'complete snapshot accepted an unknown token program';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

ROLLBACK;
