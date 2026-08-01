BEGIN;

CREATE TABLE solana_wallet_cursors (
  wallet text PRIMARY KEY CHECK (wallet ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  latest_signature text NOT NULL,
  latest_slot bigint NOT NULL CHECK (latest_slot >= 0),
  capture_complete boolean NOT NULL,
  gap_reason text,
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (capture_complete OR gap_reason IS NOT NULL)
);

CREATE TABLE solana_wallet_checkpoints (
  event_id text PRIMARY KEY REFERENCES normalized_events(id),
  wallet text NOT NULL CHECK (wallet ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  status text NOT NULL CHECK (status IN ('complete', 'gap')),
  reason text NOT NULL CHECK (
    reason IN ('backfill_complete', 'cursor_not_recovered', 'backfill_limit_reached')
  ),
  previous_signature text NOT NULL,
  previous_slot bigint NOT NULL CHECK (previous_slot >= 0),
  latest_signature text NOT NULL,
  latest_slot bigint NOT NULL CHECK (latest_slot >= previous_slot),
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (status = 'complete' AND reason = 'backfill_complete')
    OR
    (status = 'gap' AND reason <> 'backfill_complete')
  )
);

CREATE INDEX solana_wallet_checkpoints_wallet_time
  ON solana_wallet_checkpoints(wallet, observed_at_ms DESC);

CREATE TABLE solana_wallet_acquisitions (
  event_id text PRIMARY KEY REFERENCES normalized_events(id),
  wallet text NOT NULL CHECK (wallet ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  signature text NOT NULL,
  slot bigint NOT NULL CHECK (slot >= 0),
  confirmed_at_ms bigint NOT NULL CHECK (confirmed_at_ms >= 0),
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= confirmed_at_ms),
  input_mint text NOT NULL CHECK (input_mint ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  input_amount_atoms numeric NOT NULL CHECK (input_amount_atoms > 0),
  output_mint text NOT NULL CHECK (output_mint ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  output_amount_atoms numeric NOT NULL CHECK (output_amount_atoms > 0),
  output_decimals integer NOT NULL CHECK (output_decimals BETWEEN 0 AND 18),
  route_programs jsonb NOT NULL CHECK (
    jsonb_typeof(route_programs) = 'array'
    AND jsonb_array_length(route_programs) BETWEEN 1 AND 32
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (wallet, signature, output_mint)
);

CREATE INDEX solana_wallet_acquisitions_wallet_time
  ON solana_wallet_acquisitions(wallet, confirmed_at_ms, signature, output_mint);
CREATE INDEX solana_wallet_acquisitions_mint_time
  ON solana_wallet_acquisitions(output_mint, confirmed_at_ms DESC);

CREATE FUNCTION record_solana_wallet_flow_event(p_event jsonb) RETURNS jsonb
LANGUAGE plpgsql
AS $$
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
    IF NOT EXISTS (
      SELECT 1
      FROM normalized_events
      WHERE idempotency_key = p_event->>'idempotencyKey'
        AND id = v_event_id
        AND raw_payload_hash = p_event->>'rawPayloadHash'
        AND canonical_payload = p_event
    ) THEN
      RAISE EXCEPTION 'Solana wallet event idempotency conflict';
    END IF;
    SELECT capture_complete INTO v_capture_complete
    FROM solana_wallet_cursors WHERE wallet = v_wallet;
    RETURN jsonb_build_object(
      'inserted', false,
      'eventId', v_event_id,
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
$$;

INSERT INTO schema_meta(version) VALUES (42);

COMMIT;
