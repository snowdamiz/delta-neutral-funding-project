BEGIN;

ALTER TYPE strategy_variant
  ADD VALUE IF NOT EXISTS 'hyperliquid_wallet_flow';
ALTER TYPE strategy_variant
  ADD VALUE IF NOT EXISTS 'hyperliquid_wallet_mirror';
ALTER TYPE strategy_variant
  ADD VALUE IF NOT EXISTS 'hyperliquid_wallet_fade';

CREATE TABLE wallet_observations (
  event_id text PRIMARY KEY REFERENCES normalized_events(id),
  wallet text NOT NULL CHECK (wallet ~ '^0x[0-9a-f]{40}$'),
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  source_observed_at_ms bigint NOT NULL CHECK (
    source_observed_at_ms BETWEEN 0 AND observed_at_ms
  ),
  account_value_usd_micros bigint NOT NULL CHECK (
    account_value_usd_micros >= 0
  ),
  total_notional_usd_micros bigint NOT NULL CHECK (
    total_notional_usd_micros >= 0
  ),
  api_latency_ms bigint NOT NULL CHECK (api_latency_ms >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX wallet_observations_wallet_time
  ON wallet_observations(wallet, observed_at_ms DESC);

CREATE TABLE wallet_positions (
  event_id text NOT NULL REFERENCES wallet_observations(event_id),
  wallet text NOT NULL,
  asset text NOT NULL CHECK (asset ~ '^[A-Z0-9:_-]{1,64}$'),
  side text NOT NULL CHECK (side IN ('long', 'short')),
  quantity_atoms numeric NOT NULL CHECK (quantity_atoms > 0),
  entry_price_usd_micros bigint NOT NULL CHECK (entry_price_usd_micros > 0),
  mark_price_usd_micros bigint NOT NULL CHECK (mark_price_usd_micros > 0),
  leverage_ppm bigint NOT NULL CHECK (leverage_ppm > 0),
  unrealized_pnl_usd_micros bigint NOT NULL,
  PRIMARY KEY (event_id, asset)
);

CREATE TABLE wallet_fills (
  fill_id text PRIMARY KEY,
  source_event_id text NOT NULL REFERENCES wallet_observations(event_id),
  wallet text NOT NULL CHECK (wallet ~ '^0x[0-9a-f]{40}$'),
  asset text NOT NULL CHECK (asset ~ '^[A-Z0-9:_-]{1,64}$'),
  side text NOT NULL CHECK (side IN ('buy', 'sell')),
  direction text NOT NULL CHECK (
    direction IN ('open', 'increase', 'reduce', 'close', 'flip')
  ),
  quantity_atoms numeric NOT NULL CHECK (quantity_atoms > 0),
  leader_price_usd_micros bigint NOT NULL CHECK (
    leader_price_usd_micros > 0
  ),
  copy_bid_price_usd_micros bigint NOT NULL CHECK (
    copy_bid_price_usd_micros >= 0
  ),
  copy_ask_price_usd_micros bigint NOT NULL CHECK (
    copy_ask_price_usd_micros >= 0
  ),
  closed_pnl_usd_micros bigint NOT NULL,
  fee_usd_micros bigint NOT NULL CHECK (fee_usd_micros >= 0),
  filled_at_ms bigint NOT NULL CHECK (filled_at_ms >= 0),
  copy_observed_at_ms bigint NOT NULL CHECK (
    copy_observed_at_ms >= filled_at_ms
  ),
  copy_latency_ms bigint NOT NULL CHECK (
    copy_latency_ms >= copy_observed_at_ms - filled_at_ms
  ),
  copy_bid_depth_qualified boolean NOT NULL,
  copy_ask_depth_qualified boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (copy_bid_depth_qualified = false OR copy_bid_price_usd_micros > 0)
    AND
    (copy_ask_depth_qualified = false OR copy_ask_price_usd_micros > 0)
  )
);

CREATE INDEX wallet_fills_wallet_time
  ON wallet_fills(wallet, filled_at_ms, fill_id);

CREATE TABLE wallet_flow_signals (
  source_event_id text NOT NULL REFERENCES wallet_observations(event_id),
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  asset text NOT NULL CHECK (asset ~ '^[A-Z0-9:_-]{1,64}$'),
  signal_ppm bigint NOT NULL CHECK (signal_ppm BETWEEN -1000000 AND 1000000),
  qualified_wallets integer NOT NULL CHECK (qualified_wallets >= 0),
  qualified boolean NOT NULL,
  PRIMARY KEY (source_event_id, asset)
);

CREATE INDEX wallet_flow_signals_asset_time
  ON wallet_flow_signals(asset, observed_at_ms DESC);

CREATE TABLE wallet_paper_positions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  mode text NOT NULL CHECK (mode IN ('flow', 'mirror', 'fade')),
  wallet text NOT NULL,
  asset text NOT NULL,
  side text NOT NULL CHECK (side IN ('long', 'short')),
  status text NOT NULL CHECK (status IN ('open', 'closed')),
  quantity_atoms numeric NOT NULL CHECK (quantity_atoms > 0),
  notional_usd_micros bigint NOT NULL CHECK (notional_usd_micros > 0),
  entry_price_usd_micros bigint NOT NULL CHECK (entry_price_usd_micros > 0),
  exit_price_usd_micros bigint CHECK (exit_price_usd_micros > 0),
  modeled_cost_usd_micros bigint NOT NULL CHECK (modeled_cost_usd_micros >= 0),
  realized_gross_usd_micros bigint NOT NULL DEFAULT 0,
  realized_net_usd_micros bigint NOT NULL DEFAULT 0,
  opened_fill_id text NOT NULL REFERENCES wallet_fills(fill_id),
  closed_fill_id text REFERENCES wallet_fills(fill_id),
  opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= 0),
  closed_at_ms bigint CHECK (closed_at_ms >= opened_at_ms),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX wallet_paper_one_open_position
  ON wallet_paper_positions(portfolio_run_id, wallet, asset)
  WHERE status = 'open';

