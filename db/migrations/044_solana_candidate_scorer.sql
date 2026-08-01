BEGIN;

CREATE TABLE solana_strategy_configs (
  id text PRIMARY KEY CHECK (id ~ '^[a-z0-9-]{1,100}$'),
  config_hash char(64) NOT NULL UNIQUE CHECK (config_hash ~ '^[0-9a-f]{64}$'),
  config_json jsonb NOT NULL CHECK (jsonb_typeof(config_json) = 'object'),
  frozen boolean NOT NULL DEFAULT true CHECK (frozen),
  active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX solana_strategy_configs_one_active
  ON solana_strategy_configs(active) WHERE active;

INSERT INTO solana_strategy_configs (id, config_hash, config_json, active) VALUES (
  'solana-wallet-flow-v1',
  '314a9642aa2c18f1d4ffc2924167fa1b70ea228ec904915efc702803fb1dc055',
  '{
    "maxEntryImpactBps":"200",
    "maxLinkedInventoryExitDepthBps":"10000",
    "maxRoundTripLossBps":"800",
    "maxSnapshotAgeMs":"30000",
    "maxTopTenHolderConcentrationBps":"4000",
    "minimumExitDepthMultiple":"10",
    "minimumOrganicBuyerCount":"10",
    "minimumOrganicInflowUsdMicros":"1",
    "minimumWalletHistory":"20",
    "positionUsdMicros":"10000000"
  }'::jsonb,
  true
);

