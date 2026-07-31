BEGIN;

ALTER TYPE strategy_variant ADD VALUE IF NOT EXISTS 'negative_funding_reverse';

ALTER TABLE funding_observations
  ADD COLUMN borrow_venue text NOT NULL DEFAULT 'none',
  ADD COLUMN borrow_market text NOT NULL DEFAULT 'none',
  ADD COLUMN borrow_reserve text NOT NULL DEFAULT 'none',
  ADD COLUMN borrow_mint text NOT NULL DEFAULT 'none',
  ADD COLUMN borrow_source_observed_at_ms bigint NOT NULL DEFAULT 0
    CHECK (borrow_source_observed_at_ms >= 0),
  ADD COLUMN borrow_source_status text NOT NULL DEFAULT 'unavailable'
    CHECK (borrow_source_status IN ('valid', 'invalid', 'unavailable')),
  ADD COLUMN borrow_source_fresh boolean NOT NULL DEFAULT false,
  ADD COLUMN borrow_rate_ppm_per_hour bigint NOT NULL DEFAULT 0
    CHECK (borrow_rate_ppm_per_hour BETWEEN 0 AND 1000000),
  ADD COLUMN borrow_available_usd_micros bigint NOT NULL DEFAULT 0
    CHECK (borrow_available_usd_micros >= 0),
  ADD COLUMN borrow_utilization_ppm bigint NOT NULL DEFAULT 0
    CHECK (borrow_utilization_ppm BETWEEN 0 AND 1000000);

ALTER TABLE funding_observations
  DROP CONSTRAINT funding_observations_event_id_fkey,
  ADD CONSTRAINT funding_observations_event_id_fkey
    FOREIGN KEY (event_id) REFERENCES normalized_events(id) ON DELETE CASCADE;
ALTER TABLE cross_asset_paper_positions
  DROP CONSTRAINT cross_asset_paper_positions_opened_source_event_id_fkey,
  ADD CONSTRAINT cross_asset_paper_positions_opened_source_event_id_fkey
    FOREIGN KEY (opened_source_event_id)
    REFERENCES normalized_events(id) ON DELETE CASCADE,
  DROP CONSTRAINT cross_asset_paper_positions_latest_source_event_id_fkey,
  ADD CONSTRAINT cross_asset_paper_positions_latest_source_event_id_fkey
    FOREIGN KEY (latest_source_event_id)
    REFERENCES normalized_events(id) ON DELETE CASCADE;
ALTER TABLE cross_asset_paper_decisions
  DROP CONSTRAINT cross_asset_paper_decisions_source_event_id_fkey,
  ADD CONSTRAINT cross_asset_paper_decisions_source_event_id_fkey
    FOREIGN KEY (source_event_id)
    REFERENCES normalized_events(id) ON DELETE CASCADE;

CREATE TABLE reverse_carry_paper_positions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  venue text NOT NULL,
  asset text NOT NULL,
  instrument text NOT NULL,
  borrow_venue text NOT NULL,
  borrow_market text NOT NULL,
  borrow_reserve text NOT NULL,
  borrow_mint text NOT NULL,
  status text NOT NULL CHECK (status IN ('open', 'exit_blocked', 'closed')),
  quantity_atoms numeric(78, 0) NOT NULL CHECK (quantity_atoms > 0),
  entry_spot_price_usd_micros bigint NOT NULL
    CHECK (entry_spot_price_usd_micros > 0),
  entry_perp_price_usd_micros bigint NOT NULL
    CHECK (entry_perp_price_usd_micros > 0),
  exit_spot_price_usd_micros bigint CHECK (exit_spot_price_usd_micros > 0),
  exit_perp_price_usd_micros bigint CHECK (exit_perp_price_usd_micros > 0),
  borrow_rate_ppm_per_hour bigint NOT NULL
    CHECK (borrow_rate_ppm_per_hour BETWEEN 0 AND 1000000),
  last_borrow_accrual_at_ms bigint NOT NULL
    CHECK (last_borrow_accrual_at_ms >= 0),
  borrow_interest_usd_micros bigint NOT NULL DEFAULT 0
    CHECK (borrow_interest_usd_micros >= 0),
  opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= 0),
  closed_at_ms bigint CHECK (closed_at_ms >= opened_at_ms),
  opened_source_event_id text NOT NULL
    REFERENCES normalized_events(id) ON DELETE CASCADE,
  latest_source_event_id text NOT NULL
    REFERENCES normalized_events(id) ON DELETE CASCADE,
  realized_basis_usd_micros bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX reverse_carry_one_open_per_venue
  ON reverse_carry_paper_positions(portfolio_run_id, venue)
  WHERE status IN ('open', 'exit_blocked');

