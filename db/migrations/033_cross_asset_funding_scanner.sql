BEGIN;

ALTER TYPE strategy_variant ADD VALUE IF NOT EXISTS 'cross_asset_funding';

CREATE TABLE funding_observations (
  event_id text PRIMARY KEY REFERENCES normalized_events(id),
  scan_id text NOT NULL,
  scan_index integer NOT NULL CHECK (scan_index >= 0),
  scan_size integer NOT NULL CHECK (scan_size > 0 AND scan_index < scan_size),
  venue text NOT NULL,
  asset text NOT NULL,
  instrument text NOT NULL,
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  source_observed_at_ms bigint NOT NULL CHECK (source_observed_at_ms >= 0),
  source_status text NOT NULL CHECK (source_status IN ('valid', 'invalid')),
  source_fresh boolean NOT NULL,
  funding_rate_ppm_per_hour bigint NOT NULL,
  realized_funding_rate_ppm bigint NOT NULL,
  realized_funding_at_ms bigint NOT NULL CHECK (realized_funding_at_ms >= 0),
  mark_price_usd_micros bigint NOT NULL CHECK (mark_price_usd_micros >= 0),
  open_interest_usd_micros bigint NOT NULL CHECK (open_interest_usd_micros >= 0),
  spot_bid_price_usd_micros bigint NOT NULL CHECK (spot_bid_price_usd_micros >= 0),
  spot_ask_price_usd_micros bigint NOT NULL CHECK (spot_ask_price_usd_micros >= 0),
  perp_bid_price_usd_micros bigint NOT NULL CHECK (perp_bid_price_usd_micros >= 0),
  perp_ask_price_usd_micros bigint NOT NULL CHECK (perp_ask_price_usd_micros >= 0),
  spot_exit_depth_atoms numeric(78, 0) NOT NULL CHECK (spot_exit_depth_atoms >= 0),
  perp_exit_depth_atoms numeric(78, 0) NOT NULL CHECK (perp_exit_depth_atoms >= 0),
  depth_qualified boolean NOT NULL,
  funding_ema_ppm bigint NOT NULL,
  funding_24h_average_ppm bigint NOT NULL,
  samples_24h integer NOT NULL CHECK (samples_24h >= 0),
  UNIQUE (scan_id, scan_index),
  UNIQUE (scan_id, venue, asset)
);
CREATE INDEX funding_observations_asset_time
  ON funding_observations(venue, asset, observed_at_ms DESC);
CREATE INDEX funding_observations_scan
  ON funding_observations(scan_id, scan_size);

CREATE TABLE cross_asset_paper_positions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  venue text NOT NULL,
  asset text NOT NULL,
  instrument text NOT NULL,
  status text NOT NULL CHECK (status IN ('open', 'exit_blocked', 'closed')),
  quantity_atoms numeric(78, 0) NOT NULL CHECK (quantity_atoms > 0),
  entry_spot_price_usd_micros bigint NOT NULL CHECK (entry_spot_price_usd_micros > 0),
  entry_perp_price_usd_micros bigint NOT NULL CHECK (entry_perp_price_usd_micros > 0),
  exit_spot_price_usd_micros bigint CHECK (exit_spot_price_usd_micros > 0),
  exit_perp_price_usd_micros bigint CHECK (exit_perp_price_usd_micros > 0),
  opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= 0),
  closed_at_ms bigint CHECK (closed_at_ms >= opened_at_ms),
  opened_source_event_id text NOT NULL REFERENCES normalized_events(id),
  latest_source_event_id text NOT NULL REFERENCES normalized_events(id),
  realized_basis_usd_micros bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX cross_asset_paper_one_open_per_venue
  ON cross_asset_paper_positions(portfolio_run_id, venue)
  WHERE status IN ('open', 'exit_blocked');

CREATE TABLE cross_asset_paper_decisions (
  id text PRIMARY KEY,
  scan_id text NOT NULL,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  venue text NOT NULL,
  asset text NOT NULL,
  rank integer NOT NULL CHECK (rank > 0),
  funding_24h_average_ppm bigint NOT NULL,
  funding_ema_ppm bigint NOT NULL,
  gate_distance_ppm bigint NOT NULL,
  expected_funding_usd_micros bigint NOT NULL,
  net_carry_usd_micros bigint NOT NULL,
  eligible boolean NOT NULL,
  action text NOT NULL CHECK (
    action IN ('open', 'hold', 'switch', 'close', 'gated', 'exit_blocked')
  ),
  reason_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (scan_id, portfolio_run_id, venue)
);

