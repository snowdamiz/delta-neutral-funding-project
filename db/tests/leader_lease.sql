\set ON_ERROR_STOP on
BEGIN;
DELETE FROM leader_leases WHERE lease_name = 'collector';
UPDATE control_state
SET pause_entries = false,
    pause_all = false,
    reason = 'leader_lease_test'
WHERE singleton;

DO $$
DECLARE
  v_generation bigint;
  v_control_version bigint;
BEGIN
  SELECT version INTO v_control_version FROM control_state WHERE singleton;

  v_generation := acquire_collector_lease('lease-test-a', 10000);
  IF v_generation <> 1 OR NOT collector_lease_held('lease-test-a') THEN
    RAISE EXCEPTION 'first holder did not acquire generation one';
  END IF;
  IF acquire_collector_lease('lease-test-b', 10000) <> 0 THEN
    RAISE EXCEPTION 'second holder acquired a live lease';
  END IF;

  UPDATE leader_leases
  SET expires_at = clock_timestamp() - interval '1 millisecond'
  WHERE lease_name = 'collector';
  v_generation := acquire_collector_lease('lease-test-b', 10000);
  IF v_generation <> 2
     OR NOT collector_lease_held('lease-test-b')
     OR collector_lease_held('lease-test-a') THEN
    RAISE EXCEPTION 'expired lease was not fenced by a new generation';
  END IF;

  UPDATE leader_leases
  SET holder_instance_id = 'lease-test-c',
      generation = generation + 1
  WHERE lease_name = 'collector';
  PERFORM fail_closed_for_lease_loss('lease-test-b', v_generation);
  IF NOT (
    SELECT pause_entries
      AND pause_all
      AND reason = 'leader_lease_lost'
      AND version = v_control_version + 1
    FROM control_state
    WHERE singleton
  ) THEN
    RAISE EXCEPTION 'lease loss did not fail closed';
  END IF;
  PERFORM fail_closed_for_lease_loss('lease-test-b', v_generation);
  IF (SELECT version FROM control_state WHERE singleton) <> v_control_version + 1 THEN
    RAISE EXCEPTION 'repeated lease loss was not idempotent';
  END IF;
  IF (
    SELECT count(*)
    FROM risk_events
    WHERE id = 'leader-lease-lost:lease-test-b:2'
  ) <> 1 THEN
    RAISE EXCEPTION 'lease loss risk event is missing or duplicated';
  END IF;
END;
$$;

ROLLBACK;
