BEGIN;

DO $migration$
DECLARE
  v_definition text;
  v_updated text;
BEGIN
  SELECT pg_get_functiondef(
    'cross_venue_funding_leaderboard(bigint,bigint,bigint,bigint,bigint,integer,bigint,bigint,bigint)'::regprocedure
  ) INTO v_definition;

  v_updated := replace(
    v_definition,
    'high.depth_qualified AS short_depth_qualified,',
    '(high.perp_exit_depth_atoms >= trunc(p_position_notional_usd_micros::numeric * 1000000000 / GREATEST(high.perp_bid_price_usd_micros, low.perp_ask_price_usd_micros))) AS short_depth_qualified,'
  );
  v_updated := replace(
    v_updated,
    'low.depth_qualified AS long_depth_qualified,',
    '(low.perp_exit_depth_atoms >= trunc(p_position_notional_usd_micros::numeric * 1000000000 / GREATEST(high.perp_bid_price_usd_micros, low.perp_ask_price_usd_micros))) AS long_depth_qualified,'
  );
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'cross-venue leaderboard depth contract changed unexpectedly';
  END IF;
  EXECUTE v_updated;

  SELECT pg_get_functiondef(
    'run_cross_venue_paper_scan(text,bigint,bigint,bigint,bigint,bigint,integer,bigint,bigint,bigint)'::regprocedure
  ) INTO v_definition;
  v_updated := replace(
    v_definition,
    E'        AND v_short.depth_qualified\n        AND v_long.depth_qualified\n',
    ''
  );
  v_updated := replace(
    v_updated,
    'COALESCE(v_short.depth_qualified, false)',
    'COALESCE(v_short.perp_exit_depth_atoms >= v_position.quantity_atoms, false)'
  );
  v_updated := replace(
    v_updated,
    'COALESCE(v_long.depth_qualified, false)',
    'COALESCE(v_long.perp_exit_depth_atoms >= v_position.quantity_atoms, false)'
  );
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'cross-venue paper depth contract changed unexpectedly';
  END IF;
  EXECUTE v_updated;
END;
$migration$;

INSERT INTO schema_meta(version) VALUES (40);

COMMIT;