CREATE TABLE reverse_carry_paper_decisions (
  id text PRIMARY KEY,
  scan_id text NOT NULL,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL
    REFERENCES normalized_events(id) ON DELETE CASCADE,
  venue text NOT NULL,
  asset text NOT NULL,
  rank integer NOT NULL CHECK (rank > 0),
  funding_24h_average_ppm bigint NOT NULL,
  borrow_rate_ppm_per_hour bigint NOT NULL
    CHECK (borrow_rate_ppm_per_hour BETWEEN 0 AND 1000000),
  gate_distance_ppm bigint NOT NULL,
  expected_funding_usd_micros bigint NOT NULL,
  projected_borrow_usd_micros bigint NOT NULL
    CHECK (projected_borrow_usd_micros >= 0),
  net_carry_usd_micros bigint NOT NULL,
  eligible boolean NOT NULL,
  action text NOT NULL CHECK (
    action IN ('open', 'hold', 'switch', 'close', 'gated', 'exit_blocked')
  ),
  reason_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (scan_id, portfolio_run_id, venue)
);

CREATE FUNCTION record_borrow_snapshot(
  p_event jsonb,
  p_source_max_age_ms bigint
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload jsonb := p_event->'payload';
  v_status text := v_payload->>'borrowSourceStatus';
  v_fresh boolean;
BEGIN
  IF p_source_max_age_ms <= 0 THEN
    RAISE EXCEPTION 'invalid borrow source age';
  END IF;
  IF v_status IS NULL THEN
    RETURN false;
  END IF;
  IF p_event->>'eventType' <> 'FundingObservation'
     OR p_event->>'observedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR v_status NOT IN ('valid', 'invalid', 'unavailable')
     OR v_payload->>'borrowVenue' IS NULL
     OR v_payload->>'borrowMarket' IS NULL
     OR v_payload->>'borrowReserve' IS NULL
     OR v_payload->>'borrowMint' IS NULL
     OR v_payload->>'borrowSourceObservedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'borrowRatePpmPerHour' !~ '^(0|[1-9][0-9]*)$'
     OR (v_payload->>'borrowRatePpmPerHour')::numeric > 1000000
     OR v_payload->>'borrowAvailableUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'borrowUtilizationPpm' !~ '^(0|[1-9][0-9]*)$'
     OR (v_payload->>'borrowUtilizationPpm')::numeric > 1000000
     OR (
       v_status = 'valid'
       AND (
         v_payload->>'borrowVenue' <> 'kamino'
         OR v_payload->>'borrowMarket'
           !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
         OR v_payload->>'borrowReserve'
           !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
         OR v_payload->>'borrowMint'
           !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
         OR (v_payload->>'borrowSourceObservedAtMs')::numeric <= 0
         OR (v_payload->>'borrowSourceObservedAtMs')::numeric
           > (p_event->>'observedAtMs')::numeric
       )
     )
     OR (
       v_status <> 'valid'
       AND (
         (v_payload->>'borrowRatePpmPerHour')::numeric <> 0
         OR (v_payload->>'borrowAvailableUsdMicros')::numeric <> 0
         OR (v_payload->>'borrowUtilizationPpm')::numeric <> 0
       )
     ) THEN
    RAISE EXCEPTION 'invalid borrow snapshot contract';
  END IF;

  v_fresh :=
    v_status = 'valid'
    AND (p_event->>'observedAtMs')::bigint
      - (v_payload->>'borrowSourceObservedAtMs')::bigint
      BETWEEN 0 AND p_source_max_age_ms;

  UPDATE funding_observations
  SET borrow_venue = v_payload->>'borrowVenue',
      borrow_market = v_payload->>'borrowMarket',
      borrow_reserve = v_payload->>'borrowReserve',
      borrow_mint = v_payload->>'borrowMint',
      borrow_source_observed_at_ms =
        (v_payload->>'borrowSourceObservedAtMs')::bigint,
      borrow_source_status = v_status,
      borrow_source_fresh = v_fresh,
      borrow_rate_ppm_per_hour =
        (v_payload->>'borrowRatePpmPerHour')::bigint,
      borrow_available_usd_micros =
        (v_payload->>'borrowAvailableUsdMicros')::bigint,
      borrow_utilization_ppm =
        (v_payload->>'borrowUtilizationPpm')::bigint
  WHERE event_id = p_event->>'eventId';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'borrow snapshot funding observation is missing';
  END IF;
  RETURN true;
END;
$$;

CREATE FUNCTION reverse_carry_leaderboard(
  p_now_ms bigint,
  p_funding_source_max_age_ms bigint,
  p_borrow_source_max_age_ms bigint,
  p_position_notional_usd_micros bigint,
  p_cost_usd_micros bigint,
  p_risk_buffer_usd_micros bigint,
  p_hold_hours integer,
  p_maximum_break_even_hours integer,
  p_minimum_negative_funding_ppm bigint,
  p_maximum_borrow_utilization_ppm bigint
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_cost_threshold bigint;
  v_items jsonb;
BEGIN
  IF p_now_ms < 0
     OR p_funding_source_max_age_ms <= 0
     OR p_borrow_source_max_age_ms <= 0
     OR p_position_notional_usd_micros <= 0
     OR p_cost_usd_micros < 0
     OR p_risk_buffer_usd_micros < 0
     OR p_hold_hours <= 0
     OR p_maximum_break_even_hours <= 0
     OR p_minimum_negative_funding_ppm <= 0
     OR p_maximum_borrow_utilization_ppm NOT BETWEEN 1 AND 1000000 THEN
    RAISE EXCEPTION 'invalid reverse carry leaderboard inputs';
  END IF;

  v_cost_threshold := ceil(
    ((p_cost_usd_micros + p_risk_buffer_usd_micros)::numeric * 1000000)
      / (
        p_position_notional_usd_micros::numeric
        * p_maximum_break_even_hours
      )
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
  scored AS (
    SELECT
      l.*,
      GREATEST(-l.funding_24h_average_ppm, 0) AS funding_receipt_ppm,
      GREATEST(-l.funding_24h_average_ppm, 0)
        - l.borrow_rate_ppm_per_hour AS net_rate_ppm,
      (
        l.observed_at_ms - h.first_observed_at_ms >= 604800000
        AND h.bad_samples = 0
        AND h.max_gap_ms <= p_funding_source_max_age_ms
        AND l.samples_24h >= 24
      ) AS history_ready
    FROM latest l
    JOIN history h USING (venue, asset)
  ),
  ranked AS (
    SELECT
      s.*,
      row_number() OVER (
        ORDER BY s.net_rate_ppm DESC, s.venue, s.asset
      ) AS funding_rank
    FROM scored s
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
        'fundingReceiptPpmPerHour', funding_receipt_ppm::text,
        'borrowVenue', borrow_venue,
        'borrowMarket', borrow_market,
        'borrowReserve', borrow_reserve,
        'borrowMint', borrow_mint,
        'borrowSourceStatus', borrow_source_status,
        'borrowSourceFresh', borrow_source_fresh,
        'borrowRatePpmPerHour', borrow_rate_ppm_per_hour::text,
        'borrowAvailableUsdMicros', borrow_available_usd_micros::text,
        'borrowUtilizationPpm', borrow_utilization_ppm::text,
        'costThresholdPpm', v_cost_threshold::text,
        'gateDistancePpm', (net_rate_ppm - v_cost_threshold)::text,
        'samples24h', samples_24h,
        'historyReady', history_ready,
        'depthQualified', depth_qualified,
        'eligible', (
          source_status = 'valid'
          AND source_fresh
          AND p_now_ms - observed_at_ms <= p_funding_source_max_age_ms
          AND depth_qualified
          AND history_ready
          AND funding_24h_average_ppm <= -p_minimum_negative_funding_ppm
          AND borrow_source_status = 'valid'
          AND borrow_source_fresh
          AND p_now_ms - borrow_source_observed_at_ms
            <= p_borrow_source_max_age_ms
          AND borrow_available_usd_micros
            >= p_position_notional_usd_micros * 2
          AND borrow_utilization_ppm
            <= p_maximum_borrow_utilization_ppm
          AND net_rate_ppm >= v_cost_threshold
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
    'minimumNegativeFundingPpm', p_minimum_negative_funding_ppm::text,
    'maximumBorrowUtilizationPpm',
      p_maximum_borrow_utilization_ppm::text,
    'maximumBreakEvenHours', p_maximum_break_even_hours::text,
    'costThresholdPpm', v_cost_threshold::text,
    'items', v_items
  );
END;
$$;

CREATE FUNCTION run_reverse_carry_paper_scan(
  p_scan_id text,
  p_now_ms bigint,
  p_funding_source_max_age_ms bigint,
  p_borrow_source_max_age_ms bigint,
  p_position_notional_usd_micros bigint,
  p_cost_usd_micros bigint,
  p_risk_buffer_usd_micros bigint,
  p_hold_hours integer,
  p_maximum_break_even_hours integer,
  p_minimum_negative_funding_ppm bigint,
  p_maximum_borrow_utilization_ppm bigint
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
  v_position reverse_carry_paper_positions%ROWTYPE;
  v_has_position boolean;
  v_has_current boolean;
  v_control_ready boolean;
  v_candidate_eligible boolean;
  v_current_safe boolean;
  v_entries_paused boolean;
  v_action text;
  v_reason text;
  v_quantity numeric(78, 0);
  v_basis bigint;
  v_funding_amount bigint;
  v_borrow_cost bigint;
  v_payment_id text;
  v_opened integer := 0;
  v_held integer := 0;
  v_closed integer := 0;
  v_blocked integer := 0;
BEGIN
  IF p_scan_id IS NULL OR p_position_notional_usd_micros <= 0 THEN
    RAISE EXCEPTION 'invalid reverse carry paper inputs';
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
    SELECT 1 FROM reverse_carry_paper_decisions WHERE scan_id = p_scan_id
  ) THEN
    RETURN jsonb_build_object(
      'opened', 0, 'held', 0, 'closed', 0, 'blocked', 0, 'duplicate', true
    );
  END IF;

  SELECT pause_entries OR pause_all
  INTO v_entries_paused
  FROM control_state;
  v_board := reverse_carry_leaderboard(
    p_now_ms,
    p_funding_source_max_age_ms,
    p_borrow_source_max_age_ms,
    p_position_notional_usd_micros,
    p_cost_usd_micros,
    p_risk_buffer_usd_micros,
    p_hold_hours,
    p_maximum_break_even_hours,
    p_minimum_negative_funding_ppm,
    p_maximum_borrow_utilization_ppm
  );

  FOR v_portfolio IN
    SELECT p.id, p.comparison_group_id, g.mode
    FROM portfolio_runs p
    JOIN comparison_groups g ON g.id = p.comparison_group_id
    WHERE p.variant = 'negative_funding_reverse'
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
      v_reason := 'negative_funding_gate_failed';
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
      FROM reverse_carry_paper_positions
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
          v_funding_amount := trunc(
            -v_position.quantity_atoms
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
            v_position.venue || ':' || v_position.asset || ':long:'
              || v_current.realized_funding_at_ms,
            v_current.realized_funding_at_ms,
            v_position.quantity_atoms::text,
            v_current.realized_funding_rate_ppm::text,
            (-v_current.realized_funding_rate_ppm)::text,
            v_funding_amount::text,
            v_funding_amount::text,
            'realized',
            v_current.event_id
          )
          ON CONFLICT (portfolio_run_id, venue_payment_id) DO NOTHING
          RETURNING id INTO v_payment_id;

          IF v_payment_id IS NOT NULL AND v_funding_amount <> 0 THEN
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
              CASE WHEN v_funding_amount > 0
                THEN 'paper_cash' ELSE 'funding_expense' END,
              CASE WHEN v_funding_amount > 0
                THEN 'funding_income' ELSE 'paper_cash' END,
              'USDC',
              abs(v_funding_amount)::text,
              abs(v_funding_amount)::text,
              v_current.event_id
            );
          END IF;
        END IF;

        IF v_has_current
           AND p_now_ms > v_position.last_borrow_accrual_at_ms THEN
          v_borrow_cost := trunc(
            v_position.quantity_atoms
              * v_current.mark_price_usd_micros::numeric
              * v_position.borrow_rate_ppm_per_hour::numeric
              * (
                p_now_ms - v_position.last_borrow_accrual_at_ms
              )::numeric
              / 1000000000 / 1000000 / 3600000
          )::bigint;
          IF v_borrow_cost > 0 THEN
            INSERT INTO ledger_batches (
              id, portfolio_run_id, event_type, event_id, batch_hash
            )
            SELECT
              v_portfolio.id || ':' || v_current.event_id || ':borrow',
              v_portfolio.id,
              'borrow_interest',
              v_current.event_id,
              raw_payload_hash
            FROM normalized_events
            WHERE id = v_current.event_id
            ON CONFLICT (id) DO NOTHING;
            INSERT INTO ledger_entries (
              ledger_batch_id, account_debit, account_credit, asset,
              amount_atoms, usd_value_atoms, price_reference_id
            ) VALUES (
              v_portfolio.id || ':' || v_current.event_id || ':borrow',
              'borrow_interest_expense',
              'paper_cash',
              'USDC',
              v_borrow_cost::text,
              v_borrow_cost::text,
              v_current.event_id
            )
            ON CONFLICT DO NOTHING;
          END IF;
          UPDATE reverse_carry_paper_positions
          SET borrow_interest_usd_micros =
                borrow_interest_usd_micros + v_borrow_cost,
              last_borrow_accrual_at_ms = p_now_ms,
              borrow_rate_ppm_per_hour =
                CASE WHEN v_current.borrow_source_status = 'valid'
                  THEN v_current.borrow_rate_ppm_per_hour
                  ELSE borrow_rate_ppm_per_hour END,
              updated_at = now()
          WHERE id = v_position.id;
        END IF;

        v_current_safe :=
          v_has_current
          AND v_current.borrow_source_status = 'valid'
          AND v_current.borrow_source_fresh
          AND p_now_ms - v_current.borrow_source_observed_at_ms
            <= p_borrow_source_max_age_ms
          AND v_current.borrow_available_usd_micros
            >= p_position_notional_usd_micros * 2
          AND v_current.borrow_utilization_ppm
            <= p_maximum_borrow_utilization_ppm
          AND v_current.funding_rate_ppm_per_hour < 0
          AND v_current.borrow_rate_ppm_per_hour
            < -v_current.funding_rate_ppm_per_hour;
        v_candidate_eligible :=
          (v_top->>'eligible')::boolean
          AND v_control_ready
          AND NOT v_entries_paused;

        IF v_position.asset = v_top->>'asset'
           AND v_candidate_eligible
           AND v_current_safe THEN
          UPDATE reverse_carry_paper_positions
          SET status = 'open',
              latest_source_event_id = v_top_observation.event_id,
              updated_at = now()
          WHERE id = v_position.id;
          UPDATE portfolio_runs SET state = 'hedged'
          WHERE id = v_portfolio.id;
          v_action := 'hold';
          v_reason := 'reverse_carry_held';
          v_held := v_held + 1;
        ELSIF v_has_current
          AND v_current.source_status = 'valid'
          AND v_current.source_fresh
          AND v_current.depth_qualified THEN
          v_basis := trunc(
            v_position.quantity_atoms * (
              v_position.entry_spot_price_usd_micros::numeric
              - v_current.spot_ask_price_usd_micros::numeric
              + v_current.perp_bid_price_usd_micros::numeric
              - v_position.entry_perp_price_usd_micros::numeric
            ) / 1000000000
          )::bigint;
          UPDATE reverse_carry_paper_positions
          SET status = 'closed',
              exit_spot_price_usd_micros =
                v_current.spot_ask_price_usd_micros,
              exit_perp_price_usd_micros =
                v_current.perp_bid_price_usd_micros,
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
          v_action := 'close';
          v_reason := CASE
            WHEN v_current.borrow_source_status <> 'valid'
              OR NOT v_current.borrow_source_fresh
              THEN 'borrow_source_unavailable'
            WHEN v_current.borrow_utilization_ppm
              > p_maximum_borrow_utilization_ppm
              THEN 'borrow_utilization_breaker'
            WHEN v_current.borrow_available_usd_micros
              < p_position_notional_usd_micros * 2
              THEN 'borrow_liquidity_breaker'
            WHEN v_current.funding_rate_ppm_per_hour >= 0
              OR v_current.borrow_rate_ppm_per_hour
                >= -v_current.funding_rate_ppm_per_hour
              THEN 'borrow_rate_spike'
            WHEN v_position.asset <> v_top->>'asset'
              THEN 'reverse_asset_changed'
            ELSE 'negative_funding_gate_closed'
          END;
        ELSE
          UPDATE reverse_carry_paper_positions
          SET status = 'exit_blocked',
              latest_source_event_id =
                COALESCE(v_current.event_id, latest_source_event_id),
              updated_at = now()
          WHERE id = v_position.id;
          UPDATE portfolio_runs SET state = 'emergency_flatten'
          WHERE id = v_portfolio.id;
          v_action := 'exit_blocked';
          v_reason := 'executable_exit_depth_missing';
          v_blocked := v_blocked + 1;
        END IF;
      END IF;

      v_current_safe :=
        v_top_observation.borrow_source_status = 'valid'
        AND v_top_observation.borrow_source_fresh
        AND p_now_ms - v_top_observation.borrow_source_observed_at_ms
          <= p_borrow_source_max_age_ms
        AND v_top_observation.borrow_available_usd_micros
          >= p_position_notional_usd_micros * 2
        AND v_top_observation.borrow_utilization_ppm
          <= p_maximum_borrow_utilization_ppm
        AND v_top_observation.funding_rate_ppm_per_hour < 0
        AND v_top_observation.borrow_rate_ppm_per_hour
          < -v_top_observation.funding_rate_ppm_per_hour;
      v_candidate_eligible :=
        (v_top->>'eligible')::boolean
        AND v_current_safe
        AND v_control_ready
        AND NOT v_entries_paused;

      IF NOT v_has_position AND v_candidate_eligible THEN
        v_quantity := trunc(
          p_position_notional_usd_micros::numeric * 1000000000
            / v_top_observation.spot_bid_price_usd_micros
        );
        IF v_quantity <= 0 THEN
          RAISE EXCEPTION 'paper notional produced zero reverse quantity';
        END IF;
        INSERT INTO reverse_carry_paper_positions (
          id, portfolio_run_id, venue, asset, instrument,
          borrow_venue, borrow_market, borrow_reserve, borrow_mint,
          status, quantity_atoms, entry_spot_price_usd_micros,
          entry_perp_price_usd_micros, borrow_rate_ppm_per_hour,
          last_borrow_accrual_at_ms, opened_at_ms,
          opened_source_event_id, latest_source_event_id
        ) VALUES (
          v_portfolio.id || ':' || v_venue.venue || ':'
            || v_top_observation.event_id,
          v_portfolio.id,
          v_venue.venue,
          v_top_observation.asset,
          v_top_observation.instrument,
          v_top_observation.borrow_venue,
          v_top_observation.borrow_market,
          v_top_observation.borrow_reserve,
          v_top_observation.borrow_mint,
          'open',
          v_quantity,
          v_top_observation.spot_bid_price_usd_micros,
          v_top_observation.perp_ask_price_usd_micros,
          v_top_observation.borrow_rate_ppm_per_hour,
          p_now_ms,
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
          'paper_reverse_carry_cost',
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
        v_action := CASE WHEN v_action = 'close' THEN 'switch' ELSE 'open' END;
        v_reason := 'reverse_carry_opened';
        v_opened := v_opened + 1;
      ELSIF NOT v_has_position AND v_action <> 'close' THEN
        v_action := 'gated';
        v_reason := CASE
          WHEN v_entries_paused THEN 'entries_paused'
          WHEN NOT v_control_ready THEN 'control_not_hedged'
          WHEN NOT (v_top->>'historyReady')::boolean
            THEN 'funding_history_warming'
          WHEN NOT (v_top->>'depthQualified')::boolean
            THEN 'exit_depth_gate_failed'
          WHEN v_top_observation.borrow_source_status <> 'valid'
            OR NOT v_top_observation.borrow_source_fresh
            THEN 'borrow_source_unavailable'
          WHEN v_top_observation.borrow_utilization_ppm
            > p_maximum_borrow_utilization_ppm
            THEN 'borrow_utilization_gate_failed'
          WHEN v_top_observation.borrow_available_usd_micros
            < p_position_notional_usd_micros * 2
            THEN 'borrow_liquidity_gate_failed'
          ELSE 'negative_funding_gate_failed'
        END;
      END IF;

      INSERT INTO reverse_carry_paper_decisions (
        id, scan_id, portfolio_run_id, source_event_id, venue, asset,
        rank, funding_24h_average_ppm, borrow_rate_ppm_per_hour,
        gate_distance_ppm, expected_funding_usd_micros,
        projected_borrow_usd_micros, net_carry_usd_micros,
        eligible, action, reason_code
      ) VALUES (
        p_scan_id || ':' || v_portfolio.id || ':' || v_venue.venue,
        p_scan_id,
        v_portfolio.id,
        v_top_observation.event_id,
        v_venue.venue,
        v_top_observation.asset,
        (v_top->>'rank')::integer,
        (v_top->>'funding24hAveragePpm')::bigint,
        v_top_observation.borrow_rate_ppm_per_hour,
        (v_top->>'gateDistancePpm')::bigint,
        trunc(
          p_position_notional_usd_micros::numeric
            * (v_top->>'fundingReceiptPpmPerHour')::numeric
            * p_hold_hours / 1000000
        )::bigint,
        trunc(
          p_position_notional_usd_micros::numeric
            * v_top_observation.borrow_rate_ppm_per_hour::numeric
            * p_hold_hours / 1000000
        )::bigint,
        trunc(
          p_position_notional_usd_micros::numeric
            * (
              (v_top->>'fundingReceiptPpmPerHour')::numeric
              - v_top_observation.borrow_rate_ppm_per_hour::numeric
            )
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

INSERT INTO schema_meta(version) VALUES (34);

COMMIT;
