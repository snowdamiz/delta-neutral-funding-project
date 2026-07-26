BEGIN;

ALTER TABLE normalized_events
  ADD CONSTRAINT normalized_events_source_sequence_unique
  UNIQUE (source, event_type, source_sequence);

ALTER TABLE portfolio_runs
  ADD COLUMN random_state bigint NOT NULL DEFAULT 42;

INSERT INTO schema_meta(version) VALUES (2);

COMMIT;