CREATE FUNCTION record_funding_observation(
  p_event jsonb,
  p_source_max_age_ms bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload jsonb := p_event->'payload';
  v_inserted integer;
  v_matches boolean;
  v_source_fresh boolean;
  v_previous_ema bigint;
  v_ema bigint;
  v_average bigint;
  v_samples integer;
  v_scan_complete boolean;
  v_history jsonb;
  v_history_at bigint;
  v_history_rate bigint;
  v_previous_history_at bigint := -1;
BEGIN
  IF p_source_max_age_ms <= 0
     OR p_event->>'eventType' <> 'FundingObservation'
     OR p_event->>'schemaVersion' <> '1'
     OR p_event->>'eventId' IS NULL
     OR p_event->>'source' IS NULL
     OR p_event->>'observedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR p_event->>'sourceSlot' !~ '^(0|[1-9][0-9]*)$'
     OR p_event->>'sourceSequence' IS NULL
     OR p_event->>'idempotencyKey' IS NULL
     OR p_event->>'rawPayloadHash' !~ '^[0-9a-f]{64}$'
     OR v_payload->>'scanId' IS NULL
     OR v_payload->>'scanIndex' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'scanSize' !~ '^[1-9][0-9]*$'
     OR (v_payload->>'scanIndex')::integer >= (v_payload->>'scanSize')::integer
     OR v_payload->>'venue' !~ '^[a-z][a-z0-9_-]*$'
     OR v_payload->>'asset' !~ '^[A-Z0-9]+$'
     OR v_payload->>'instrument' !~ '^[A-Z0-9]+-PERP$'
     OR v_payload->>'sourceObservedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'sourceStatus' NOT IN ('valid', 'invalid')
     OR v_payload->>'fundingRatePpmPerHour' !~ '^-?(0|[1-9][0-9]*)$'
     OR abs((v_payload->>'fundingRatePpmPerHour')::numeric) > 1000000
     OR v_payload->>'realizedFundingRatePpm' !~ '^-?(0|[1-9][0-9]*)$'
     OR abs((v_payload->>'realizedFundingRatePpm')::numeric) > 1000000
     OR v_payload->>'realizedFundingAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR (v_payload->>'realizedFundingAtMs')::numeric
       > (p_event->>'observedAtMs')::numeric
     OR v_payload->>'markPriceUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'openInterestUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'spotBidPriceUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'spotAskPriceUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'perpBidPriceUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'perpAskPriceUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'spotExitDepthAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'perpExitDepthAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR jsonb_typeof(v_payload->'depthQualified') <> 'boolean'
     OR (
       (v_payload->>'sourceStatus') = 'valid'
       AND (v_payload->>'markPriceUsdMicros')::numeric <= 0
     )
     OR (
       (v_payload->>'depthQualified')::boolean
       AND (
         (v_payload->>'sourceStatus') <> 'valid'
         OR (v_payload->>'spotBidPriceUsdMicros')::numeric <= 0
         OR (v_payload->>'spotAskPriceUsdMicros')::numeric <= 0
         OR (v_payload->>'perpBidPriceUsdMicros')::numeric <= 0
         OR (v_payload->>'perpAskPriceUsdMicros')::numeric <= 0
         OR (v_payload->>'spotExitDepthAtoms')::numeric <= 0
         OR (v_payload->>'perpExitDepthAtoms')::numeric <= 0
       )
     ) THEN
    RAISE EXCEPTION 'invalid funding observation contract';
  END IF;

  v_source_fresh :=
    (v_payload->>'sourceStatus') = 'valid'
    AND (v_payload->>'sourceObservedAtMs')::bigint <= (p_event->>'observedAtMs')::bigint
    AND (p_event->>'observedAtMs')::bigint
      - (v_payload->>'sourceObservedAtMs')::bigint <= p_source_max_age_ms;

  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    p_event->>'eventId',
    1,
    'FundingObservation',
    p_event->>'source',
    (p_event->>'observedAtMs')::bigint,
    (p_event->>'sourceSlot')::bigint,
    p_event->>'sourceSequence',
    p_event->>'idempotencyKey',
    p_event->>'rawPayloadHash',
    p_event
  )
  ON CONFLICT (idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT id = p_event->>'eventId'
      AND raw_payload_hash = p_event->>'rawPayloadHash'
      AND canonical_payload = p_event
    INTO v_matches
    FROM normalized_events
    WHERE idempotency_key = p_event->>'idempotencyKey';

    IF COALESCE(v_matches, false) = false THEN
      RAISE EXCEPTION 'idempotency key reused for a different event';
    END IF;

    SELECT count(*) = max(scan_size)
    INTO v_scan_complete
    FROM funding_observations
    WHERE scan_id = v_payload->>'scanId';
    RETURN jsonb_build_object('inserted', false, 'scanComplete', v_scan_complete);
  END IF;

  IF v_payload ? 'fundingHistory' THEN
    IF jsonb_typeof(v_payload->'fundingHistory') <> 'array'
       OR jsonb_array_length(v_payload->'fundingHistory') = 0 THEN
      RAISE EXCEPTION 'invalid funding history contract';
    END IF;
    FOR v_history IN
      SELECT value FROM jsonb_array_elements(v_payload->'fundingHistory')
    LOOP
      IF jsonb_typeof(v_history) <> 'object'
         OR v_history->>'observedAtMs' !~ '^(0|[1-9][0-9]*)$'
         OR v_history->>'ratePpm' !~ '^-?(0|[1-9][0-9]*)$'
         OR abs((v_history->>'ratePpm')::numeric) > 1000000 THEN
        RAISE EXCEPTION 'invalid funding history contract';
      END IF;
      v_history_at := (v_history->>'observedAtMs')::bigint;
      v_history_rate := (v_history->>'ratePpm')::bigint;
      IF v_history_at <= v_previous_history_at
         OR v_history_at > (p_event->>'observedAtMs')::bigint THEN
        RAISE EXCEPTION 'invalid funding history contract';
      END IF;
      v_previous_history_at := v_history_at;

      IF v_history_at < (p_event->>'observedAtMs')::bigint
         AND v_payload->>'sourceStatus' = 'valid'
         AND NOT EXISTS (
           SELECT 1
           FROM funding_observations
           WHERE venue = v_payload->>'venue'
             AND asset = v_payload->>'asset'
             AND observed_at_ms = v_history_at
         ) THEN
        INSERT INTO normalized_events (
          id, schema_version, event_type, source, observed_at_ms, source_slot,
          source_sequence, idempotency_key, raw_payload_hash, canonical_payload
        ) VALUES (
          p_event->>'eventId' || ':history:' || v_history_at,
          1,
          'FundingObservationHistory',
          p_event->>'source' || ':history:' || v_history_at,
          v_history_at,
          v_history_at,
          p_event->>'sourceSequence' || ':history:' || v_history_at,
          p_event->>'idempotencyKey' || ':history:' || v_history_at,
          p_event->>'rawPayloadHash',
          jsonb_build_object(
            'parentEventId', p_event->>'eventId',
            'venue', v_payload->>'venue',
            'asset', v_payload->>'asset',
            'sample', v_history
          )
        )
        ON CONFLICT (idempotency_key) DO NOTHING;

        INSERT INTO funding_observations (
          event_id, scan_id, scan_index, scan_size, venue, asset, instrument,
          observed_at_ms, source_observed_at_ms, source_status, source_fresh,
          funding_rate_ppm_per_hour, realized_funding_rate_ppm,
          realized_funding_at_ms, mark_price_usd_micros,
          open_interest_usd_micros, spot_bid_price_usd_micros,
          spot_ask_price_usd_micros, perp_bid_price_usd_micros,
          perp_ask_price_usd_micros, spot_exit_depth_atoms,
          perp_exit_depth_atoms, depth_qualified, funding_ema_ppm,
          funding_24h_average_ppm, samples_24h
        ) VALUES (
          p_event->>'eventId' || ':history:' || v_history_at,
          p_event->>'eventId' || ':history:' || v_history_at,
          0,
          1,
          v_payload->>'venue',
          v_payload->>'asset',
          v_payload->>'instrument',
          v_history_at,
          v_history_at,
          'valid',
          true,
          v_history_rate,
          v_history_rate,
          v_history_at,
          (v_payload->>'markPriceUsdMicros')::bigint,
          (v_payload->>'openInterestUsdMicros')::bigint,
          0,
          0,
          (v_payload->>'perpBidPriceUsdMicros')::bigint,
          (v_payload->>'perpAskPriceUsdMicros')::bigint,
          0,
          0,
          false,
          v_history_rate,
          v_history_rate,
          1
        )
        ON CONFLICT (event_id) DO NOTHING;
      END IF;
    END LOOP;
  END IF;

  SELECT funding_ema_ppm
  INTO v_previous_ema
  FROM funding_observations
  WHERE venue = v_payload->>'venue'
    AND asset = v_payload->>'asset'
    AND source_fresh
    AND source_status = 'valid'
  ORDER BY observed_at_ms DESC
  LIMIT 1;

  v_ema := CASE
    WHEN NOT v_source_fresh THEN COALESCE(v_previous_ema, 0)
    WHEN v_previous_ema IS NULL
      THEN (v_payload->>'fundingRatePpmPerHour')::bigint
    ELSE (
      ((v_payload->>'fundingRatePpmPerHour')::numeric * 2
        + v_previous_ema::numeric * 23) / 25
    )::bigint
  END;

  INSERT INTO funding_observations (
    event_id, scan_id, scan_index, scan_size, venue, asset, instrument,
    observed_at_ms, source_observed_at_ms, source_status, source_fresh,
    funding_rate_ppm_per_hour, realized_funding_rate_ppm,
    realized_funding_at_ms, mark_price_usd_micros,
    open_interest_usd_micros, spot_bid_price_usd_micros,
    spot_ask_price_usd_micros, perp_bid_price_usd_micros,
    perp_ask_price_usd_micros, spot_exit_depth_atoms,
    perp_exit_depth_atoms, depth_qualified, funding_ema_ppm,
    funding_24h_average_ppm, samples_24h
  ) VALUES (
    p_event->>'eventId',
    v_payload->>'scanId',
    (v_payload->>'scanIndex')::integer,
    (v_payload->>'scanSize')::integer,
    v_payload->>'venue',
    v_payload->>'asset',
    v_payload->>'instrument',
    (p_event->>'observedAtMs')::bigint,
    (v_payload->>'sourceObservedAtMs')::bigint,
    v_payload->>'sourceStatus',
    v_source_fresh,
    (v_payload->>'fundingRatePpmPerHour')::bigint,
    (v_payload->>'realizedFundingRatePpm')::bigint,
    (v_payload->>'realizedFundingAtMs')::bigint,
    (v_payload->>'markPriceUsdMicros')::bigint,
    (v_payload->>'openInterestUsdMicros')::bigint,
    (v_payload->>'spotBidPriceUsdMicros')::bigint,
    (v_payload->>'spotAskPriceUsdMicros')::bigint,
    (v_payload->>'perpBidPriceUsdMicros')::bigint,
    (v_payload->>'perpAskPriceUsdMicros')::bigint,
    (v_payload->>'spotExitDepthAtoms')::numeric,
    (v_payload->>'perpExitDepthAtoms')::numeric,
    (v_payload->>'depthQualified')::boolean,
    v_ema,
    0,
    0
  );

  SELECT
    COALESCE(avg(funding_rate_ppm_per_hour)::bigint, 0),
    count(*)::integer
  INTO v_average, v_samples
  FROM funding_observations
  WHERE venue = v_payload->>'venue'
    AND asset = v_payload->>'asset'
    AND source_fresh
    AND source_status = 'valid'
    AND observed_at_ms > (p_event->>'observedAtMs')::bigint - 86400000
    AND observed_at_ms <= (p_event->>'observedAtMs')::bigint;

  UPDATE funding_observations
  SET funding_24h_average_ppm = v_average,
      samples_24h = v_samples
  WHERE event_id = p_event->>'eventId';

  SELECT count(*) = max(scan_size)
  INTO v_scan_complete
  FROM funding_observations
  WHERE scan_id = v_payload->>'scanId';

  RETURN jsonb_build_object('inserted', true, 'scanComplete', v_scan_complete);
END;
$$;

CREATE FUNCTION funding_leaderboard(
  p_now_ms bigint,
  p_source_max_age_ms bigint,
  p_position_notional_usd_micros bigint,
  p_cost_usd_micros bigint,
  p_risk_buffer_usd_micros bigint,
  p_hold_hours integer
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
     OR p_hold_hours <= 0 THEN
    RAISE EXCEPTION 'invalid funding leaderboard inputs';
  END IF;

  v_threshold := ceil(
    ((p_cost_usd_micros + p_risk_buffer_usd_micros)::numeric * 1000000)
      / (p_position_notional_usd_micros::numeric * p_hold_hours)
  )::bigint;

  WITH completed AS (
    SELECT scan_id
    FROM funding_observations
    GROUP BY scan_id
    HAVING count(*) = max(scan_size)
  ),
  latest AS (
    SELECT DISTINCT ON (f.venue, f.asset) f.*
    FROM funding_observations f
    JOIN completed c USING (scan_id)
    WHERE f.observed_at_ms <= p_now_ms
    ORDER BY f.venue, f.asset, f.observed_at_ms DESC
  ),
  history_rows AS (
    SELECT
      f.*,
      f.observed_at_ms
        - lag(f.observed_at_ms) OVER (
          PARTITION BY f.venue, f.asset ORDER BY f.observed_at_ms
        ) AS gap_ms
    FROM funding_observations f
    JOIN latest l USING (venue, asset)
    WHERE f.observed_at_ms >= l.observed_at_ms - 608400000
      AND f.observed_at_ms <= l.observed_at_ms
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
    FROM history_rows
    GROUP BY venue, asset
  ),
  ranked AS (
    SELECT
      l.*,
      row_number() OVER (
        ORDER BY l.funding_24h_average_ppm DESC, l.venue, l.asset
      ) AS funding_rank,
      round(
        percent_rank() OVER (
          ORDER BY l.funding_24h_average_ppm
        ) * 1000000
      )::bigint AS percentile_ppm,
      (
        l.observed_at_ms - h.first_observed_at_ms >= 604800000
        AND h.bad_samples = 0
        AND h.max_gap_ms <= p_source_max_age_ms
        AND l.samples_24h >= 24
      ) AS history_ready
    FROM latest l
    JOIN history h USING (venue, asset)
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'rank', funding_rank,
        'venue', venue,
        'asset', asset,
        'instrument', instrument,
        'observedAtMs', observed_at_ms::text,
        'fundingRatePpmPerHour', funding_rate_ppm_per_hour::text,
        'funding24hAveragePpm', funding_24h_average_ppm::text,
        'fundingEmaPpm', funding_ema_ppm::text,
        'percentilePpm', percentile_ppm::text,
        'gateThresholdPpm', v_threshold::text,
        'gateDistancePpm', (funding_24h_average_ppm - v_threshold)::text,
        'samples24h', samples_24h,
        'historyReady', history_ready,
        'depthQualified', depth_qualified,
        'eligible', (
          source_status = 'valid'
          AND source_fresh
          AND p_now_ms - observed_at_ms <= p_source_max_age_ms
          AND depth_qualified
          AND history_ready
          AND funding_24h_average_ppm >= v_threshold
        )
      )
      ORDER BY funding_rank
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM ranked;

  RETURN jsonb_build_object(
    'asOfMs', p_now_ms::text,
    'historyRequiredHours', '168',
    'minimumSamples24h', '24',
    'gateThresholdPpm', v_threshold::text,
    'items', v_items
  );
END;
$$;

CREATE FUNCTION run_cross_asset_paper_scan(
  p_scan_id text,
  p_now_ms bigint,
  p_source_max_age_ms bigint,
  p_position_notional_usd_micros bigint,
  p_cost_usd_micros bigint,
  p_risk_buffer_usd_micros bigint,
  p_hold_hours integer
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_board jsonb;
  v_portfolio record;
  v_venue record;
  v_top jsonb;
  v_top_observation funding_observations%ROWTYPE;
  v_current funding_observations%ROWTYPE;
  v_position cross_asset_paper_positions%ROWTYPE;
  v_has_position boolean;
  v_has_current boolean;
  v_control_ready boolean;
  v_candidate_eligible boolean;
  v_entries_paused boolean;
  v_action text;
  v_reason text;
  v_quantity numeric(78, 0);
  v_basis bigint;
  v_amount bigint;
  v_payment_id text;
  v_opened integer := 0;
  v_held integer := 0;
  v_closed integer := 0;
  v_blocked integer := 0;
BEGIN
  IF p_scan_id IS NULL
     OR p_position_notional_usd_micros <= 0
     OR p_cost_usd_micros < 0 THEN
    RAISE EXCEPTION 'invalid cross-asset paper inputs';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM funding_observations
    WHERE scan_id = p_scan_id
    GROUP BY scan_id
    HAVING count(*) = max(scan_size)
  ) THEN
    RAISE EXCEPTION 'funding scan is incomplete';
  END IF;
  IF EXISTS (
    SELECT 1 FROM cross_asset_paper_decisions WHERE scan_id = p_scan_id
  ) THEN
    RETURN jsonb_build_object(
      'opened', 0, 'held', 0, 'closed', 0, 'blocked', 0, 'duplicate', true
    );
  END IF;

  SELECT pause_entries OR pause_all
  INTO v_entries_paused
  FROM control_state;
  v_board := funding_leaderboard(
    p_now_ms,
    p_source_max_age_ms,
    p_position_notional_usd_micros,
    p_cost_usd_micros,
    p_risk_buffer_usd_micros,
    p_hold_hours
  );

  FOR v_portfolio IN
    SELECT p.id, p.comparison_group_id, g.mode
    FROM portfolio_runs p
    JOIN comparison_groups g ON g.id = p.comparison_group_id
    WHERE p.variant = 'cross_asset_funding'
      AND p.execution_mode = 'paper'
      AND p.ended_at IS NULL
      AND p.state <> 'paused'
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

    FOR v_venue IN
      SELECT DISTINCT venue
      FROM funding_observations
      WHERE scan_id = p_scan_id
      ORDER BY venue
    LOOP
      v_action := 'gated';
      v_reason := 'funding_gate_failed';
      SELECT value
      INTO v_top
      FROM jsonb_array_elements(v_board->'items')
      WHERE value->>'venue' = v_venue.venue
      ORDER BY
        CASE WHEN (value->>'eligible')::boolean THEN 0 ELSE 1 END,
        (value->>'rank')::integer
      LIMIT 1;
      IF v_top IS NULL THEN
        CONTINUE;
      END IF;

      SELECT *
      INTO v_top_observation
      FROM funding_observations
      WHERE scan_id = p_scan_id
        AND venue = v_venue.venue
        AND asset = v_top->>'asset';

      SELECT *
      INTO v_position
      FROM cross_asset_paper_positions
      WHERE portfolio_run_id = v_portfolio.id
        AND venue = v_venue.venue
        AND status IN ('open', 'exit_blocked')
      LIMIT 1;
      v_has_position := FOUND;

      IF v_has_position THEN
        SELECT *
        INTO v_current
        FROM funding_observations
        WHERE scan_id = p_scan_id
          AND venue = v_position.venue
          AND asset = v_position.asset;
        v_has_current := FOUND;

        IF v_has_current
           AND v_current.realized_funding_at_ms > v_position.opened_at_ms THEN
          v_amount := trunc(
            v_position.quantity_atoms
              * v_current.mark_price_usd_micros::numeric
              * v_current.realized_funding_rate_ppm::numeric
              / 1000000000 / 1000000
          )::bigint;
          v_payment_id := NULL;
          INSERT INTO funding_payments (
            id, portfolio_run_id, venue_payment_id, effective_at_ms,
            position_quantity_atoms, raw_rate_atoms, normalized_rate_atoms,
            amount_atoms, usd_value_atoms, realization_status, source_event_id
          ) VALUES (
            v_portfolio.id || ':' || v_position.venue || ':'
              || v_position.asset || ':' || v_current.realized_funding_at_ms,
            v_portfolio.id,
            v_position.venue || ':' || v_position.asset || ':'
              || v_current.realized_funding_at_ms,
            v_current.realized_funding_at_ms,
            v_position.quantity_atoms::text,
            v_current.realized_funding_rate_ppm::text,
            v_current.realized_funding_rate_ppm::text,
            v_amount::text,
            v_amount::text,
            'realized',
            v_current.event_id
          )
          ON CONFLICT (portfolio_run_id, venue_payment_id) DO NOTHING
          RETURNING id INTO v_payment_id;

          IF v_payment_id IS NOT NULL AND v_amount <> 0 THEN
            INSERT INTO ledger_batches (
              id, portfolio_run_id, event_type, event_id, batch_hash
            )
            SELECT
              v_payment_id || ':ledger',
              v_portfolio.id,
              'funding',
              v_payment_id,
              raw_payload_hash
            FROM normalized_events
            WHERE id = v_current.event_id;
            INSERT INTO ledger_entries (
              ledger_batch_id, account_debit, account_credit, asset,
              amount_atoms, usd_value_atoms, price_reference_id
            ) VALUES (
              v_payment_id || ':ledger',
              CASE WHEN v_amount > 0 THEN 'paper_cash' ELSE 'funding_expense' END,
              CASE WHEN v_amount > 0 THEN 'funding_income' ELSE 'paper_cash' END,
              'USDC',
              abs(v_amount)::text,
              abs(v_amount)::text,
              v_current.event_id
            );
          END IF;
        END IF;

        v_candidate_eligible :=
          (v_top->>'eligible')::boolean
          AND v_control_ready
          AND NOT v_entries_paused;
        IF v_position.asset = v_top->>'asset' AND v_candidate_eligible THEN
          UPDATE cross_asset_paper_positions
          SET status = 'open',
              latest_source_event_id = v_top_observation.event_id,
              updated_at = now()
          WHERE id = v_position.id;
          UPDATE portfolio_runs
          SET state = 'hedged'
          WHERE id = v_portfolio.id;
          v_action := 'hold';
          v_reason := 'top_ranked_asset_held';
          v_held := v_held + 1;
        ELSIF v_has_current
          AND v_current.source_status = 'valid'
          AND v_current.source_fresh
          AND v_current.depth_qualified THEN
          v_basis := trunc(
            v_position.quantity_atoms * (
              v_current.spot_bid_price_usd_micros::numeric
              - v_position.entry_spot_price_usd_micros::numeric
              + v_position.entry_perp_price_usd_micros::numeric
              - v_current.perp_ask_price_usd_micros::numeric
            ) / 1000000000
          )::bigint;
          UPDATE cross_asset_paper_positions
          SET status = 'closed',
              exit_spot_price_usd_micros = v_current.spot_bid_price_usd_micros,
              exit_perp_price_usd_micros = v_current.perp_ask_price_usd_micros,
              closed_at_ms = p_now_ms,
              latest_source_event_id = v_current.event_id,
              realized_basis_usd_micros = v_basis,
              updated_at = now()
          WHERE id = v_position.id;
          UPDATE portfolio_runs
          SET state = 'idle', state_version = state_version + 1
          WHERE id = v_portfolio.id;
          v_has_position := false;
          v_closed := v_closed + 1;
          v_action := 'switch';
          v_reason := 'top_ranked_asset_changed';
        ELSE
          UPDATE cross_asset_paper_positions
          SET status = 'exit_blocked',
              latest_source_event_id = COALESCE(v_current.event_id, latest_source_event_id),
              updated_at = now()
          WHERE id = v_position.id;
          UPDATE portfolio_runs
          SET state = 'emergency_flatten'
          WHERE id = v_portfolio.id;
          v_action := 'exit_blocked';
          v_reason := 'executable_exit_depth_missing';
          v_blocked := v_blocked + 1;
        END IF;
      END IF;

      v_candidate_eligible :=
        (v_top->>'eligible')::boolean
        AND v_control_ready
        AND NOT v_entries_paused;
      IF NOT v_has_position AND v_candidate_eligible THEN
        v_quantity := trunc(
          p_position_notional_usd_micros::numeric * 1000000000
            / v_top_observation.spot_ask_price_usd_micros
        );
        IF v_quantity <= 0 THEN
          RAISE EXCEPTION 'paper notional produced zero quantity';
        END IF;
        INSERT INTO cross_asset_paper_positions (
          id, portfolio_run_id, venue, asset, instrument, status,
          quantity_atoms, entry_spot_price_usd_micros,
          entry_perp_price_usd_micros, opened_at_ms,
          opened_source_event_id, latest_source_event_id
        ) VALUES (
          v_portfolio.id || ':' || v_venue.venue || ':'
            || v_top_observation.event_id,
          v_portfolio.id,
          v_venue.venue,
          v_top_observation.asset,
          v_top_observation.instrument,
          'open',
          v_quantity,
          v_top_observation.spot_ask_price_usd_micros,
          v_top_observation.perp_bid_price_usd_micros,
          p_now_ms,
          v_top_observation.event_id,
          v_top_observation.event_id
        );
        UPDATE portfolio_runs
        SET state = 'hedged', state_version = state_version + 1
        WHERE id = v_portfolio.id;

        INSERT INTO ledger_batches (
          id, portfolio_run_id, event_type, event_id, batch_hash
        )
        SELECT
          v_portfolio.id || ':' || v_top_observation.event_id || ':cost',
          v_portfolio.id,
          'paper_cross_asset_cost',
          v_top_observation.event_id,
          raw_payload_hash
        FROM normalized_events
        WHERE id = v_top_observation.event_id;
        IF p_cost_usd_micros > 0 THEN
          INSERT INTO ledger_entries (
            ledger_batch_id, account_debit, account_credit, asset,
            amount_atoms, usd_value_atoms, price_reference_id
          ) VALUES (
            v_portfolio.id || ':' || v_top_observation.event_id || ':cost',
            'trading_fees',
            'paper_cash',
            'USDC',
            p_cost_usd_micros::text,
            p_cost_usd_micros::text,
            v_top_observation.event_id
          );
        END IF;
        v_action := CASE WHEN v_action = 'switch' THEN 'switch' ELSE 'open' END;
        v_reason := 'top_ranked_asset_opened';
        v_opened := v_opened + 1;
      ELSIF NOT v_has_position THEN
        IF v_action = 'switch' THEN
          v_action := 'close';
          v_reason := 'funding_gate_closed';
        ELSE
          v_action := 'gated';
          v_reason := CASE
            WHEN v_entries_paused THEN 'entries_paused'
            WHEN NOT v_control_ready THEN 'control_not_hedged'
            WHEN NOT (v_top->>'historyReady')::boolean THEN 'funding_history_warming'
            WHEN NOT (v_top->>'depthQualified')::boolean THEN 'exit_depth_gate_failed'
            ELSE 'funding_gate_failed'
          END;
        END IF;
      END IF;

      INSERT INTO cross_asset_paper_decisions (
        id, scan_id, portfolio_run_id, source_event_id, venue, asset,
        rank, funding_24h_average_ppm, funding_ema_ppm,
        gate_distance_ppm, expected_funding_usd_micros,
        net_carry_usd_micros, eligible, action, reason_code
      ) VALUES (
        p_scan_id || ':' || v_portfolio.id || ':' || v_venue.venue,
        p_scan_id,
        v_portfolio.id,
        v_top_observation.event_id,
        v_venue.venue,
        v_top_observation.asset,
        (v_top->>'rank')::integer,
        (v_top->>'funding24hAveragePpm')::bigint,
        (v_top->>'fundingEmaPpm')::bigint,
        (v_top->>'gateDistancePpm')::bigint,
        trunc(
          p_position_notional_usd_micros::numeric
            * (v_top->>'funding24hAveragePpm')::numeric
            * p_hold_hours / 1000000
        )::bigint,
        trunc(
          p_position_notional_usd_micros::numeric
            * (v_top->>'funding24hAveragePpm')::numeric
            * p_hold_hours / 1000000
        )::bigint - p_cost_usd_micros - p_risk_buffer_usd_micros,
        v_candidate_eligible,
        v_action,
        v_reason
      );
    END LOOP;
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

INSERT INTO schema_meta(version) VALUES (33);

COMMIT;
