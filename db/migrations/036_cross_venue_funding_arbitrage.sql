BEGIN;

ALTER TYPE strategy_variant
  ADD VALUE IF NOT EXISTS 'cross_venue_funding';

ALTER TABLE funding_observations
  ADD COLUMN margin_status text NOT NULL DEFAULT 'unavailable'
    CHECK (margin_status IN ('valid', 'unavailable')),
  ADD COLUMN maintenance_margin_ppm bigint NOT NULL DEFAULT 0
    CHECK (maintenance_margin_ppm BETWEEN 0 AND 1000000),
  ADD CHECK (
    (margin_status = 'valid' AND maintenance_margin_ppm > 0)
    OR (margin_status = 'unavailable' AND maintenance_margin_ppm = 0)
  );

CREATE FUNCTION funding_observation_margin_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload jsonb;
  v_status text;
  v_rate text;
BEGIN
  SELECT canonical_payload->'payload'
  INTO v_payload
  FROM normalized_events
  WHERE id = NEW.event_id;

  v_status := COALESCE(v_payload->>'marginStatus', 'unavailable');
  v_rate := COALESCE(v_payload->>'maintenanceMarginPpm', '0');
  IF v_status NOT IN ('valid', 'unavailable')
     OR v_rate !~ '^(0|[1-9][0-9]*)$'
     OR v_rate::numeric > 1000000
     OR (v_status = 'valid' AND v_rate::numeric = 0)
     OR (v_status = 'unavailable' AND v_rate::numeric <> 0) THEN
    RAISE EXCEPTION 'invalid funding observation margin contract';
  END IF;

  NEW.margin_status := v_status;
  NEW.maintenance_margin_ppm := v_rate::bigint;
  RETURN NEW;
END;
$$;

CREATE TRIGGER funding_observation_margin_fields
BEFORE INSERT ON funding_observations
FOR EACH ROW
EXECUTE FUNCTION funding_observation_margin_fields();

CREATE TABLE cross_venue_paper_positions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  status text NOT NULL
    CHECK (status IN ('open', 'exit_blocked', 'closed')),
  asset text NOT NULL CHECK (asset ~ '^[A-Z0-9]+$'),
  instrument text NOT NULL,
  short_venue text NOT NULL,
  long_venue text NOT NULL,
  quantity_atoms numeric NOT NULL CHECK (quantity_atoms > 0),
  entry_short_price_usd_micros bigint NOT NULL
    CHECK (entry_short_price_usd_micros > 0),
  entry_long_price_usd_micros bigint NOT NULL
    CHECK (entry_long_price_usd_micros > 0),
  short_collateral_usd_micros bigint NOT NULL
    CHECK (short_collateral_usd_micros > 0),
  long_collateral_usd_micros bigint NOT NULL
    CHECK (long_collateral_usd_micros > 0),
  short_maintenance_margin_ppm bigint NOT NULL
    CHECK (short_maintenance_margin_ppm BETWEEN 1 AND 1000000),
  long_maintenance_margin_ppm bigint NOT NULL
    CHECK (long_maintenance_margin_ppm BETWEEN 1 AND 1000000),
  short_equity_usd_micros bigint NOT NULL,
  long_equity_usd_micros bigint NOT NULL,
  short_maintenance_usd_micros bigint NOT NULL
    CHECK (short_maintenance_usd_micros > 0),
  long_maintenance_usd_micros bigint NOT NULL
    CHECK (long_maintenance_usd_micros > 0),
  short_margin_ratio_ppm bigint NOT NULL,
  long_margin_ratio_ppm bigint NOT NULL,
  short_liquidation_distance_bps bigint NOT NULL,
  long_liquidation_distance_bps bigint NOT NULL,
  short_funding_usd_micros bigint NOT NULL DEFAULT 0,
  long_funding_usd_micros bigint NOT NULL DEFAULT 0,
  last_short_funding_at_ms bigint NOT NULL CHECK (last_short_funding_at_ms >= 0),
  last_long_funding_at_ms bigint NOT NULL CHECK (last_long_funding_at_ms >= 0),
  opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= 0),
  closed_at_ms bigint CHECK (closed_at_ms >= opened_at_ms),
  opened_scan_id text NOT NULL,
  latest_scan_id text NOT NULL,
  opened_short_source_event_id text NOT NULL REFERENCES normalized_events(id),
  opened_long_source_event_id text NOT NULL REFERENCES normalized_events(id),
  latest_short_source_event_id text NOT NULL REFERENCES normalized_events(id),
  latest_long_source_event_id text NOT NULL REFERENCES normalized_events(id),
  exit_short_price_usd_micros bigint
    CHECK (exit_short_price_usd_micros > 0),
  exit_long_price_usd_micros bigint
    CHECK (exit_long_price_usd_micros > 0),
  realized_basis_usd_micros bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (short_venue <> long_venue)
);

CREATE UNIQUE INDEX cross_venue_one_open_per_portfolio
  ON cross_venue_paper_positions(portfolio_run_id)
  WHERE status IN ('open', 'exit_blocked');

