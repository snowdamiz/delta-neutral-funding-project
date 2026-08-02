BEGIN;

-- Re-observing an acquisition is not a conflict.
--
-- An acquisition is identified by on-chain facts — wallet, signature, mint —
-- and its idempotency key says exactly that. The retry check, though, demanded
-- the whole event match byte for byte, including two fields that legitimately
-- differ between two observations of the same fact: `observedAtMs`, which is
-- when the adapter looked rather than when the trade happened, and `eventId`,
-- which carries the adapter's per-process session id.
--
-- So the second observation of an already-captured signature raised
-- 'idempotency conflict'. That is a 500 to the observer, which fails the whole
-- tick, so the cursor never advances past the acquisition — and the next sweep
-- re-reads the same signature and fails identically. Capture wedges closed and
-- stays there. It did: two wallets stopped advancing and retried in a loop
-- until this was found.
--
-- Only the evidence is compared now: same source, slot, sequence, raw
-- transaction hash and payload means the same event, whenever it was seen and
-- whichever process saw it. Every other difference still conflicts, loudly.

CREATE OR REPLACE FUNCTION record_solana_wallet_flow_event(p_event jsonb)
RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_payload jsonb;
  v_event_id text;
  v_event_type text;
  v_wallet text;
  v_observed_at_ms bigint;
  v_source_slot bigint;
  v_inserted boolean;
  v_capture_complete boolean;
  v_cursor solana_wallet_cursors%ROWTYPE;
