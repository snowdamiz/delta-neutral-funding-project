BEGIN;

-- The second wedge, hiding behind the first.
--
-- One wallet bought the same mint in two transactions. Both produce a
-- candidate snapshot on the same source and at the same slot, but with
-- different signatures — and the exemption added for re-quoting demanded the
-- source sequence match, so the second snapshot was refused as a sequence
-- regression. That is a 500 to the observer, which fails the tick, so the
-- cursor never advances past the acquisition and every later sweep fails the
-- same way. Same failure shape as the acquisition conflict in schema 58, a
-- different cause, and it only became visible once that one was fixed.

CREATE OR REPLACE FUNCTION enforce_source_continuity() RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_prior normalized_events%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(NEW.source));
  IF EXISTS (
    SELECT 1 FROM normalized_events WHERE idempotency_key = NEW.idempotency_key
  ) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_prior
  FROM normalized_events
  WHERE source = NEW.source
  ORDER BY source_slot DESC, received_at DESC, id DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;
  -- A candidate snapshot is not a position in a stream. It is an independent
  -- re-quote of one mint, and the same mint is snapshotted again whenever it
  -- is re-scored or bought a second time — by another signature, at the same
  -- slot. Requiring the sequence to match made that second buy unrecordable:
  -- the insert raised, the observer's whole tick failed, and capture wedged.
  -- Snapshots carry their own uniqueness index, and gap detection for this
  -- source lives in solana_wallet_cursors, so time moving forward is the only
  -- continuity a snapshot owes. Equal is allowed: one sweep can snapshot two
  -- acquisitions of the same mint in the same millisecond.
  IF NEW.event_type = 'SolanaCandidateSnapshot'
     AND v_prior.event_type = 'SolanaCandidateSnapshot'
     AND NEW.observed_at_ms >= v_prior.observed_at_ms THEN
    RETURN NEW;
  END IF;
  -- A wallet's cursor may repeat while it is idle; it may never go backwards.
  IF NEW.event_type IN ('SolanaWalletAcquisition', 'SolanaWalletCheckpoint')
     AND v_prior.event_type IN ('SolanaWalletAcquisition', 'SolanaWalletCheckpoint')
     AND NEW.source_slot >= v_prior.source_slot THEN
    RETURN NEW;
  END IF;
  IF NEW.source_sequence ~ '^(0|[1-9][0-9]*)$'
     AND v_prior.source_sequence ~ '^(0|[1-9][0-9]*)$' THEN
    IF NEW.source_sequence::numeric = v_prior.source_sequence::numeric + 1
       AND NEW.source_slot >= v_prior.source_slot THEN
      RETURN NEW;
    END IF;
    IF NEW.source_sequence = v_prior.source_sequence
       AND NEW.source_slot = v_prior.source_slot
       AND NOT EXISTS (
         SELECT 1 FROM normalized_events
         WHERE source = NEW.source
           AND event_type = NEW.event_type
           AND source_sequence = NEW.source_sequence
       ) THEN
      RETURN NEW;
    END IF;
  ELSIF NEW.source_slot > v_prior.source_slot THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'source sequence gap or regression for %', NEW.source;
END;
$function$;

INSERT INTO schema_meta(version) VALUES (59);

COMMIT;