CREATE TABLE solana_candidate_decisions (
  snapshot_event_id text PRIMARY KEY REFERENCES solana_candidate_snapshots(event_id),
  config_id text NOT NULL REFERENCES solana_strategy_configs(id),
  decision text NOT NULL CHECK (decision IN ('ENTER', 'WATCH', 'REJECT')),
  reason text NOT NULL CHECK (reason ~ '^[A-Z][A-Z0-9_]{1,100}$'),
  wallet_score_bps integer NOT NULL CHECK (wallet_score_bps BETWEEN 0 AND 10000),
  token_score_bps integer NOT NULL CHECK (token_score_bps BETWEEN 0 AND 10000),
  liquidity_score_bps integer NOT NULL CHECK (liquidity_score_bps BETWEEN 0 AND 10000),
  flow_score_bps integer NOT NULL CHECK (flow_score_bps BETWEEN 0 AND 10000),
  total_score_bps integer NOT NULL CHECK (total_score_bps BETWEEN 0 AND 10000),
  evidence jsonb NOT NULL CHECK (jsonb_typeof(evidence) = 'object'),
  decided_at_ms bigint NOT NULL CHECK (decided_at_ms >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX solana_candidate_decisions_latest
  ON solana_candidate_decisions(decided_at_ms DESC, decision, snapshot_event_id);

CREATE FUNCTION evaluate_solana_candidate(
  p_snapshot_event_id text,
  p_config_id text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_snapshot solana_candidate_snapshots%ROWTYPE;
  v_acquisition solana_wallet_acquisitions%ROWTYPE;
  v_config solana_strategy_configs%ROWTYPE;
  v_prior_eligible integer;
  v_linked_inventory_usd numeric;
  v_linked_inventory_bps integer;
  v_organic boolean;
  v_decision text;
  v_reason text;
  v_wallet_score integer;
  v_token_score integer;
  v_liquidity_score integer;
  v_flow_score integer;
  v_total_score integer;
BEGIN
  SELECT * INTO STRICT v_snapshot
  FROM solana_candidate_snapshots WHERE event_id = p_snapshot_event_id;
  SELECT * INTO STRICT v_acquisition
  FROM solana_wallet_acquisitions WHERE event_id = v_snapshot.acquisition_event_id;
  SELECT * INTO STRICT v_config
  FROM solana_strategy_configs WHERE id = p_config_id AND frozen;

  SELECT count(*)::integer INTO v_prior_eligible
  FROM solana_candidate_snapshots prior
  JOIN solana_wallet_acquisitions acquisition
    ON acquisition.event_id = prior.acquisition_event_id
  WHERE prior.wallet = v_snapshot.wallet
    AND prior.snapshot_status = 'complete'
    AND acquisition.confirmed_at_ms < v_acquisition.confirmed_at_ms;

  v_linked_inventory_usd := CASE WHEN v_snapshot.buy_output_atoms = 0 THEN 0
    ELSE trunc(
      (v_snapshot.creator_inventory_atoms + v_snapshot.cluster_inventory_atoms)
      * v_snapshot.buy_input_usd_micros / v_snapshot.buy_output_atoms
    ) END;
  v_linked_inventory_bps := CASE WHEN v_snapshot.exit_depth_usd_micros = 0 THEN 10000
    ELSE LEAST(10000, trunc(
      v_linked_inventory_usd * 10000 / v_snapshot.exit_depth_usd_micros
    )::integer) END;
  v_organic := v_snapshot.flow_coverage_complete
    AND v_snapshot.unlinked_buyer_count >=
      (v_config.config_json->>'minimumOrganicBuyerCount')::integer
    AND v_snapshot.net_quote_inflow_usd_micros >=
      (v_config.config_json->>'minimumOrganicInflowUsdMicros')::numeric;

  v_wallet_score := LEAST(10000,
    LEAST(5000, v_prior_eligible * 250)
    + CASE WHEN NOT v_snapshot.creator_sold AND NOT v_snapshot.cluster_sold THEN 2500 ELSE 0 END
    + CASE WHEN v_linked_inventory_bps <=
        (v_config.config_json->>'maxLinkedInventoryExitDepthBps')::integer
      THEN 2500 ELSE 0 END
  );
  v_token_score :=
    CASE WHEN v_snapshot.token_program <> 'unknown' THEN 2500 ELSE 0 END
    + CASE WHEN v_snapshot.mint_authority_disabled THEN 2500 ELSE 0 END
    + CASE WHEN v_snapshot.freeze_authority_disabled THEN 2500 ELSE 0 END
    + CASE WHEN v_snapshot.top_ten_holder_concentration_bps <=
        (v_config.config_json->>'maxTopTenHolderConcentrationBps')::integer
      THEN 2500 ELSE 0 END;
  v_liquidity_score := GREATEST(0, 10000
    - v_snapshot.entry_price_impact_bps * 10
    - v_snapshot.round_trip_loss_bps * 5);
  v_flow_score := LEAST(10000,
    v_snapshot.unlinked_buyer_count * 800
    + LEAST(2000, trunc(v_snapshot.net_quote_inflow_usd_micros / 10000)::integer)
  );
  v_total_score := trunc(
    (v_wallet_score + v_token_score + v_liquidity_score + v_flow_score) / 4
  );

  IF v_snapshot.snapshot_status = 'rejected' THEN
    v_decision := 'REJECT'; v_reason := v_snapshot.reject_reason;
  ELSIF v_snapshot.observed_at_ms - v_snapshot.source_observed_at_ms >
      (v_config.config_json->>'maxSnapshotAgeMs')::bigint THEN
    v_decision := 'REJECT'; v_reason := 'REJECT_STALE_SNAPSHOT';
  ELSIF v_snapshot.sanctions_hit THEN
    v_decision := 'REJECT'; v_reason := 'SANCTIONS_HIT';
  ELSIF NOT v_snapshot.mint_authority_disabled THEN
    v_decision := 'REJECT'; v_reason := 'MINT_AUTHORITY_ENABLED';
  ELSIF NOT v_snapshot.freeze_authority_disabled THEN
    v_decision := 'REJECT'; v_reason := 'FREEZE_AUTHORITY_ENABLED';
  ELSIF v_snapshot.creator_sold THEN
    v_decision := 'REJECT'; v_reason := 'CREATOR_SOLD';
  ELSIF v_snapshot.cluster_sold THEN
    v_decision := 'REJECT'; v_reason := 'CLUSTER_SOLD';
  ELSIF v_snapshot.entry_price_impact_bps >
      (v_config.config_json->>'maxEntryImpactBps')::integer THEN
    v_decision := 'REJECT'; v_reason := 'ENTRY_IMPACT';
  ELSIF v_snapshot.round_trip_loss_bps >
      (v_config.config_json->>'maxRoundTripLossBps')::integer THEN
    v_decision := 'REJECT'; v_reason := 'ROUND_TRIP_LOSS';
  ELSIF v_snapshot.exit_depth_usd_micros <
      (v_config.config_json->>'positionUsdMicros')::numeric
      * (v_config.config_json->>'minimumExitDepthMultiple')::numeric THEN
    v_decision := 'REJECT'; v_reason := 'EXIT_DEPTH';
  ELSIF v_snapshot.top_ten_holder_concentration_bps >
      (v_config.config_json->>'maxTopTenHolderConcentrationBps')::integer THEN
    v_decision := 'REJECT'; v_reason := 'HOLDER_CONCENTRATION';
  ELSIF v_linked_inventory_bps >
      (v_config.config_json->>'maxLinkedInventoryExitDepthBps')::integer THEN
    v_decision := 'REJECT'; v_reason := 'LINKED_INVENTORY';
  ELSIF NOT v_snapshot.flow_coverage_complete THEN
    v_decision := 'WATCH'; v_reason := 'WATCH_FLOW_INCOMPLETE';
  ELSIF NOT v_organic THEN
    v_decision := 'WATCH'; v_reason := 'WATCH_INDEPENDENT_CONFIRMATION';
  ELSE
    v_decision := 'ENTER'; v_reason := 'ELIGIBLE';
  END IF;

  RETURN jsonb_build_object(
    'configId', v_config.id,
    'configHash', v_config.config_hash,
    'decision', v_decision,
    'reason', v_reason,
    'walletScoreBps', v_wallet_score::text,
    'tokenScoreBps', v_token_score::text,
    'liquidityScoreBps', v_liquidity_score::text,
    'flowScoreBps', v_flow_score::text,
    'totalScoreBps', v_total_score::text,
    'priorEligibleAcquisitions', v_prior_eligible::text,
    'walletHistoryQualified', v_prior_eligible >=
      (v_config.config_json->>'minimumWalletHistory')::integer,
    'organicConfirmation', v_organic,
    'linkedInventoryUsdMicros', v_linked_inventory_usd::text,
    'linkedInventoryExitDepthBps', v_linked_inventory_bps::text,
    'evaluatedAtMs', v_snapshot.observed_at_ms::text
  );
END;
$$;

CREATE FUNCTION record_solana_candidate_decision(p_snapshot_event_id text) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_config_id text;
  v_evidence jsonb;
BEGIN
  SELECT id INTO STRICT v_config_id FROM solana_strategy_configs WHERE active;
  v_evidence := evaluate_solana_candidate(p_snapshot_event_id, v_config_id);
  INSERT INTO solana_candidate_decisions (
    snapshot_event_id, config_id, decision, reason, wallet_score_bps,
    token_score_bps, liquidity_score_bps, flow_score_bps, total_score_bps,
    evidence, decided_at_ms
  ) VALUES (
    p_snapshot_event_id, v_config_id, v_evidence->>'decision', v_evidence->>'reason',
    (v_evidence->>'walletScoreBps')::integer,
    (v_evidence->>'tokenScoreBps')::integer,
    (v_evidence->>'liquidityScoreBps')::integer,
    (v_evidence->>'flowScoreBps')::integer,
    (v_evidence->>'totalScoreBps')::integer,
    v_evidence, (v_evidence->>'evaluatedAtMs')::bigint
  ) ON CONFLICT (snapshot_event_id) DO NOTHING;
END;
$$;

CREATE FUNCTION score_solana_candidate_after_snapshot() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM record_solana_candidate_decision(NEW.event_id);
  RETURN NEW;
END;
$$;
CREATE TRIGGER score_solana_candidate_after_snapshot
AFTER INSERT ON solana_candidate_snapshots
FOR EACH ROW EXECUTE FUNCTION score_solana_candidate_after_snapshot();

DO $$
DECLARE
  v_event_id text;
BEGIN
  FOR v_event_id IN SELECT event_id FROM solana_candidate_snapshots ORDER BY observed_at_ms, event_id LOOP
    PERFORM record_solana_candidate_decision(v_event_id);
  END LOOP;
END;
$$;

INSERT INTO schema_meta(version) VALUES (44);

COMMIT;