CREATE TABLE wallet_paper_decisions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  fill_id text NOT NULL REFERENCES wallet_fills(fill_id),
  mode text NOT NULL CHECK (mode IN ('flow', 'mirror', 'fade')),
  wallet text NOT NULL,
  asset text NOT NULL,
  score_as_of_ms bigint NOT NULL CHECK (score_as_of_ms >= 0),
  score_ppm bigint NOT NULL,
  closed_decisions integer NOT NULL CHECK (closed_decisions >= 0),
  signal_ppm bigint NOT NULL CHECK (signal_ppm BETWEEN -1000000 AND 1000000),
  copy_latency_ms bigint NOT NULL CHECK (copy_latency_ms >= 0),
  slippage_usd_micros bigint NOT NULL CHECK (slippage_usd_micros >= 0),
  eligible boolean NOT NULL,
  action text NOT NULL,
  reason_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (portfolio_run_id, fill_id, mode)
);

CREATE FUNCTION wallet_score_rows(
  p_as_of_ms bigint,
  p_minimum_decisions integer DEFAULT 20
) RETURNS TABLE (
  wallet text,
  closed_decisions integer,
  net_realized_usd_micros bigint,
  fees_usd_micros bigint,
  max_drawdown_usd_micros bigint,
  score_ppm bigint,
  qualified boolean
)
LANGUAGE sql
STABLE
AS $$
  WITH observed AS (
    SELECT
      o.wallet,
      o.observed_at_ms,
      o.account_value_usd_micros,
      max(o.account_value_usd_micros) OVER (
        PARTITION BY o.wallet
        ORDER BY o.observed_at_ms, o.event_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS running_peak
    FROM wallet_observations o
    WHERE o.observed_at_ms <= p_as_of_ms
  ),
  drawdowns AS (
    SELECT
      o.wallet,
      COALESCE(max(o.running_peak - o.account_value_usd_micros), 0)::bigint
        AS max_drawdown
    FROM observed o
    GROUP BY o.wallet
  ),
  fill_totals AS (
    SELECT
      f.wallet,
      count(*) FILTER (
        WHERE f.direction IN ('reduce', 'close', 'flip')
      )::integer AS closed_decisions,
      COALESCE(sum(f.closed_pnl_usd_micros), 0)::bigint AS closed_pnl,
      COALESCE(sum(f.fee_usd_micros), 0)::bigint AS fees
    FROM wallet_fills f
    WHERE f.filled_at_ms <= p_as_of_ms
    GROUP BY f.wallet
  ),
  wallets AS (
    SELECT wallet FROM drawdowns
    UNION
    SELECT wallet FROM fill_totals
  ),
  scored AS (
    SELECT
      w.wallet,
      COALESCE(f.closed_decisions, 0) AS closed_decisions,
      (COALESCE(f.closed_pnl, 0) - COALESCE(f.fees, 0))::bigint AS net,
      COALESCE(f.fees, 0)::bigint AS fees,
      COALESCE(d.max_drawdown, 0)::bigint AS max_drawdown
    FROM wallets w
    LEFT JOIN fill_totals f USING (wallet)
    LEFT JOIN drawdowns d USING (wallet)
  )
  SELECT
    s.wallet,
    s.closed_decisions,
    s.net,
    s.fees,
    s.max_drawdown,
    trunc(
      s.net::numeric * 1000000
        / greatest(s.max_drawdown + s.fees, 1)
    )::bigint AS score_ppm,
    s.closed_decisions >= p_minimum_decisions AS qualified
  FROM scored s
$$;

CREATE FUNCTION wallet_consistency_scores(
  p_as_of_ms bigint,
  p_minimum_decisions integer DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF p_as_of_ms < 0 OR p_minimum_decisions <= 0 THEN
    RAISE EXCEPTION 'invalid wallet score inputs';
  END IF;
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'rank', ranked.rank,
      'wallet', ranked.wallet,
      'closedDecisions', ranked.closed_decisions::text,
      'netRealizedUsdMicros', ranked.net_realized_usd_micros::text,
      'feesUsdMicros', ranked.fees_usd_micros::text,
      'maxDrawdownUsdMicros', ranked.max_drawdown_usd_micros::text,
      'scorePpm', ranked.score_ppm::text,
      'qualified', ranked.qualified
    ) ORDER BY ranked.rank
  ), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      row_number() OVER (
        ORDER BY s.score_ppm DESC, s.closed_decisions DESC, s.wallet
      ) AS rank,
      s.*
    FROM wallet_score_rows(p_as_of_ms, p_minimum_decisions) s
  ) ranked;
  RETURN jsonb_build_object(
    'asOfMs', p_as_of_ms::text,
    'minimumDecisions', p_minimum_decisions::text,
    'items', v_items
  );
END;
$$;

