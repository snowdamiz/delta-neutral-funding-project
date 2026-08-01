BEGIN;

-- A followed wallet that has not transacted still reports: every sweep posts
-- a checkpoint carrying the same durable cursor. The continuity trigger was
-- written for streamed market sources, where a repeated sequence at an
-- unchanged slot means the stream stalled, so it rejected those checkpoints —
-- one succeeded per wallet and every later one failed with a 500. An idle
-- wallet is the normal case, so capture stopped for the whole cohort.
--
-- Wallet-flow sources already carry a stronger, purpose-built continuity
-- mechanism: solana_wallet_cursors advances its signature and slot only while
-- capture_complete holds, latches closed on the first gap, and is what the
-- frozen validation window reads. Candidate snapshots were exempted from this
-- trigger for the same reason. Grant the acquisition and checkpoint types the
-- same exemption, still refusing a slot regression, and leave gap detection
-- where it belongs.
-- The same repeat also collides with the source-sequence uniqueness index,
-- exactly as re-quoting one candidate did before schema 45. Key a checkpoint
-- by its observation the way a candidate snapshot already is.
DROP INDEX normalized_events_source_sequence_unique;
CREATE UNIQUE INDEX normalized_events_source_sequence_unique
  ON normalized_events(source, event_type, source_sequence)
  WHERE event_type NOT IN ('SolanaCandidateSnapshot', 'SolanaWalletCheckpoint');
CREATE UNIQUE INDEX normalized_events_wallet_checkpoint_sequence_unique
  ON normalized_events(source, event_type, source_sequence, observed_at_ms)
  WHERE event_type = 'SolanaWalletCheckpoint';

CREATE OR REPLACE FUNCTION enforce_source_continuity() RETURNS trigger
LANGUAGE plpgsql
AS $$
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
  IF NEW.event_type = 'SolanaCandidateSnapshot'
     AND v_prior.event_type = 'SolanaCandidateSnapshot'
     AND NEW.source_sequence = v_prior.source_sequence
     AND NEW.source_slot = v_prior.source_slot
     AND NEW.observed_at_ms > v_prior.observed_at_ms THEN
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
$$;

INSERT INTO schema_meta(version) VALUES (54);

COMMIT;
