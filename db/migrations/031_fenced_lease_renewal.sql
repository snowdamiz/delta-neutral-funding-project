BEGIN;

CREATE FUNCTION renew_collector_lease(
  p_holder_instance_id text,
  p_generation bigint,
  p_ttl_ms integer
) RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_holder_instance_id !~ '^[A-Za-z0-9:_-]{1,200}$' THEN
    RAISE EXCEPTION 'invalid lease holder identity';
  END IF;
  IF p_generation < 1 THEN
    RAISE EXCEPTION 'invalid lease generation';
  END IF;
  IF p_ttl_ms < 1000 OR p_ttl_ms > 60000 THEN
    RAISE EXCEPTION 'lease TTL must be between 1000 and 60000 milliseconds';
  END IF;

  UPDATE leader_leases
  SET expires_at = clock_timestamp() + p_ttl_ms * interval '1 millisecond',
      last_renewed_at = clock_timestamp()
  WHERE lease_name = 'collector'
    AND holder_instance_id = p_holder_instance_id
    AND generation = p_generation
    AND expires_at > clock_timestamp();

  RETURN FOUND;
END;
$$;

INSERT INTO schema_meta(version) VALUES (31);

COMMIT;