CREATE FUNCTION refresh_wallet_flow_signals(
  p_source_event_id text,
  p_observed_at_ms bigint
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  WITH latest_events AS (
    SELECT DISTINCT ON (o.wallet)
      o.wallet, o.event_id
    FROM wallet_observations o
    WHERE o.observed_at_ms <= p_observed_at_ms
    ORDER BY o.wallet, o.observed_at_ms DESC, o.event_id DESC
  ),
  scores AS (
    SELECT *
    FROM wallet_score_rows(greatest(p_observed_at_ms - 1, 0), 20)
    WHERE qualified AND score_ppm > 0
  ),
  current_positions AS (
    SELECT p.wallet, p.asset, p.side, s.score_ppm
    FROM latest_events e
    JOIN wallet_positions p ON p.event_id = e.event_id
    JOIN scores s ON s.wallet = p.wallet
  ),
  assets AS (
    SELECT asset FROM current_positions
    UNION
    SELECT asset
    FROM wallet_flow_signals
    WHERE observed_at_ms = (
      SELECT max(observed_at_ms)
      FROM wallet_flow_signals
      WHERE observed_at_ms < p_observed_at_ms
    )
  ),
  aggregated AS (
    SELECT
      a.asset,
      count(p.wallet)::integer AS wallets,
      COALESCE(
        trunc(
          sum(CASE WHEN p.side = 'long' THEN p.score_ppm ELSE -p.score_ppm END)
            * 1000000::numeric
            / NULLIF(sum(abs(p.score_ppm)), 0)
        ),
        0
      )::bigint AS signal
    FROM assets a
    LEFT JOIN current_positions p USING (asset)
    GROUP BY a.asset
  )
  INSERT INTO wallet_flow_signals (
    source_event_id, observed_at_ms, asset, signal_ppm,
    qualified_wallets, qualified
  )
  SELECT
    p_source_event_id,
    p_observed_at_ms,
    asset,
    signal,
    wallets,
    wallets > 0
  FROM aggregated
  ON CONFLICT (source_event_id, asset) DO NOTHING;
END;
$$;

CREATE FUNCTION process_wallet_paper_fill(
  p_fill_id text,
  p_notional_usd_micros bigint,
  p_modeled_cost_usd_micros bigint
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_fill wallet_fills%ROWTYPE;
  v_score record;
  v_signal wallet_flow_signals%ROWTYPE;
  v_portfolio record;
  v_position wallet_paper_positions%ROWTYPE;
  v_mode text;
  v_variant text;
  v_gate_eligible boolean;
  v_eligible boolean;
  v_depth_qualified boolean;
  v_action text;
  v_reason text;
  v_side text;
  v_copy_price bigint;
  v_open_notional bigint;
  v_position_found boolean;
  v_quantity numeric;
  v_gross numeric;
  v_slippage numeric;
BEGIN
  SELECT * INTO STRICT v_fill
  FROM wallet_fills
  WHERE fill_id = p_fill_id;
  SELECT * INTO v_score
  FROM wallet_score_rows(greatest(v_fill.filled_at_ms - 1, 0), 20)
  WHERE wallet = v_fill.wallet;
  SELECT * INTO v_signal
  FROM wallet_flow_signals
  WHERE asset = v_fill.asset
    AND observed_at_ms <= v_fill.copy_observed_at_ms
  ORDER BY observed_at_ms DESC
  LIMIT 1;

  FOREACH v_mode IN ARRAY ARRAY['flow', 'mirror', 'fade'] LOOP
    v_variant := CASE v_mode
      WHEN 'flow' THEN 'hyperliquid_wallet_flow'
      WHEN 'mirror' THEN 'hyperliquid_wallet_mirror'
      ELSE 'hyperliquid_wallet_fade'
    END;
    FOR v_portfolio IN
      SELECT id, initial_capital_usd_micros
      FROM portfolio_runs
      WHERE variant::text = v_variant
        AND execution_mode = 'paper'
        AND ended_at IS NULL
        AND state <> 'paused'
      ORDER BY id
      FOR UPDATE
    LOOP
      v_gate_eligible :=
        COALESCE(v_score.qualified, false)
        AND CASE v_mode
          WHEN 'mirror' THEN v_score.score_ppm > 0
          WHEN 'fade' THEN v_score.score_ppm < 0
          ELSE COALESCE(v_signal.qualified, false)
            AND abs(v_signal.signal_ppm) >= 250000
        END;
      v_action := 'gated';

      SELECT * INTO v_position
      FROM wallet_paper_positions
      WHERE portfolio_run_id = v_portfolio.id
        AND wallet = v_fill.wallet
        AND asset = v_fill.asset
        AND status = 'open'
      LIMIT 1;
      v_position_found := FOUND;

      IF v_position_found THEN
        v_copy_price := CASE v_position.side
          WHEN 'long' THEN v_fill.copy_bid_price_usd_micros
          ELSE v_fill.copy_ask_price_usd_micros
        END;
        v_depth_qualified := CASE v_position.side
          WHEN 'long' THEN v_fill.copy_bid_depth_qualified
          ELSE v_fill.copy_ask_depth_qualified
        END;
        v_eligible := v_depth_qualified AND v_copy_price > 0;

        IF v_eligible
           AND (
             v_fill.direction IN ('reduce', 'close', 'flip')
             OR NOT v_gate_eligible
           ) THEN
        v_gross := trunc(
          v_position.quantity_atoms
            * CASE v_position.side
              WHEN 'long' THEN
                v_copy_price
                  - v_position.entry_price_usd_micros
              ELSE
                v_position.entry_price_usd_micros
                  - v_copy_price
            END
            / 1000000000
        );
        UPDATE wallet_paper_positions
        SET status = 'closed',
            exit_price_usd_micros = v_copy_price,
            realized_gross_usd_micros = v_gross::bigint,
            realized_net_usd_micros =
              (v_gross - modeled_cost_usd_micros)::bigint,
            closed_fill_id = v_fill.fill_id,
            closed_at_ms = v_fill.copy_observed_at_ms,
            updated_at = now()
        WHERE id = v_position.id;
        UPDATE portfolio_runs
        SET state = CASE WHEN EXISTS (
              SELECT 1
              FROM wallet_paper_positions
              WHERE portfolio_run_id = v_portfolio.id
                AND status = 'open'
            ) THEN 'hedged' ELSE 'idle' END::portfolio_state,
            state_version = state_version + 1
        WHERE id = v_portfolio.id;
        v_action := 'close';
        v_reason := CASE
          WHEN v_gate_eligible THEN 'wallet_position_closed'
          ELSE 'wallet_gate_exit'
        END;
        ELSIF NOT v_eligible
              AND (
                v_fill.direction IN ('reduce', 'close', 'flip')
                OR NOT v_gate_eligible
              ) THEN
          v_reason := 'copy_exit_depth_unavailable';
        ELSE
          v_eligible := v_gate_eligible;
          v_action := CASE WHEN v_gate_eligible THEN 'hold' ELSE 'gated' END;
          v_reason := CASE
            WHEN v_gate_eligible THEN 'wallet_position_held'
            ELSE 'wallet_gate_closed'
          END;
        END IF;
      ELSE
        v_side := CASE v_mode
          WHEN 'fade' THEN
            CASE v_fill.side WHEN 'buy' THEN 'short' ELSE 'long' END
          WHEN 'flow' THEN
            CASE WHEN v_signal.signal_ppm > 0 THEN 'long' ELSE 'short' END
          ELSE
            CASE v_fill.side WHEN 'buy' THEN 'long' ELSE 'short' END
        END;
        v_copy_price := CASE v_side
          WHEN 'long' THEN v_fill.copy_ask_price_usd_micros
          ELSE v_fill.copy_bid_price_usd_micros
        END;
        v_depth_qualified := CASE v_side
          WHEN 'long' THEN v_fill.copy_ask_depth_qualified
          ELSE v_fill.copy_bid_depth_qualified
        END;
        SELECT COALESCE(sum(notional_usd_micros), 0)::bigint
        INTO v_open_notional
        FROM wallet_paper_positions
        WHERE portfolio_run_id = v_portfolio.id
          AND status = 'open';
        v_eligible :=
          v_gate_eligible
          AND v_depth_qualified
          AND v_copy_price > 0
          AND v_open_notional + p_notional_usd_micros
            <= v_portfolio.initial_capital_usd_micros
          AND v_fill.direction IN ('open', 'increase', 'flip');
        v_reason := CASE
          WHEN NOT COALESCE(v_score.qualified, false)
            THEN 'wallet_history_insufficient'
          WHEN v_mode = 'mirror' AND v_score.score_ppm <= 0
            THEN 'wallet_not_consistently_profitable'
          WHEN v_mode = 'fade' AND v_score.score_ppm >= 0
            THEN 'wallet_not_consistently_losing'
          WHEN v_mode = 'flow' AND NOT COALESCE(v_signal.qualified, false)
            THEN 'aggregate_flow_unqualified'
          WHEN v_mode = 'flow' AND abs(v_signal.signal_ppm) < 250000
            THEN 'aggregate_flow_weak'
          WHEN NOT v_depth_qualified THEN 'copy_entry_depth_unavailable'
          WHEN v_open_notional + p_notional_usd_micros
            > v_portfolio.initial_capital_usd_micros
            THEN 'portfolio_notional_limit'
          WHEN v_fill.direction NOT IN ('open', 'increase', 'flip')
            THEN 'no_open_position'
          ELSE 'wallet_gate_open'
        END;

        IF v_eligible THEN
        v_quantity := trunc(
          p_notional_usd_micros::numeric * 1000000000
            / v_copy_price
        );
        IF v_quantity > 0 THEN
          INSERT INTO wallet_paper_positions (
            id, portfolio_run_id, mode, wallet, asset, side, status,
            quantity_atoms, notional_usd_micros, entry_price_usd_micros,
            modeled_cost_usd_micros, opened_fill_id, opened_at_ms
          ) VALUES (
            v_fill.fill_id || ':' || v_portfolio.id,
            v_portfolio.id,
            v_mode,
            v_fill.wallet,
            v_fill.asset,
            v_side,
            'open',
            v_quantity,
            p_notional_usd_micros,
            v_copy_price,
            p_modeled_cost_usd_micros,
            v_fill.fill_id,
            v_fill.copy_observed_at_ms
          );
          UPDATE portfolio_runs
          SET state = 'hedged', state_version = state_version + 1
          WHERE id = v_portfolio.id;
          v_action := 'open';
          v_reason := 'wallet_position_opened';
        END IF;
        END IF;
      END IF;

      v_slippage := trunc(
        abs(v_copy_price - v_fill.leader_price_usd_micros)::numeric
          * p_notional_usd_micros
          / v_fill.leader_price_usd_micros
      );

      INSERT INTO wallet_paper_decisions (
        id, portfolio_run_id, fill_id, mode, wallet, asset,
        score_as_of_ms, score_ppm, closed_decisions, signal_ppm,
        copy_latency_ms, slippage_usd_micros, eligible, action, reason_code
      ) VALUES (
        v_fill.fill_id || ':' || v_portfolio.id || ':' || v_mode,
        v_portfolio.id,
        v_fill.fill_id,
        v_mode,
        v_fill.wallet,
        v_fill.asset,
        greatest(v_fill.filled_at_ms - 1, 0),
        COALESCE(v_score.score_ppm, 0),
        COALESCE(v_score.closed_decisions, 0),
        COALESCE(v_signal.signal_ppm, 0),
        v_fill.copy_latency_ms,
        v_slippage::bigint,
        v_eligible,
        v_action,
        v_reason
      ) ON CONFLICT (portfolio_run_id, fill_id, mode) DO NOTHING;
    END LOOP;
  END LOOP;
END;
$$;

CREATE FUNCTION record_wallet_observation(
  p_event jsonb,
  p_source_max_age_ms bigint,
  p_notional_usd_micros bigint,
  p_modeled_cost_usd_micros bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload jsonb;
  v_position jsonb;
  v_fill jsonb;
  v_event_id text;
  v_wallet text;
  v_observed_at_ms bigint;
  v_source_observed_at_ms bigint;
  v_inserted boolean := false;
BEGIN
  IF p_source_max_age_ms <= 0
     OR p_notional_usd_micros <= 0
     OR p_modeled_cost_usd_micros < 0
     OR jsonb_typeof(p_event) <> 'object'
     OR p_event->>'eventType' <> 'WalletObservation'
     OR p_event->>'schemaVersion' <> '1'
     OR p_event->>'eventId' !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR p_event->>'idempotencyKey' !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR p_event->>'rawPayloadHash' !~ '^[0-9a-f]{64}$'
     OR p_event->>'observedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR p_event->>'sourceSlot' !~ '^(0|[1-9][0-9]*)$' THEN
    RAISE EXCEPTION 'invalid wallet observation envelope';
  END IF;
  v_payload := p_event->'payload';
  IF jsonb_typeof(v_payload) <> 'object'
     OR v_payload->>'wallet' !~ '^0x[0-9a-f]{40}$'
     OR v_payload->>'sourceObservedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'accountValueUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'totalNotionalUsdMicros' !~ '^(0|[1-9][0-9]*)$'
     OR v_payload->>'apiLatencyMs' !~ '^(0|[1-9][0-9]*)$'
     OR jsonb_typeof(v_payload->'positions') <> 'array'
     OR jsonb_typeof(v_payload->'fills') <> 'array' THEN
    RAISE EXCEPTION 'invalid wallet observation payload';
  END IF;
  v_event_id := p_event->>'eventId';
  v_wallet := v_payload->>'wallet';
  v_observed_at_ms := (p_event->>'observedAtMs')::bigint;
  v_source_observed_at_ms := (v_payload->>'sourceObservedAtMs')::bigint;
  IF v_source_observed_at_ms > v_observed_at_ms
     OR v_observed_at_ms - v_source_observed_at_ms > p_source_max_age_ms THEN
    RAISE EXCEPTION 'wallet observation source is stale or in the future';
  END IF;

  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    v_event_id,
    1,
    'WalletObservation',
    p_event->>'source',
    v_observed_at_ms,
    (p_event->>'sourceSlot')::bigint,
    p_event->>'sourceSequence',
    p_event->>'idempotencyKey',
    p_event->>'rawPayloadHash',
    p_event
  )
  ON CONFLICT (idempotency_key) DO NOTHING;
  v_inserted := FOUND;
  IF NOT v_inserted THEN
    IF NOT EXISTS (
      SELECT 1
      FROM normalized_events
      WHERE idempotency_key = p_event->>'idempotencyKey'
        AND id = v_event_id
        AND raw_payload_hash = p_event->>'rawPayloadHash'
        AND canonical_payload = p_event
    ) THEN
      RAISE EXCEPTION 'wallet observation idempotency conflict';
    END IF;
    RETURN jsonb_build_object('inserted', false, 'eventId', v_event_id);
  END IF;

  INSERT INTO wallet_observations (
    event_id, wallet, observed_at_ms, source_observed_at_ms,
    account_value_usd_micros, total_notional_usd_micros, api_latency_ms
  ) VALUES (
    v_event_id,
    v_wallet,
    v_observed_at_ms,
    v_source_observed_at_ms,
    (v_payload->>'accountValueUsdMicros')::bigint,
    (v_payload->>'totalNotionalUsdMicros')::bigint,
    (v_payload->>'apiLatencyMs')::bigint
  );

  FOR v_position IN
    SELECT value FROM jsonb_array_elements(v_payload->'positions')
  LOOP
    IF jsonb_typeof(v_position) <> 'object'
       OR v_position->>'asset' !~ '^[A-Z0-9:_-]{1,64}$'
       OR v_position->>'side' NOT IN ('long', 'short')
       OR v_position->>'quantityAtoms' !~ '^[1-9][0-9]*$'
       OR v_position->>'entryPriceUsdMicros' !~ '^[1-9][0-9]*$'
       OR v_position->>'markPriceUsdMicros' !~ '^[1-9][0-9]*$'
       OR v_position->>'leveragePpm' !~ '^[1-9][0-9]*$'
       OR v_position->>'unrealizedPnlUsdMicros'
         !~ '^(0|-?[1-9][0-9]*)$' THEN
      RAISE EXCEPTION 'invalid wallet position';
    END IF;
    INSERT INTO wallet_positions (
      event_id, wallet, asset, side, quantity_atoms,
      entry_price_usd_micros, mark_price_usd_micros, leverage_ppm,
      unrealized_pnl_usd_micros
    ) VALUES (
      v_event_id,
      v_wallet,
      v_position->>'asset',
      v_position->>'side',
      (v_position->>'quantityAtoms')::numeric,
      (v_position->>'entryPriceUsdMicros')::bigint,
      (v_position->>'markPriceUsdMicros')::bigint,
      (v_position->>'leveragePpm')::bigint,
      (v_position->>'unrealizedPnlUsdMicros')::bigint
    );
  END LOOP;

  PERFORM refresh_wallet_flow_signals(v_event_id, v_observed_at_ms);

  FOR v_fill IN
    SELECT value
    FROM jsonb_array_elements(v_payload->'fills')
    ORDER BY (value->>'filledAtMs')::bigint, value->>'fillId'
  LOOP
    IF jsonb_typeof(v_fill) <> 'object'
       OR v_fill->>'fillId' !~ '^[A-Za-z0-9:_-]{1,200}$'
       OR v_fill->>'asset' !~ '^[A-Z0-9:_-]{1,64}$'
       OR v_fill->>'side' NOT IN ('buy', 'sell')
       OR v_fill->>'direction'
         NOT IN ('open', 'increase', 'reduce', 'close', 'flip')
       OR v_fill->>'quantityAtoms' !~ '^[1-9][0-9]*$'
       OR v_fill->>'leaderPriceUsdMicros' !~ '^[1-9][0-9]*$'
       OR v_fill->>'copyBidPriceUsdMicros'
         !~ '^(0|[1-9][0-9]*)$'
       OR v_fill->>'copyAskPriceUsdMicros'
         !~ '^(0|[1-9][0-9]*)$'
       OR v_fill->>'closedPnlUsdMicros' !~ '^(0|-?[1-9][0-9]*)$'
       OR v_fill->>'feeUsdMicros' !~ '^(0|[1-9][0-9]*)$'
       OR v_fill->>'filledAtMs' !~ '^(0|[1-9][0-9]*)$'
       OR v_fill->>'copyObservedAtMs' !~ '^(0|[1-9][0-9]*)$'
       OR v_fill->>'copyLatencyMs' !~ '^(0|[1-9][0-9]*)$'
       OR jsonb_typeof(v_fill->'copyBidDepthQualified') <> 'boolean'
       OR jsonb_typeof(v_fill->'copyAskDepthQualified') <> 'boolean'
       OR (v_fill->>'copyObservedAtMs')::bigint <> v_observed_at_ms
       OR (v_fill->>'filledAtMs')::bigint > v_observed_at_ms
       OR (v_fill->>'copyLatencyMs')::bigint
         < v_observed_at_ms - (v_fill->>'filledAtMs')::bigint
       OR (
         (v_fill->>'copyBidDepthQualified')::boolean
         AND (v_fill->>'copyBidPriceUsdMicros')::bigint = 0
       )
       OR (
         (v_fill->>'copyAskDepthQualified')::boolean
         AND (v_fill->>'copyAskPriceUsdMicros')::bigint = 0
       ) THEN
      RAISE EXCEPTION 'invalid wallet fill';
    END IF;
    INSERT INTO wallet_fills (
      fill_id, source_event_id, wallet, asset, side, direction,
      quantity_atoms, leader_price_usd_micros,
      copy_bid_price_usd_micros, copy_ask_price_usd_micros,
      closed_pnl_usd_micros,
      fee_usd_micros, filled_at_ms, copy_observed_at_ms,
      copy_latency_ms, copy_bid_depth_qualified,
      copy_ask_depth_qualified
    ) VALUES (
      v_fill->>'fillId',
      v_event_id,
      v_wallet,
      v_fill->>'asset',
      v_fill->>'side',
      v_fill->>'direction',
      (v_fill->>'quantityAtoms')::numeric,
      (v_fill->>'leaderPriceUsdMicros')::bigint,
      (v_fill->>'copyBidPriceUsdMicros')::bigint,
      (v_fill->>'copyAskPriceUsdMicros')::bigint,
      (v_fill->>'closedPnlUsdMicros')::bigint,
      (v_fill->>'feeUsdMicros')::bigint,
      (v_fill->>'filledAtMs')::bigint,
      v_observed_at_ms,
      (v_fill->>'copyLatencyMs')::bigint,
      (v_fill->>'copyBidDepthQualified')::boolean,
      (v_fill->>'copyAskDepthQualified')::boolean
    ) ON CONFLICT (fill_id) DO NOTHING;
    IF FOUND THEN
      PERFORM process_wallet_paper_fill(
        v_fill->>'fillId',
        p_notional_usd_micros,
        p_modeled_cost_usd_micros
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('inserted', true, 'eventId', v_event_id);
END;
$$;

CREATE FUNCTION wallet_mode_assessment(p_now_ms bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_started_at bigint;
  v_days bigint;
  v_mode text;
  v_closed integer;
  v_net bigint;
  v_drawdown bigint;
  v_capital bigint;
  v_return_ppm bigint;
  v_sol_ready boolean := false;
  v_sol_score_ppm bigint := 0;
  v_phase1_ready boolean := false;
  v_phase1_score_ppm bigint := 0;
  v_modes jsonb := '{}'::jsonb;
BEGIN
  SELECT min(observed_at_ms) INTO v_started_at FROM wallet_observations;
  v_days := CASE
    WHEN v_started_at IS NULL THEN 0
    ELSE greatest((p_now_ms - v_started_at) / 86400000, 0)
  END;

  WITH prices AS (
    SELECT DISTINCT ON (observed_at_ms)
      observed_at_ms,
      spot_bid_price_usd_micros AS bid,
      first_value(spot_ask_price_usd_micros) OVER (
        ORDER BY observed_at_ms, event_id
      ) AS entry,
      max(spot_bid_price_usd_micros) OVER (
        ORDER BY observed_at_ms, event_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS peak
    FROM funding_observations
    WHERE asset = 'SOL'
      AND source_status = 'valid'
      AND source_fresh
      AND spot_bid_price_usd_micros > 0
      AND spot_ask_price_usd_micros > 0
      AND observed_at_ms BETWEEN v_started_at AND p_now_ms
    ORDER BY observed_at_ms, event_id
  )
  SELECT
    count(*) >= 2,
    COALESCE(
      trunc(
        ((array_agg(bid ORDER BY observed_at_ms DESC))[1] - min(entry))::numeric
          * 1000000 / min(entry)
      ) - max(
        trunc((peak - bid)::numeric * 1000000 / greatest(peak, 1))
      ),
      0
    )::bigint
  INTO v_sol_ready, v_sol_score_ppm
  FROM prices;

  WITH runs AS (
    SELECT p.id, p.initial_capital_usd_micros
    FROM portfolio_runs p
    JOIN comparison_groups g ON g.id = p.comparison_group_id
    WHERE p.variant = 'cross_asset_funding'
      AND p.execution_mode = 'paper'
      AND g.mode = 'independent'
  ),
  economics AS (
    SELECT x.closed_at_ms AS at_ms, x.realized_basis_usd_micros AS amount
    FROM cross_asset_paper_positions x
    JOIN runs r ON r.id = x.portfolio_run_id
    WHERE x.status = 'closed'
      AND x.closed_at_ms BETWEEN v_started_at AND p_now_ms
    UNION ALL
    SELECT f.effective_at_ms, f.usd_value_atoms::bigint
    FROM funding_payments f
    JOIN runs r ON r.id = f.portfolio_run_id
    WHERE f.effective_at_ms BETWEEN v_started_at AND p_now_ms
    UNION ALL
    SELECT n.observed_at_ms, -e.usd_value_atoms::bigint
    FROM ledger_entries e
    JOIN ledger_batches b ON b.id = e.ledger_batch_id
    JOIN runs r ON r.id = b.portfolio_run_id
    JOIN normalized_events n ON n.id = b.event_id
    WHERE e.account_debit IN ('trading_fees', 'borrow_interest_expense')
      AND n.observed_at_ms BETWEEN v_started_at AND p_now_ms
  ),
  grouped AS (
    SELECT at_ms, sum(amount)::bigint AS amount
    FROM economics
    GROUP BY at_ms
  ),
  cumulative AS (
    SELECT
      at_ms,
      sum(amount) OVER (ORDER BY at_ms) AS net
    FROM grouped
  ),
  path AS (
    SELECT
      at_ms,
      net,
      greatest(
        max(net) OVER (
          ORDER BY at_ms ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ),
        0
      ) AS peak
    FROM cumulative
  ),
  capital AS (
    SELECT COALESCE(sum(initial_capital_usd_micros), 0)::bigint AS amount
    FROM runs
  )
  SELECT
    count(path.at_ms) > 0 AND capital.amount > 0,
    COALESCE(
      trunc(
        (array_agg(path.net ORDER BY path.at_ms DESC))[1]
          * 1000000 / NULLIF(capital.amount, 0)
      ) - trunc(
        COALESCE(max(path.peak - path.net), 0)
          * 1000000 / NULLIF(capital.amount, 0)
      ),
      0
    )::bigint
  INTO v_phase1_ready, v_phase1_score_ppm
  FROM capital
  LEFT JOIN path ON true
  GROUP BY capital.amount;

  FOREACH v_mode IN ARRAY ARRAY['flow', 'mirror', 'fade'] LOOP
    SELECT COALESCE(sum(p.initial_capital_usd_micros), 0)::bigint
    INTO v_capital
    FROM portfolio_runs p
    JOIN comparison_groups g ON g.id = p.comparison_group_id
    WHERE p.variant::text = CASE v_mode
        WHEN 'flow' THEN 'hyperliquid_wallet_flow'
        WHEN 'mirror' THEN 'hyperliquid_wallet_mirror'
        ELSE 'hyperliquid_wallet_fade'
      END
      AND p.execution_mode = 'paper'
      AND g.mode = 'independent';
    WITH raw_outcomes AS (
      SELECT
        w.closed_at_ms,
        w.realized_net_usd_micros AS amount
      FROM wallet_paper_positions w
      JOIN portfolio_runs p ON p.id = w.portfolio_run_id
      JOIN comparison_groups g ON g.id = p.comparison_group_id
      WHERE w.mode = v_mode
        AND w.status = 'closed'
        AND g.mode = 'independent'
        AND w.closed_at_ms BETWEEN v_started_at AND p_now_ms
    ),
    outcomes AS (
      SELECT closed_at_ms, sum(amount)::bigint AS amount
      FROM raw_outcomes
      GROUP BY closed_at_ms
    ),
    cumulative AS (
      SELECT
        closed_at_ms,
        sum(amount) OVER (ORDER BY closed_at_ms) AS net
      FROM outcomes
    ),
    path AS (
      SELECT
        net,
        greatest(
          max(net) OVER (
            ORDER BY closed_at_ms
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          ),
          0
        ) AS peak
      FROM cumulative
    )
    SELECT
      (SELECT count(*)::integer FROM raw_outcomes),
      (SELECT COALESCE(sum(amount), 0)::bigint FROM outcomes),
      (SELECT COALESCE(max(peak - net), 0)::bigint FROM path)
    INTO v_closed, v_net, v_drawdown
    ;
    v_return_ppm := trunc(
      (v_net - v_drawdown)::numeric * 1000000 / greatest(v_capital, 1)
    )::bigint;
    v_modes := v_modes || jsonb_build_object(
      v_mode,
      jsonb_build_object(
        'verdict', CASE
          WHEN v_days < 60
            OR v_closed < 20
            OR NOT v_sol_ready
            OR NOT v_phase1_ready THEN 'pending'
          WHEN v_return_ppm > v_sol_score_ppm
            AND v_return_ppm > v_phase1_score_ppm THEN 'go'
          ELSE 'kill'
        END,
        'evidenceDays', v_days::text,
        'closedDecisions', v_closed::text,
        'netUsdMicros', v_net::text,
        'riskAdjustedReturnPpm', v_return_ppm::text,
        'minimumDays', '60',
        'minimumDecisions', '20'
      )
    );
  END LOOP;
  RETURN jsonb_build_object(
    'asOfMs', p_now_ms::text,
    'modes', v_modes,
    'benchmarks', jsonb_build_object(
      'holdingSol', jsonb_build_object(
        'ready', v_sol_ready,
        'riskAdjustedReturnPpm', v_sol_score_ppm::text
      ),
      'phase1', jsonb_build_object(
        'ready', v_phase1_ready,
        'riskAdjustedReturnPpm', v_phase1_score_ppm::text
      )
    )
  );
END;
$$;

ALTER TABLE cross_asset_paper_decisions
  ADD COLUMN wallet_signal_ppm bigint NOT NULL DEFAULT 0,
  ADD COLUMN wallet_signal_qualified boolean NOT NULL DEFAULT false,
  ADD COLUMN wallet_signal_would_allow boolean NOT NULL DEFAULT true;
ALTER TABLE reverse_carry_paper_decisions
  ADD COLUMN wallet_signal_ppm bigint NOT NULL DEFAULT 0,
  ADD COLUMN wallet_signal_qualified boolean NOT NULL DEFAULT false,
  ADD COLUMN wallet_signal_would_allow boolean NOT NULL DEFAULT true;
ALTER TABLE nav_discount_paper_decisions
  ADD COLUMN wallet_signal_ppm bigint NOT NULL DEFAULT 0,
  ADD COLUMN wallet_signal_qualified boolean NOT NULL DEFAULT false,
  ADD COLUMN wallet_signal_would_allow boolean NOT NULL DEFAULT true;
ALTER TABLE cross_venue_paper_decisions
  ADD COLUMN wallet_signal_ppm bigint NOT NULL DEFAULT 0,
  ADD COLUMN wallet_signal_qualified boolean NOT NULL DEFAULT false,
  ADD COLUMN wallet_signal_would_allow boolean NOT NULL DEFAULT true;

CREATE FUNCTION attach_wallet_flow_signal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_signal wallet_flow_signals%ROWTYPE;
  v_asset text;
BEGIN
  IF TG_TABLE_NAME = 'nav_discount_paper_decisions' THEN
    v_asset := 'SOL';
  ELSE
    v_asset := to_jsonb(NEW)->>'asset';
  END IF;
  SELECT * INTO v_signal
  FROM wallet_flow_signals
  WHERE asset = v_asset
    AND observed_at_ms <= (
      SELECT observed_at_ms
      FROM normalized_events
      WHERE id = to_jsonb(NEW)->>'source_event_id'
    )
  ORDER BY observed_at_ms DESC
  LIMIT 1;
  NEW.wallet_signal_ppm := COALESCE(v_signal.signal_ppm, 0);
  NEW.wallet_signal_qualified := COALESCE(v_signal.qualified, false);
  NEW.wallet_signal_would_allow :=
    NOT COALESCE(v_signal.qualified, false)
    OR CASE TG_TABLE_NAME
      WHEN 'cross_asset_paper_decisions' THEN v_signal.signal_ppm >= -250000
      WHEN 'reverse_carry_paper_decisions' THEN v_signal.signal_ppm <= 250000
      WHEN 'nav_discount_paper_decisions' THEN v_signal.signal_ppm >= -250000
      ELSE abs(v_signal.signal_ppm) < 750000
    END;
  RETURN NEW;
END;
$$;

CREATE TRIGGER cross_asset_wallet_flow_signal
BEFORE INSERT ON cross_asset_paper_decisions
FOR EACH ROW EXECUTE FUNCTION attach_wallet_flow_signal();
CREATE TRIGGER reverse_carry_wallet_flow_signal
BEFORE INSERT ON reverse_carry_paper_decisions
FOR EACH ROW EXECUTE FUNCTION attach_wallet_flow_signal();
CREATE TRIGGER nav_discount_wallet_flow_signal
BEFORE INSERT ON nav_discount_paper_decisions
FOR EACH ROW EXECUTE FUNCTION attach_wallet_flow_signal();
CREATE TRIGGER cross_venue_wallet_flow_signal
BEFORE INSERT ON cross_venue_paper_decisions
FOR EACH ROW EXECUTE FUNCTION attach_wallet_flow_signal();

INSERT INTO schema_meta(version) VALUES (37);

COMMIT;