BEGIN
  IF jsonb_typeof(p_event) <> 'object'
     OR p_event->>'schemaVersion' <> '1'
     OR p_event->>'eventId' !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR p_event->>'eventType'
       NOT IN ('SolanaWalletAcquisition', 'SolanaWalletCheckpoint')
     OR p_event->>'source' !~ '^solana-wallet:'
     OR p_event->>'observedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR p_event->>'sourceSlot' !~ '^(0|[1-9][0-9]*)$'
     OR COALESCE(p_event->>'sourceSequence', '') = ''
     OR p_event->>'idempotencyKey' !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR p_event->>'rawPayloadHash' !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_event->'payload') <> 'object' THEN
    RAISE EXCEPTION 'invalid Solana wallet event envelope';
  END IF;

  v_payload := p_event->'payload';
  v_event_id := p_event->>'eventId';
  v_event_type := p_event->>'eventType';
  v_wallet := v_payload->>'wallet';
  v_observed_at_ms := (p_event->>'observedAtMs')::bigint;
  v_source_slot := (p_event->>'sourceSlot')::bigint;
  IF v_wallet !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$' THEN
    RAISE EXCEPTION 'invalid followed Solana wallet';
  END IF;

  IF v_event_type = 'SolanaWalletAcquisition' THEN
    IF COALESCE(v_payload->>'signature', '') = ''
       OR v_payload->>'confirmedAtMs' !~ '^(0|[1-9][0-9]*)$'
       OR (v_payload->>'confirmedAtMs')::bigint > v_observed_at_ms
       OR v_payload->>'inputMint' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
       OR v_payload->>'inputAmountAtoms' !~ '^[1-9][0-9]*$'
       OR v_payload->>'outputMint' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
       OR v_payload->>'outputAmountAtoms' !~ '^[1-9][0-9]*$'
       OR v_payload->>'outputDecimals' !~ '^(0|[1-9][0-9]*)$'
       OR (v_payload->>'outputDecimals')::integer > 18
       OR v_payload->>'inputMint' = v_payload->>'outputMint'
       OR jsonb_typeof(v_payload->'routePrograms') <> 'array'
       OR jsonb_array_length(v_payload->'routePrograms') NOT BETWEEN 1 AND 32
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements_text(v_payload->'routePrograms') program
         WHERE program !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
       ) THEN
      RAISE EXCEPTION 'invalid Solana wallet acquisition';
    END IF;
  ELSE
    IF v_payload->>'status' NOT IN ('complete', 'gap')
       OR v_payload->>'reason'
         NOT IN ('backfill_complete', 'cursor_not_recovered', 'backfill_limit_reached')
       OR (v_payload->>'status' = 'complete')
         <> (v_payload->>'reason' = 'backfill_complete')
       OR v_payload->>'previousSlot' !~ '^(0|[1-9][0-9]*)$'
       OR v_payload->>'latestSlot' !~ '^(0|[1-9][0-9]*)$'
       OR (v_payload->>'latestSlot')::bigint < (v_payload->>'previousSlot')::bigint
       OR (v_payload->>'latestSlot')::bigint <> v_source_slot THEN
      RAISE EXCEPTION 'invalid Solana wallet checkpoint';
    END IF;
  END IF;

  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    v_event_id, 1, v_event_type, p_event->>'source', v_observed_at_ms,
    v_source_slot, p_event->>'sourceSequence', p_event->>'idempotencyKey',
    p_event->>'rawPayloadHash', p_event
  ) ON CONFLICT (idempotency_key) DO NOTHING;
  v_inserted := FOUND;
  IF NOT v_inserted THEN
    -- The evidence, not the observation. `observedAtMs` records when the
    -- adapter looked and `eventId` carries its session id, so both differ
    -- legitimately between two observations of one on-chain fact. Everything
    -- describing what happened on chain is still compared exactly.
    IF NOT EXISTS (
      SELECT 1
      FROM normalized_events
      WHERE idempotency_key = p_event->>'idempotencyKey'
        AND event_type = v_event_type
        AND source = p_event->>'source'
        AND source_slot = v_source_slot
        AND source_sequence = p_event->>'sourceSequence'
        AND raw_payload_hash = p_event->>'rawPayloadHash'
        AND canonical_payload->'payload' = v_payload
    ) THEN
      RAISE EXCEPTION 'Solana wallet event idempotency conflict';
    END IF;
    SELECT capture_complete INTO v_capture_complete
    FROM solana_wallet_cursors WHERE wallet = v_wallet;
    RETURN jsonb_build_object(
      'inserted', false,
      'eventId', (SELECT id FROM normalized_events
                  WHERE idempotency_key = p_event->>'idempotencyKey'),
      'captureComplete', COALESCE(v_capture_complete, false)
    );
  END IF;

  IF v_event_type = 'SolanaWalletAcquisition' THEN
    INSERT INTO solana_wallet_acquisitions (
      event_id, wallet, signature, slot, confirmed_at_ms, observed_at_ms,
      input_mint, input_amount_atoms, output_mint, output_amount_atoms,
      output_decimals, route_programs
    ) VALUES (
      v_event_id, v_wallet, v_payload->>'signature', v_source_slot,
      (v_payload->>'confirmedAtMs')::bigint, v_observed_at_ms,
      v_payload->>'inputMint', (v_payload->>'inputAmountAtoms')::numeric,
      v_payload->>'outputMint', (v_payload->>'outputAmountAtoms')::numeric,
      (v_payload->>'outputDecimals')::integer, v_payload->'routePrograms'
    );
  ELSE
    SELECT * INTO v_cursor
    FROM solana_wallet_cursors WHERE wallet = v_wallet FOR UPDATE;
    IF FOUND
       AND v_payload->>'status' = 'complete'
       AND (
         v_cursor.latest_signature <> v_payload->>'previousSignature'
         OR v_cursor.latest_slot <> (v_payload->>'previousSlot')::bigint
       ) THEN
      RAISE EXCEPTION 'Solana wallet checkpoint does not continue the durable cursor';
    END IF;

    INSERT INTO solana_wallet_checkpoints (
      event_id, wallet, status, reason, previous_signature, previous_slot,
      latest_signature, latest_slot, observed_at_ms
    ) VALUES (
      v_event_id, v_wallet, v_payload->>'status', v_payload->>'reason',
      v_payload->>'previousSignature', (v_payload->>'previousSlot')::bigint,
      v_payload->>'latestSignature', (v_payload->>'latestSlot')::bigint,
      v_observed_at_ms
    );

    INSERT INTO solana_wallet_cursors (
      wallet, latest_signature, latest_slot, capture_complete, gap_reason,
      observed_at_ms
    ) VALUES (
      v_wallet,
      CASE WHEN v_payload->>'status' = 'complete'
        THEN v_payload->>'latestSignature' ELSE v_payload->>'previousSignature' END,
      CASE WHEN v_payload->>'status' = 'complete'
        THEN (v_payload->>'latestSlot')::bigint
        ELSE (v_payload->>'previousSlot')::bigint END,
      v_payload->>'status' = 'complete',
      CASE WHEN v_payload->>'status' = 'gap' THEN v_payload->>'reason' END,
      v_observed_at_ms
    )
    ON CONFLICT (wallet) DO UPDATE SET
      latest_signature = CASE
        WHEN EXCLUDED.capture_complete THEN EXCLUDED.latest_signature
        ELSE solana_wallet_cursors.latest_signature
      END,
      latest_slot = CASE
        WHEN EXCLUDED.capture_complete THEN EXCLUDED.latest_slot
        ELSE solana_wallet_cursors.latest_slot
      END,
      capture_complete = solana_wallet_cursors.capture_complete
        AND EXCLUDED.capture_complete,
      gap_reason = COALESCE(
        solana_wallet_cursors.gap_reason,
        EXCLUDED.gap_reason
      ),
      observed_at_ms = EXCLUDED.observed_at_ms,
      updated_at = now();
  END IF;

  SELECT capture_complete INTO v_capture_complete
  FROM solana_wallet_cursors WHERE wallet = v_wallet;
  RETURN jsonb_build_object(
    'inserted', true,
    'eventId', v_event_id,
    'captureComplete', COALESCE(v_capture_complete, false)
  );
END;
$function$;

INSERT INTO schema_meta(version) VALUES (58);

COMMIT;
