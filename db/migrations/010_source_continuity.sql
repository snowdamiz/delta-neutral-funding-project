BEGIN;

CREATE FUNCTION enforce_source_continuity() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_prior normalized_events%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(NEW.source));

  IF EXISTS (
    SELECT 1
    FROM normalized_events
    WHERE idempotency_key = NEW.idempotency_key
  ) THEN
    RETURN NEW;
  END IF;

  SELECT *
  INTO v_prior
  FROM normalized_events
  WHERE source = NEW.source
  ORDER BY source_slot DESC, received_at DESC, id DESC
  LIMIT 1;

  IF NOT FOUND THEN
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
         SELECT 1
         FROM normalized_events
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

CREATE TRIGGER normalized_events_source_continuity
BEFORE INSERT ON normalized_events
FOR EACH ROW EXECUTE FUNCTION enforce_source_continuity();

INSERT INTO schema_meta(version) VALUES (10);

COMMIT;