CREATE TABLE cross_venue_paper_decisions (
  id text PRIMARY KEY,
  scan_id text NOT NULL,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  short_source_event_id text NOT NULL REFERENCES normalized_events(id),
  long_source_event_id text NOT NULL REFERENCES normalized_events(id),
  asset text NOT NULL,
  short_venue text NOT NULL,
  long_venue text NOT NULL,
  rank integer NOT NULL CHECK (rank > 0),
  short_realized_average_ppm bigint NOT NULL,
  long_realized_average_ppm bigint NOT NULL,
  realized_spread_ppm_per_hour bigint NOT NULL,
  gate_distance_ppm bigint NOT NULL,
  expected_funding_usd_micros bigint NOT NULL,
  net_carry_usd_micros bigint NOT NULL,
  short_margin_ratio_ppm bigint NOT NULL,
  long_margin_ratio_ppm bigint NOT NULL,
  short_liquidation_distance_bps bigint NOT NULL,
  long_liquidation_distance_bps bigint NOT NULL,
  mark_divergence_usd_micros bigint NOT NULL DEFAULT 0,
  eligible boolean NOT NULL,
  action text NOT NULL,
  reason_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (scan_id, portfolio_run_id)
);

CREATE FUNCTION cross_venue_funding_leaderboard(
  p_now_ms bigint,
  p_source_max_age_ms bigint,
  p_position_notional_usd_micros bigint,
  p_cost_usd_micros bigint,
  p_risk_buffer_usd_micros bigint,
  p_hold_hours integer,
  p_collateral_usd_micros bigint,
  p_minimum_margin_ratio_ppm bigint,
  p_minimum_liquidation_distance_bps bigint
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_threshold bigint;
  v_items jsonb;
BEGIN
  IF p_now_ms < 0
     OR p_source_max_age_ms <= 0
     OR p_position_notional_usd_micros <= 0
     OR p_cost_usd_micros < 0
     OR p_risk_buffer_usd_micros < 0
     OR p_hold_hours <= 0
     OR p_collateral_usd_micros <= 0
     OR p_minimum_margin_ratio_ppm <= 0
     OR p_minimum_liquidation_distance_bps < 0 THEN
    RAISE EXCEPTION 'invalid cross-venue leaderboard inputs';
  END IF;

  v_threshold := ceil(
    ((p_cost_usd_micros + p_risk_buffer_usd_micros)::numeric * 1000000)
      / (p_position_notional_usd_micros::numeric * p_hold_hours)
  )::bigint;

  WITH completed AS (
    SELECT scan_id, max(observed_at_ms) AS observed_at_ms
    FROM funding_observations
    WHERE observed_at_ms <= p_now_ms
    GROUP BY scan_id
    HAVING count(*) = max(scan_size)
  ),
  current_scan AS (
    SELECT scan_id
    FROM completed
    ORDER BY observed_at_ms DESC, scan_id
    LIMIT 1
  ),
  current_rows AS (
    SELECT f.*
    FROM funding_observations f
    JOIN current_scan c USING (scan_id)
  ),
  realized_rows AS (
    SELECT DISTINCT ON (venue, asset, realized_funding_at_ms)
      venue,
      asset,
      realized_funding_at_ms,
      realized_funding_rate_ppm
    FROM funding_observations
    WHERE realized_funding_at_ms > p_now_ms - 86400000
      AND realized_funding_at_ms <= p_now_ms
      AND realized_funding_at_ms > 0
      AND observed_at_ms <= p_now_ms
      AND source_status = 'valid'
      AND source_fresh
    ORDER BY venue, asset, realized_funding_at_ms, observed_at_ms DESC
  ),
  realized AS (
    SELECT
      venue,
      asset,
      avg(realized_funding_rate_ppm)::bigint AS realized_average_ppm,
      count(*)::integer AS realized_samples_24h
    FROM realized_rows
    GROUP BY venue, asset
  ),
  history_lagged AS (
    SELECT
      f.venue,
      f.asset,
      f.observed_at_ms,
      f.source_status,
      f.source_fresh,
      f.observed_at_ms - lag(f.observed_at_ms) OVER (
        PARTITION BY f.venue, f.asset ORDER BY f.observed_at_ms
      ) AS gap_ms
    FROM funding_observations f
    JOIN current_rows c USING (venue, asset)
    WHERE f.observed_at_ms >= p_now_ms - 608400000
      AND f.observed_at_ms <= p_now_ms
  ),
  history AS (
    SELECT
      venue,
      asset,
      min(observed_at_ms) AS first_observed_at_ms,
      count(*) FILTER (
        WHERE source_status <> 'valid' OR NOT source_fresh
      ) AS bad_samples,
      COALESCE(max(gap_ms), 0) AS max_gap_ms
    FROM history_lagged
    GROUP BY venue, asset
  ),
  markets AS (
    SELECT
      c.*,
      COALESCE(r.realized_average_ppm, 0) AS realized_average_ppm,
      COALESCE(r.realized_samples_24h, 0) AS realized_samples_24h,
      (
        c.observed_at_ms - h.first_observed_at_ms >= 604800000
        AND h.bad_samples = 0
        AND h.max_gap_ms <= p_source_max_age_ms
        AND COALESCE(r.realized_samples_24h, 0) >= 24
      ) AS history_ready
    FROM current_rows c
    JOIN history h USING (venue, asset)
    LEFT JOIN realized r USING (venue, asset)
  ),
  oriented AS (
    SELECT
      high.scan_id,
      high.asset,
      high.instrument,
      high.event_id AS short_source_event_id,
      low.event_id AS long_source_event_id,
      high.venue AS short_venue,
      low.venue AS long_venue,
      high.observed_at_ms,
      high.source_status AS short_source_status,
      low.source_status AS long_source_status,
      high.source_fresh AS short_source_fresh,
      low.source_fresh AS long_source_fresh,
      high.depth_qualified AS short_depth_qualified,
      low.depth_qualified AS long_depth_qualified,
      high.margin_status AS short_margin_status,
      low.margin_status AS long_margin_status,
      high.maintenance_margin_ppm AS short_maintenance_margin_ppm,
      low.maintenance_margin_ppm AS long_maintenance_margin_ppm,
      high.perp_bid_price_usd_micros AS short_entry_price,
      high.perp_ask_price_usd_micros AS short_exit_price,
      low.perp_ask_price_usd_micros AS long_entry_price,
      low.perp_bid_price_usd_micros AS long_exit_price,
      high.perp_exit_depth_atoms AS short_depth,
      low.perp_exit_depth_atoms AS long_depth,
      high.mark_price_usd_micros AS short_mark,
      low.mark_price_usd_micros AS long_mark,
      high.realized_funding_at_ms AS short_realized_at_ms,
      low.realized_funding_at_ms AS long_realized_at_ms,
      high.realized_average_ppm AS short_realized_average_ppm,
      low.realized_average_ppm AS long_realized_average_ppm,
      high.realized_average_ppm
        - low.realized_average_ppm AS realized_spread_ppm,
      LEAST(
        high.realized_samples_24h,
        low.realized_samples_24h
      ) AS realized_samples_24h,
      high.history_ready AND low.history_ready AS history_ready
    FROM markets high
    JOIN markets low
      ON low.asset = high.asset
     AND (
       high.realized_average_ppm > low.realized_average_ppm
       OR (
         high.realized_average_ppm = low.realized_average_ppm
         AND high.venue < low.venue
       )
     )
  ),
  sized AS (
    SELECT
      o.*,
      trunc(
        p_position_notional_usd_micros::numeric * 1000000000
          / GREATEST(short_entry_price, long_entry_price)
      ) AS quantity_atoms
    FROM oriented o
  ),
  margined AS (
    SELECT
      s.*,
      ceil(
        quantity_atoms * short_mark / 1000000000
          * short_maintenance_margin_ppm / 1000000
      )::bigint AS short_maintenance_usd_micros,
      ceil(
        quantity_atoms * long_mark / 1000000000
          * long_maintenance_margin_ppm / 1000000
      )::bigint AS long_maintenance_usd_micros,
      trunc(quantity_atoms * short_mark / 1000000000)::bigint
        AS short_notional_usd_micros,
      trunc(quantity_atoms * long_mark / 1000000000)::bigint
        AS long_notional_usd_micros
    FROM sized s
    WHERE quantity_atoms > 0
  ),
  risked AS (
    SELECT
      m.*,
      CASE WHEN short_maintenance_usd_micros > 0
        THEN trunc(
          p_collateral_usd_micros::numeric * 1000000
            / short_maintenance_usd_micros
        )::bigint
        ELSE 0
      END AS short_margin_ratio_ppm,
      CASE WHEN long_maintenance_usd_micros > 0
        THEN trunc(
          p_collateral_usd_micros::numeric * 1000000
            / long_maintenance_usd_micros
        )::bigint
        ELSE 0
      END AS long_margin_ratio_ppm,
      CASE WHEN short_notional_usd_micros > 0
        THEN floor(
          (
            p_collateral_usd_micros
              - short_maintenance_usd_micros
          )::numeric * 10000 / short_notional_usd_micros
        )::bigint
        ELSE 0
      END AS short_liquidation_distance_bps,
      CASE WHEN long_notional_usd_micros > 0
        THEN floor(
          (
            p_collateral_usd_micros
              - long_maintenance_usd_micros
          )::numeric * 10000 / long_notional_usd_micros
        )::bigint
        ELSE 0
      END AS long_liquidation_distance_bps
    FROM margined m
  ),
  ranked AS (
    SELECT
      r.*,
      row_number() OVER (
        ORDER BY realized_spread_ppm DESC, asset, short_venue, long_venue
      ) AS pair_rank
    FROM risked r
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'rank', pair_rank,
        'scanId', scan_id,
        'asset', asset,
        'instrument', instrument,
        'shortSourceEventId', short_source_event_id,
        'longSourceEventId', long_source_event_id,
        'shortVenue', short_venue,
        'longVenue', long_venue,
        'observedAtMs', observed_at_ms::text,
        'shortRealizedAveragePpm', short_realized_average_ppm::text,
        'longRealizedAveragePpm', long_realized_average_ppm::text,
        'realizedSpreadPpmPerHour', realized_spread_ppm::text,
        'realizedSamples24h', realized_samples_24h,
        'gateThresholdPpm', v_threshold::text,
        'gateDistancePpm', (realized_spread_ppm - v_threshold)::text,
        'historyReady', history_ready,
        'shortDepthQualified', short_depth_qualified,
        'longDepthQualified', long_depth_qualified,
        'shortMarginStatus', short_margin_status,
        'longMarginStatus', long_margin_status,
        'shortMaintenanceMarginPpm',
          short_maintenance_margin_ppm::text,
        'longMaintenanceMarginPpm',
          long_maintenance_margin_ppm::text,
        'shortMarginRatioPpm', short_margin_ratio_ppm::text,
        'longMarginRatioPpm', long_margin_ratio_ppm::text,
        'shortLiquidationDistanceBps',
          short_liquidation_distance_bps::text,
        'longLiquidationDistanceBps',
          long_liquidation_distance_bps::text,
        'quantityAtoms', quantity_atoms::text,
        'shortEntryPriceUsdMicros', short_entry_price::text,
        'longEntryPriceUsdMicros', long_entry_price::text,
        'shortRealizedAtMs', short_realized_at_ms::text,
        'longRealizedAtMs', long_realized_at_ms::text,
        'eligible', (
          short_source_status = 'valid'
          AND long_source_status = 'valid'
          AND short_source_fresh
          AND long_source_fresh
          AND p_now_ms - observed_at_ms <= p_source_max_age_ms
          AND short_depth_qualified
          AND long_depth_qualified
          AND short_depth >= quantity_atoms
          AND long_depth >= quantity_atoms
          AND short_margin_status = 'valid'
          AND long_margin_status = 'valid'
          AND short_margin_ratio_ppm >= p_minimum_margin_ratio_ppm
          AND long_margin_ratio_ppm >= p_minimum_margin_ratio_ppm
          AND short_liquidation_distance_bps
            >= p_minimum_liquidation_distance_bps
          AND long_liquidation_distance_bps
            >= p_minimum_liquidation_distance_bps
          AND history_ready
          AND realized_spread_ppm >= v_threshold
        )
      )
      ORDER BY pair_rank
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM ranked;

  RETURN jsonb_build_object(
    'asOfMs', p_now_ms::text,
    'historyRequiredHours', '168',
    'minimumRealizedSamples24h', '24',
    'gateThresholdPpm', v_threshold::text,
    'items', v_items
  );
END;
$$;

CREATE FUNCTION run_cross_venue_paper_scan(
  p_scan_id text,
  p_now_ms bigint,
  p_source_max_age_ms bigint,
  p_position_notional_usd_micros bigint,
  p_cost_usd_micros bigint,
  p_risk_buffer_usd_micros bigint,
  p_hold_hours integer,
  p_collateral_usd_micros bigint,
  p_minimum_margin_ratio_ppm bigint,
  p_minimum_liquidation_distance_bps bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_leaderboard jsonb;
  v_top jsonb;
  v_portfolio record;
  v_position cross_venue_paper_positions%ROWTYPE;
  v_short funding_observations%ROWTYPE;
  v_long funding_observations%ROWTYPE;
  v_entries_paused boolean;
  v_control_ready boolean;
  v_has_position boolean;
  v_short_found boolean;
  v_long_found boolean;
  v_exit_executable boolean;
  v_margin_safe boolean;
  v_pair_viable boolean;
  v_eligible boolean;
  v_quantity numeric;
  v_amount bigint;
  v_short_pnl bigint;
  v_long_pnl bigint;
  v_divergence bigint;
  v_short_equity bigint;
  v_long_equity bigint;
  v_short_maintenance bigint;
  v_long_maintenance bigint;
  v_short_notional bigint;
  v_long_notional bigint;
  v_short_ratio bigint;
  v_long_ratio bigint;
  v_short_distance bigint;
  v_long_distance bigint;
  v_week_carry bigint;
  v_expected_funding bigint;
  v_net_carry bigint;
  v_action text;
  v_reason text;
  v_opened integer := 0;
  v_held integer := 0;
  v_closed integer := 0;
  v_blocked integer := 0;
BEGIN
  IF p_scan_id IS NULL OR p_scan_id = '' THEN
    RAISE EXCEPTION 'scan id is required';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM cross_venue_paper_decisions
    WHERE scan_id = p_scan_id
  ) THEN
    RETURN jsonb_build_object(
      'opened', 0,
      'held', 0,
      'closed', 0,
      'blocked', 0,
      'duplicate', true
    );
  END IF;

  v_leaderboard := cross_venue_funding_leaderboard(
    p_now_ms,
    p_source_max_age_ms,
    p_position_notional_usd_micros,
    p_cost_usd_micros,
    p_risk_buffer_usd_micros,
    p_hold_hours,
    p_collateral_usd_micros,
    p_minimum_margin_ratio_ppm,
    p_minimum_liquidation_distance_bps
  );
  SELECT value
  INTO v_top
  FROM jsonb_array_elements(v_leaderboard->'items')
  ORDER BY
    CASE WHEN (value->>'eligible')::boolean THEN 0 ELSE 1 END,
    (value->>'rank')::integer
  LIMIT 1;
  IF v_top IS NULL THEN
    RETURN jsonb_build_object(
      'opened', 0,
      'held', 0,
      'closed', 0,
      'blocked', 0,
      'duplicate', false
    );
  END IF;
  IF v_top->>'scanId' <> p_scan_id THEN
    RAISE EXCEPTION 'cross-venue scan is not the latest complete scan';
  END IF;

  SELECT pause_entries OR pause_all
  INTO v_entries_paused
  FROM control_state;
  v_expected_funding := trunc(
    p_position_notional_usd_micros::numeric
      * (v_top->>'realizedSpreadPpmPerHour')::numeric
      * p_hold_hours / 1000000
  )::bigint;
  v_net_carry :=
    v_expected_funding - p_cost_usd_micros - p_risk_buffer_usd_micros;

  FOR v_portfolio IN
    SELECT p.*, g.mode
    FROM portfolio_runs p
    JOIN comparison_groups g ON g.id = p.comparison_group_id
    WHERE p.variant = 'cross_venue_funding'
    ORDER BY p.id
  LOOP
    SELECT CASE
      WHEN v_portfolio.mode = 'independent' THEN true
      ELSE EXISTS (
        SELECT 1
        FROM portfolio_runs
        WHERE comparison_group_id = v_portfolio.comparison_group_id
          AND variant = 'sol_control'
          AND state = 'hedged'
      )
    END
    INTO v_control_ready;

    SELECT *
    INTO v_position
    FROM cross_venue_paper_positions
    WHERE portfolio_run_id = v_portfolio.id
      AND status IN ('open', 'exit_blocked');
    v_has_position := FOUND;
    v_action := 'gated';
    v_reason := 'cross_venue_gate_failed';
    v_divergence := 0;
    v_short_ratio := (v_top->>'shortMarginRatioPpm')::bigint;
    v_long_ratio := (v_top->>'longMarginRatioPpm')::bigint;
    v_short_distance :=
      (v_top->>'shortLiquidationDistanceBps')::bigint;
    v_long_distance :=
      (v_top->>'longLiquidationDistanceBps')::bigint;

    IF v_has_position THEN
      SELECT *
      INTO v_short
      FROM funding_observations
      WHERE scan_id = p_scan_id
        AND venue = v_position.short_venue
        AND asset = v_position.asset;
      v_short_found := FOUND;
      SELECT *
      INTO v_long
      FROM funding_observations
      WHERE scan_id = p_scan_id
        AND venue = v_position.long_venue
        AND asset = v_position.asset;
      v_long_found := FOUND;

      IF v_short_found
         AND v_short.source_status = 'valid'
         AND v_short.source_fresh
         AND v_short.realized_funding_at_ms
           > v_position.last_short_funding_at_ms
         AND v_short.realized_funding_at_ms > v_position.opened_at_ms THEN
        v_amount := trunc(
          v_position.quantity_atoms * v_short.mark_price_usd_micros
            / 1000000000
            * v_short.realized_funding_rate_ppm / 1000000
        )::bigint;
        INSERT INTO funding_payments (
          id, portfolio_run_id, venue_payment_id, effective_at_ms,
          position_quantity_atoms, raw_rate_atoms, normalized_rate_atoms,
          amount_atoms, usd_value_atoms, realization_status, source_event_id
        ) VALUES (
          v_position.id || ':short-funding:'
            || v_short.realized_funding_at_ms,
          v_portfolio.id,
          'cross-venue:' || v_position.id || ':' || v_short.venue || ':'
            || v_short.realized_funding_at_ms,
          v_short.realized_funding_at_ms,
          v_position.quantity_atoms::text,
          v_short.realized_funding_rate_ppm::text,
          v_short.realized_funding_rate_ppm::text,
          v_amount::text,
          v_amount::text,
          'realized',
          v_short.event_id
        );
        UPDATE cross_venue_paper_positions
        SET short_funding_usd_micros =
              short_funding_usd_micros + v_amount,
            last_short_funding_at_ms = v_short.realized_funding_at_ms
        WHERE id = v_position.id;
      END IF;

      IF v_long_found
         AND v_long.source_status = 'valid'
         AND v_long.source_fresh
         AND v_long.realized_funding_at_ms
           > v_position.last_long_funding_at_ms
         AND v_long.realized_funding_at_ms > v_position.opened_at_ms THEN
        v_amount := trunc(
          v_position.quantity_atoms * v_long.mark_price_usd_micros
            / 1000000000
            * -v_long.realized_funding_rate_ppm / 1000000
        )::bigint;
        INSERT INTO funding_payments (
          id, portfolio_run_id, venue_payment_id, effective_at_ms,
          position_quantity_atoms, raw_rate_atoms, normalized_rate_atoms,
          amount_atoms, usd_value_atoms, realization_status, source_event_id
        ) VALUES (
          v_position.id || ':long-funding:'
            || v_long.realized_funding_at_ms,
          v_portfolio.id,
          'cross-venue:' || v_position.id || ':' || v_long.venue || ':'
            || v_long.realized_funding_at_ms,
          v_long.realized_funding_at_ms,
          v_position.quantity_atoms::text,
          v_long.realized_funding_rate_ppm::text,
          (-v_long.realized_funding_rate_ppm)::text,
          v_amount::text,
          v_amount::text,
          'realized',
          v_long.event_id
        );
        UPDATE cross_venue_paper_positions
        SET long_funding_usd_micros =
              long_funding_usd_micros + v_amount,
            last_long_funding_at_ms = v_long.realized_funding_at_ms
        WHERE id = v_position.id;
      END IF;

      SELECT *
      INTO v_position
      FROM cross_venue_paper_positions
      WHERE id = v_position.id;

      v_exit_executable :=
        v_short_found
        AND v_long_found
        AND v_short.source_status = 'valid'
        AND v_long.source_status = 'valid'
        AND v_short.source_fresh
        AND v_long.source_fresh
        AND p_now_ms - v_short.observed_at_ms <= p_source_max_age_ms
        AND p_now_ms - v_long.observed_at_ms <= p_source_max_age_ms
        AND v_short.depth_qualified
        AND v_long.depth_qualified
        AND v_short.perp_exit_depth_atoms >= v_position.quantity_atoms
        AND v_long.perp_exit_depth_atoms >= v_position.quantity_atoms;

      IF v_short_found AND v_long_found THEN
        v_short_pnl := trunc(
          v_position.quantity_atoms
            * (
              v_position.entry_short_price_usd_micros
                - v_short.perp_ask_price_usd_micros
            ) / 1000000000
        )::bigint;
        v_long_pnl := trunc(
          v_position.quantity_atoms
            * (
              v_long.perp_bid_price_usd_micros
                - v_position.entry_long_price_usd_micros
            ) / 1000000000
        )::bigint;
        v_divergence := v_short_pnl + v_long_pnl;
        v_short_equity :=
          v_position.short_collateral_usd_micros
            + v_short_pnl + v_position.short_funding_usd_micros;
        v_long_equity :=
          v_position.long_collateral_usd_micros
            + v_long_pnl + v_position.long_funding_usd_micros;
        v_short_notional := trunc(
          v_position.quantity_atoms * v_short.mark_price_usd_micros
            / 1000000000
        )::bigint;
        v_long_notional := trunc(
          v_position.quantity_atoms * v_long.mark_price_usd_micros
            / 1000000000
        )::bigint;
        v_short_maintenance := ceil(
          v_short_notional::numeric
            * v_short.maintenance_margin_ppm / 1000000
        )::bigint;
        v_long_maintenance := ceil(
          v_long_notional::numeric
            * v_long.maintenance_margin_ppm / 1000000
        )::bigint;
        v_short_ratio := CASE WHEN v_short_maintenance > 0
          THEN trunc(
            v_short_equity::numeric * 1000000 / v_short_maintenance
          )::bigint
          ELSE 0
        END;
        v_long_ratio := CASE WHEN v_long_maintenance > 0
          THEN trunc(
            v_long_equity::numeric * 1000000 / v_long_maintenance
          )::bigint
          ELSE 0
        END;
        v_short_distance := CASE WHEN v_short_notional > 0
          THEN floor(
            (v_short_equity - v_short_maintenance)::numeric
              * 10000 / v_short_notional
          )::bigint
          ELSE 0
        END;
        v_long_distance := CASE WHEN v_long_notional > 0
          THEN floor(
            (v_long_equity - v_long_maintenance)::numeric
              * 10000 / v_long_notional
          )::bigint
          ELSE 0
        END;
      ELSE
        v_short_equity := v_position.short_equity_usd_micros;
        v_long_equity := v_position.long_equity_usd_micros;
        v_short_maintenance :=
          v_position.short_maintenance_usd_micros;
        v_long_maintenance :=
          v_position.long_maintenance_usd_micros;
      END IF;

      v_margin_safe :=
        v_short_found
        AND v_long_found
        AND v_short.margin_status = 'valid'
        AND v_long.margin_status = 'valid'
        AND v_short_ratio >= p_minimum_margin_ratio_ppm
        AND v_long_ratio >= p_minimum_margin_ratio_ppm
        AND v_short_distance >= p_minimum_liquidation_distance_bps
        AND v_long_distance >= p_minimum_liquidation_distance_bps;
      v_pair_viable :=
        (v_top->>'eligible')::boolean
        AND v_top->>'asset' = v_position.asset
        AND v_top->>'shortVenue' = v_position.short_venue
        AND v_top->>'longVenue' = v_position.long_venue;
      v_week_carry := trunc(
        p_position_notional_usd_micros::numeric
          * GREATEST(
            (v_top->>'realizedSpreadPpmPerHour')::numeric,
            0
          )
          * 168 / 1000000
      )::bigint;

      IF NOT v_margin_safe
         OR NOT v_pair_viable
         OR -v_divergence > v_week_carry THEN
        IF v_exit_executable THEN
          UPDATE cross_venue_paper_positions
          SET status = 'closed',
              closed_at_ms = p_now_ms,
              latest_scan_id = p_scan_id,
              latest_short_source_event_id = v_short.event_id,
              latest_long_source_event_id = v_long.event_id,
              exit_short_price_usd_micros =
                v_short.perp_ask_price_usd_micros,
              exit_long_price_usd_micros =
                v_long.perp_bid_price_usd_micros,
              short_equity_usd_micros = v_short_equity,
              long_equity_usd_micros = v_long_equity,
              short_maintenance_margin_ppm =
                v_short.maintenance_margin_ppm,
              long_maintenance_margin_ppm =
                v_long.maintenance_margin_ppm,
              short_maintenance_usd_micros = v_short_maintenance,
              long_maintenance_usd_micros = v_long_maintenance,
              short_margin_ratio_ppm = v_short_ratio,
              long_margin_ratio_ppm = v_long_ratio,
              short_liquidation_distance_bps = v_short_distance,
              long_liquidation_distance_bps = v_long_distance,
              realized_basis_usd_micros = v_divergence,
              updated_at = now()
          WHERE id = v_position.id;
          UPDATE portfolio_runs
          SET state = 'idle', state_version = state_version + 1
          WHERE id = v_portfolio.id;
          UPDATE risk_events
          SET resolved_at = now()
          WHERE portfolio_run_id = v_portfolio.id
            AND code = 'cross_venue_one_leg_uncertain'
            AND resolved_at IS NULL;
          v_action := 'close';
          v_reason := CASE
            WHEN NOT v_margin_safe THEN 'venue_margin_breaker'
            WHEN -v_divergence > v_week_carry
              THEN 'mark_divergence_breaker'
            ELSE 'funding_spread_closed'
          END;
          v_closed := v_closed + 1;
        ELSE
          UPDATE cross_venue_paper_positions
          SET status = 'exit_blocked',
              latest_scan_id = p_scan_id,
              updated_at = now()
          WHERE id = v_position.id;
          UPDATE portfolio_runs
          SET state = 'emergency_flatten'
          WHERE id = v_portfolio.id;
          INSERT INTO risk_events (
            id, strategy_run_id, portfolio_run_id, severity, code, message,
            observed_value, limit_value, action_taken
          ) VALUES (
            v_portfolio.id || ':' || p_scan_id || ':one-leg-uncertain',
            v_portfolio.strategy_run_id,
            v_portfolio.id,
            'critical',
            'cross_venue_one_leg_uncertain',
            'A cross-venue leg cannot be priced and exited safely',
            jsonb_build_object(
              'shortVenueObserved', v_short_found,
              'longVenueObserved', v_long_found,
              'shortExitExecutable',
                v_short_found AND COALESCE(v_short.depth_qualified, false),
              'longExitExecutable',
                v_long_found AND COALESCE(v_long.depth_qualified, false)
            ),
            jsonb_build_object('bothLegsExecutable', true),
            'emergency_flatten'
          );
          v_action := 'exit_blocked';
          v_reason := 'one_leg_exit_unavailable';
          v_blocked := v_blocked + 1;
        END IF;
      ELSE
        UPDATE cross_venue_paper_positions
        SET status = 'open',
            latest_scan_id = p_scan_id,
            latest_short_source_event_id = v_short.event_id,
            latest_long_source_event_id = v_long.event_id,
            short_equity_usd_micros = v_short_equity,
            long_equity_usd_micros = v_long_equity,
            short_maintenance_margin_ppm =
              v_short.maintenance_margin_ppm,
            long_maintenance_margin_ppm =
              v_long.maintenance_margin_ppm,
            short_maintenance_usd_micros = v_short_maintenance,
            long_maintenance_usd_micros = v_long_maintenance,
            short_margin_ratio_ppm = v_short_ratio,
            long_margin_ratio_ppm = v_long_ratio,
            short_liquidation_distance_bps = v_short_distance,
            long_liquidation_distance_bps = v_long_distance,
            updated_at = now()
        WHERE id = v_position.id;
        v_action := 'hold';
        v_reason := 'cross_venue_held';
        v_held := v_held + 1;
      END IF;
    END IF;

    v_eligible :=
      NOT v_has_position
      AND (v_top->>'eligible')::boolean
      AND v_control_ready
      AND NOT v_entries_paused;
    IF NOT v_has_position AND v_eligible THEN
      v_quantity := (v_top->>'quantityAtoms')::numeric;
      INSERT INTO cross_venue_paper_positions (
        id, portfolio_run_id, status, asset, instrument,
        short_venue, long_venue, quantity_atoms,
        entry_short_price_usd_micros, entry_long_price_usd_micros,
        short_collateral_usd_micros, long_collateral_usd_micros,
        short_maintenance_margin_ppm, long_maintenance_margin_ppm,
        short_equity_usd_micros, long_equity_usd_micros,
        short_maintenance_usd_micros, long_maintenance_usd_micros,
        short_margin_ratio_ppm, long_margin_ratio_ppm,
        short_liquidation_distance_bps, long_liquidation_distance_bps,
        last_short_funding_at_ms, last_long_funding_at_ms,
        opened_at_ms, opened_scan_id, latest_scan_id,
        opened_short_source_event_id, opened_long_source_event_id,
        latest_short_source_event_id, latest_long_source_event_id
      ) VALUES (
        v_portfolio.id || ':' || p_scan_id,
        v_portfolio.id,
        'open',
        v_top->>'asset',
        v_top->>'instrument',
        v_top->>'shortVenue',
        v_top->>'longVenue',
        v_quantity,
        (v_top->>'shortEntryPriceUsdMicros')::bigint,
        (v_top->>'longEntryPriceUsdMicros')::bigint,
        p_collateral_usd_micros,
        p_collateral_usd_micros,
        (v_top->>'shortMaintenanceMarginPpm')::bigint,
        (v_top->>'longMaintenanceMarginPpm')::bigint,
        p_collateral_usd_micros,
        p_collateral_usd_micros,
        ceil(
          v_quantity
            * (
              SELECT mark_price_usd_micros
              FROM funding_observations
              WHERE event_id = v_top->>'shortSourceEventId'
            )
            / 1000000000
            * (v_top->>'shortMaintenanceMarginPpm')::numeric
            / 1000000
        )::bigint,
        ceil(
          v_quantity
            * (
              SELECT mark_price_usd_micros
              FROM funding_observations
              WHERE event_id = v_top->>'longSourceEventId'
            )
            / 1000000000
            * (v_top->>'longMaintenanceMarginPpm')::numeric
            / 1000000
        )::bigint,
        (v_top->>'shortMarginRatioPpm')::bigint,
        (v_top->>'longMarginRatioPpm')::bigint,
        (v_top->>'shortLiquidationDistanceBps')::bigint,
        (v_top->>'longLiquidationDistanceBps')::bigint,
        (v_top->>'shortRealizedAtMs')::bigint,
        (v_top->>'longRealizedAtMs')::bigint,
        p_now_ms,
        p_scan_id,
        p_scan_id,
        v_top->>'shortSourceEventId',
        v_top->>'longSourceEventId',
        v_top->>'shortSourceEventId',
        v_top->>'longSourceEventId'
      );
      UPDATE portfolio_runs
      SET state = 'hedged', state_version = state_version + 1
      WHERE id = v_portfolio.id;

      INSERT INTO ledger_batches (
        id, portfolio_run_id, event_type, event_id, batch_hash
      )
      SELECT
        v_portfolio.id || ':' || p_scan_id || ':cost',
        v_portfolio.id,
        'paper_cross_venue_cost',
        p_scan_id,
        raw_payload_hash
      FROM normalized_events
      WHERE id = v_top->>'shortSourceEventId';
      IF p_cost_usd_micros > 0 THEN
        INSERT INTO ledger_entries (
          ledger_batch_id, account_debit, account_credit, asset,
          amount_atoms, usd_value_atoms, price_reference_id
        ) VALUES (
          v_portfolio.id || ':' || p_scan_id || ':cost',
          'trading_fees',
          'paper_cash',
          'USDC',
          p_cost_usd_micros::text,
          p_cost_usd_micros::text,
          v_top->>'shortSourceEventId'
        );
      END IF;
      v_action := 'open';
      v_reason := 'cross_venue_opened';
      v_opened := v_opened + 1;
    ELSIF NOT v_has_position THEN
      v_action := 'gated';
      v_reason := CASE
        WHEN v_entries_paused THEN 'entries_paused'
        WHEN NOT v_control_ready THEN 'control_not_hedged'
        WHEN NOT (v_top->>'historyReady')::boolean
          THEN 'realized_funding_history_warming'
        WHEN v_top->>'shortMarginStatus' <> 'valid'
          OR v_top->>'longMarginStatus' <> 'valid'
          THEN 'venue_margin_unavailable'
        WHEN NOT (v_top->>'shortDepthQualified')::boolean
          OR NOT (v_top->>'longDepthQualified')::boolean
          THEN 'executable_depth_missing'
        WHEN (v_top->>'shortMarginRatioPpm')::bigint
          < p_minimum_margin_ratio_ppm
          OR (v_top->>'longMarginRatioPpm')::bigint
            < p_minimum_margin_ratio_ppm
          OR (v_top->>'shortLiquidationDistanceBps')::bigint
            < p_minimum_liquidation_distance_bps
          OR (v_top->>'longLiquidationDistanceBps')::bigint
            < p_minimum_liquidation_distance_bps
          THEN 'venue_margin_gate_failed'
        ELSE 'realized_funding_spread_below_cost'
      END;
    END IF;

    INSERT INTO cross_venue_paper_decisions (
      id, scan_id, portfolio_run_id,
      short_source_event_id, long_source_event_id,
      asset, short_venue, long_venue, rank,
      short_realized_average_ppm, long_realized_average_ppm,
      realized_spread_ppm_per_hour, gate_distance_ppm,
      expected_funding_usd_micros, net_carry_usd_micros,
      short_margin_ratio_ppm, long_margin_ratio_ppm,
      short_liquidation_distance_bps, long_liquidation_distance_bps,
      mark_divergence_usd_micros, eligible, action, reason_code
    ) VALUES (
      p_scan_id || ':' || v_portfolio.id,
      p_scan_id,
      v_portfolio.id,
      v_top->>'shortSourceEventId',
      v_top->>'longSourceEventId',
      v_top->>'asset',
      v_top->>'shortVenue',
      v_top->>'longVenue',
      (v_top->>'rank')::integer,
      (v_top->>'shortRealizedAveragePpm')::bigint,
      (v_top->>'longRealizedAveragePpm')::bigint,
      (v_top->>'realizedSpreadPpmPerHour')::bigint,
      (v_top->>'gateDistancePpm')::bigint,
      v_expected_funding,
      v_net_carry,
      v_short_ratio,
      v_long_ratio,
      v_short_distance,
      v_long_distance,
      v_divergence,
      CASE WHEN v_action = 'open'
        THEN true
        ELSE v_action = 'hold'
      END,
      v_action,
      v_reason
    );
  END LOOP;

  RETURN jsonb_build_object(
    'opened', v_opened,
    'held', v_held,
    'closed', v_closed,
    'blocked', v_blocked,
    'duplicate', false
  );
END;
$$;

INSERT INTO schema_meta(version) VALUES (36);

COMMIT;
