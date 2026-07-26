BEGIN;

CREATE FUNCTION release_collector_lease(
  p_holder_instance_id text,
  p_generation bigint
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

  UPDATE leader_leases
  SET expires_at = clock_timestamp(),
      last_renewed_at = clock_timestamp()
  WHERE lease_name = 'collector'
    AND holder_instance_id = p_holder_instance_id
    AND generation = p_generation
    AND expires_at > clock_timestamp();

  RETURN FOUND;
END;
$$;

INSERT INTO schema_meta(version) VALUES (25);

COMMIT;
