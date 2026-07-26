BEGIN;

CREATE TABLE risk_decisions (
  id text PRIMARY KEY,
  opportunity_decision_id text NOT NULL REFERENCES opportunity_decisions(id),
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  state_version bigint NOT NULL CHECK (state_version >= 0),
  approved boolean NOT NULL,
  reason_code text NOT NULL CHECK (reason_code <> ''),
  action text NOT NULL CHECK (
    action IN ('skip', 'entry', 'hold', 'rebalance_perp', 'exit', 'emergency')
  ),
  limits_snapshot jsonb NOT NULL CHECK (jsonb_typeof(limits_snapshot) = 'object'),
  health_snapshot jsonb NOT NULL CHECK (jsonb_typeof(health_snapshot) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (portfolio_run_id, source_event_id)
);
CREATE INDEX risk_decisions_latest
  ON risk_decisions(portfolio_run_id, created_at DESC);

CREATE FUNCTION record_paper_risk_decision(
  p_portfolio_id text,
  p_source_event_id text,
  p_state_version bigint,
  p_approved boolean,
  p_reason_code text,
  p_action text,
  p_limits_snapshot jsonb,
  p_health_snapshot jsonb
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_opportunity_decision_id text;
  v_inserted integer;
BEGIN
  SELECT od.id
  INTO v_opportunity_decision_id
  FROM portfolio_runs p
  JOIN opportunity_decisions od
    ON od.source_event_id = p_source_event_id
   AND od.variant = p.variant
  WHERE p.id = p_portfolio_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'risk decision has no matching opportunity';
  END IF;

  INSERT INTO risk_decisions (
    id, opportunity_decision_id, portfolio_run_id, source_event_id,
    state_version, approved, reason_code, action,
    limits_snapshot, health_snapshot
  ) VALUES (
    p_source_event_id || ':' || p_portfolio_id || ':risk',
    v_opportunity_decision_id,
    p_portfolio_id,
    p_source_event_id,
    p_state_version,
    p_approved,
    p_reason_code,
    p_action,
    p_limits_snapshot,
    p_health_snapshot
  )
  ON CONFLICT (portfolio_run_id, source_event_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN v_inserted = 1;
END;
$$;

INSERT INTO schema_meta(version) VALUES (11);

COMMIT;
