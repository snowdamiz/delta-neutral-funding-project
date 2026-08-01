BEGIN;

DO $$
DECLARE
  v_result jsonb;
  v_event jsonb;
BEGIN
  v_event := '{
    "schemaVersion": 1,
    "eventId": "solana-acquisition-a",
    "eventType": "SolanaWalletAcquisition",
    "source": "solana-wallet:11111111111111111111111111111111:mint-a",
    "observedAtMs": "200000",
    "sourceSlot": "12",
    "sourceSequence": "swap-2",
    "idempotencyKey": "solana-acquisition:wallet:swap-2:mint-a",
    "rawPayloadHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "payload": {
      "wallet": "11111111111111111111111111111111",
      "signature": "swap-2",
      "confirmedAtMs": "102000",
      "inputMint": "So11111111111111111111111111111111111111112",
      "inputAmountAtoms": "100000",
      "outputMint": "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
      "outputAmountAtoms": "250000",
      "outputDecimals": "6",
      "routePrograms": ["JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"]
    }
  }'::jsonb;

  v_result := record_solana_wallet_flow_event(v_event);
  IF v_result->>'inserted' <> 'true' THEN
    RAISE EXCEPTION 'acquisition was not inserted: %', v_result;
  END IF;
  v_result := record_solana_wallet_flow_event(v_event);
  IF v_result->>'inserted' <> 'false' THEN
    RAISE EXCEPTION 'acquisition retry was not idempotent: %', v_result;
  END IF;

  v_event := jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(v_event, '{eventId}', '"solana-acquisition-b"'),
        '{source}', '"solana-wallet:11111111111111111111111111111111:mint-b"'
      ),
      '{idempotencyKey}', '"solana-acquisition:wallet:swap-2:mint-b"'
    ),
    '{payload,outputMint}', '"5Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ"'
  );
  PERFORM record_solana_wallet_flow_event(v_event);

  IF (SELECT count(*) FROM solana_wallet_acquisitions WHERE signature = 'swap-2') <> 2 THEN
    RAISE EXCEPTION 'multi-output swap was not preserved';
  END IF;

  v_result := record_solana_wallet_flow_event('{
    "schemaVersion": 1,
    "eventId": "solana-checkpoint-complete",
    "eventType": "SolanaWalletCheckpoint",
    "source": "solana-wallet:11111111111111111111111111111111",
    "observedAtMs": "200000",
    "sourceSlot": "12",
    "sourceSequence": "swap-2",
    "idempotencyKey": "solana-checkpoint:wallet:200000",
    "rawPayloadHash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "payload": {
      "wallet": "11111111111111111111111111111111",
      "status": "complete",
      "reason": "backfill_complete",
      "previousSignature": "cursor",
      "previousSlot": "9",
      "latestSignature": "swap-2",
      "latestSlot": "12"
    }
  }'::jsonb);
  IF v_result->>'captureComplete' <> 'true'
     OR (SELECT latest_signature FROM solana_wallet_cursors
         WHERE wallet = '11111111111111111111111111111111') <> 'swap-2' THEN
    RAISE EXCEPTION 'complete checkpoint did not advance the cursor: %', v_result;
  END IF;

  v_result := record_solana_wallet_flow_event('{
    "schemaVersion": 1,
    "eventId": "solana-checkpoint-gap",
    "eventType": "SolanaWalletCheckpoint",
    "source": "solana-wallet:11111111111111111111111111111111",
    "observedAtMs": "201000",
    "sourceSlot": "13",
    "sourceSequence": "gap-1",
    "idempotencyKey": "solana-checkpoint:wallet:201000",
    "rawPayloadHash": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "payload": {
      "wallet": "11111111111111111111111111111111",
      "status": "gap",
      "reason": "cursor_not_recovered",
      "previousSignature": "swap-2",
      "previousSlot": "12",
      "latestSignature": "swap-3",
      "latestSlot": "13"
    }
  }'::jsonb);
  IF v_result->>'captureComplete' <> 'false' THEN
    RAISE EXCEPTION 'capture gap did not fail closed: %', v_result;
  END IF;

  v_event := jsonb_set(
    jsonb_set(
      jsonb_set(v_event, '{eventId}', '"solana-acquisition-after-gap"'),
      '{idempotencyKey}', '"solana-acquisition:wallet:swap-3:mint-b"'
    ),
    '{sourceSlot}', '"13"'
  );
  v_event := jsonb_set(v_event, '{sourceSequence}', '"swap-3"');
  v_event := jsonb_set(v_event, '{payload,signature}', '"swap-3"');
  v_result := record_solana_wallet_flow_event(v_event);
  IF v_result->>'captureComplete' <> 'false' THEN
    RAISE EXCEPTION 'post-gap acquisition was treated as complete: %', v_result;
  END IF;
END;
$$;

ROLLBACK;
