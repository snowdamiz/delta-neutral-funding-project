BEGIN;

CREATE FUNCTION acquire_collector_lease(
  p_holder_instance_id text,
  p_ttl_ms integer
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_generation bigint;
BEGIN
  IF p_holder_instance_id !~ '^[A-Za-z0-9:_-]{1,200}$' THEN
    RAISE EXCEPTION 'invalid lease holder identity';
  END IF;
  IF p_ttl_ms < 1000 OR p_ttl_ms > 60000 THEN
    RAISE EXCEPTION 'lease TTL must be between 1000 and 60000 milliseconds';
  END IF;

  INSERT INTO leader_leases (
    lease_name, holder_instance_id, generation,
    acquired_at, expires_at, last_renewed_at
  ) VALUES (
    'collector',
    p_holder_instance_id,
    1,
    clock_timestamp(),
    clock_timestamp() + p_ttl_ms * interval '1 millisecond',
    clock_timestamp()
  )
  ON CONFLICT (lease_name) DO UPDATE
  SET holder_instance_id = EXCLUDED.holder_instance_id,
      generation = CASE
        WHEN leader_leases.holder_instance_id = EXCLUDED.holder_instance_id
         AND leader_leases.expires_at > clock_timestamp()
        THEN leader_leases.generation
        ELSE leader_leases.generation + 1
      END,
      acquired_at = CASE
        WHEN leader_leases.holder_instance_id = EXCLUDED.holder_instance_id
         AND leader_leases.expires_at > clock_timestamp()
        THEN leader_leases.acquired_at
        ELSE clock_timestamp()
      END,
      expires_at = clock_timestamp() + p_ttl_ms * interval '1 millisecond',
      last_renewed_at = clock_timestamp()
  WHERE leader_leases.holder_instance_id = EXCLUDED.holder_instance_id
     OR leader_leases.expires_at <= clock_timestamp()
  RETURNING generation INTO v_generation;

  RETURN COALESCE(v_generation, 0);
END;
$$;

CREATE FUNCTION collector_lease_held(
  p_holder_instance_id text
) RETURNS boolean
LANGUAGE sql
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM leader_leases
    WHERE lease_name = 'collector'
      AND holder_instance_id = p_holder_instance_id
      AND expires_at > clock_timestamp()
  )
$$;

CREATE FUNCTION fail_closed_for_lease_loss(
  p_holder_instance_id text,
  p_generation bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_version bigint;
BEGIN
  IF p_generation < 0 THEN
    RAISE EXCEPTION 'invalid lost lease generation';
  END IF;

  UPDATE control_state
  SET pause_entries = true,
      pause_all = true,
      reason = 'leader_lease_lost',
      version = version + 1,
      updated_at = now()
  WHERE singleton
    AND NOT (
      pause_entries
      AND pause_all
      AND reason = 'leader_lease_lost'
    );

  SELECT version INTO v_version FROM control_state WHERE singleton;

  INSERT INTO risk_events (
    id, strategy_run_id, severity, code, message,
    observed_value, limit_value, action_taken
  ) VALUES (
    'leader-lease-lost:' || p_holder_instance_id || ':' || p_generation,
    (SELECT id FROM strategy_runs WHERE id = 'local-paper-run'),
    'critical',
    'leader_lease_lost',
    'collector lost its renewable writer lease',
    jsonb_build_object(
      'holderInstanceId', p_holder_instance_id,
      'generation', p_generation::text
    ),
    jsonb_build_object('leaseRequired', true),
    'pause_all'
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN v_version;
END;
$$;

INSERT INTO schema_meta(version) VALUES (8);

COMMIT;
