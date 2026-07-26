BEGIN;

ALTER TABLE normalized_events
  ADD COLUMN source_slot bigint NOT NULL DEFAULT 0 CHECK (source_slot >= 0);
ALTER TABLE normalized_events
  ALTER COLUMN source_slot DROP DEFAULT;

INSERT INTO schema_meta(version) VALUES (3);

COMMIT;
