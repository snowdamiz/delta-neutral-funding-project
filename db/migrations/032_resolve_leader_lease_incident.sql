\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION resolve_leader_lease_incident_on_resume()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT NEW.pause_entries
     AND NOT NEW.pause_all
     AND EXISTS (
       SELECT 1
       FROM leader_leases
       WHERE lease_name = 'collector'
         AND expires_at > clock_timestamp()
     ) THEN
    UPDATE risk_events
    SET resolved_at = now()
    WHERE code = 'leader_lease_lost'
      AND resolved_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER resolve_leader_lease_incident_on_resume
AFTER UPDATE OF pause_entries, pause_all ON control_state
FOR EACH ROW
EXECUTE FUNCTION resolve_leader_lease_incident_on_resume();

INSERT INTO schema_meta(version) VALUES (32);

COMMIT;
