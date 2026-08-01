BEGIN;

CREATE TABLE solana_candidate_snapshots (
  event_id text PRIMARY KEY REFERENCES normalized_events(id),
  acquisition_event_id text NOT NULL REFERENCES solana_wallet_acquisitions(event_id),
  wallet text NOT NULL CHECK (wallet ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  signature text NOT NULL,
  mint text NOT NULL CHECK (mint ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  snapshot_status text NOT NULL CHECK (snapshot_status IN ('complete', 'rejected')),
  reject_reason text NOT NULL,
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  source_observed_at_ms bigint NOT NULL CHECK (source_observed_at_ms <= observed_at_ms),
  source_slot bigint NOT NULL CHECK (source_slot >= 0),
  token_program text NOT NULL CHECK (token_program IN ('spl-token', 'token-2022', 'unknown')),
  token_extensions jsonb NOT NULL CHECK (jsonb_typeof(token_extensions) = 'array'),
  mint_authority_disabled boolean NOT NULL,
  freeze_authority_disabled boolean NOT NULL,
  transfer_fee_bps integer NOT NULL CHECK (transfer_fee_bps BETWEEN 0 AND 10000),
  transfer_fee_maximum_atoms numeric NOT NULL CHECK (transfer_fee_maximum_atoms >= 0),
  transfer_fee_buy_atoms numeric NOT NULL CHECK (transfer_fee_buy_atoms >= 0),
  transfer_fee_sell_atoms numeric NOT NULL CHECK (transfer_fee_sell_atoms >= 0),
  supply_atoms numeric NOT NULL CHECK (supply_atoms >= 0),
  decimals integer NOT NULL CHECK (decimals BETWEEN 0 AND 18),
  market_cap_usd_micros numeric NOT NULL CHECK (market_cap_usd_micros >= 0),
  top_ten_holder_concentration_bps integer NOT NULL CHECK (
    top_ten_holder_concentration_bps BETWEEN 0 AND 10000
  ),
  creator text NOT NULL CHECK (creator = '' OR creator ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  creator_inventory_atoms numeric NOT NULL CHECK (creator_inventory_atoms >= 0),
  cluster_inventory_atoms numeric NOT NULL CHECK (cluster_inventory_atoms >= 0),
  market_age_slots bigint NOT NULL CHECK (market_age_slots >= 0),
  migration_status text NOT NULL CHECK (
    migration_status IN ('pre_migration', 'post_migration', 'not_applicable', 'unknown')
  ),
  route_labels jsonb NOT NULL CHECK (jsonb_typeof(route_labels) = 'array'),
  buy_input_usd_micros numeric NOT NULL CHECK (buy_input_usd_micros > 0),
  buy_output_atoms numeric NOT NULL CHECK (buy_output_atoms >= 0),
  sell_output_usd_micros numeric NOT NULL CHECK (sell_output_usd_micros >= 0),
  entry_price_impact_bps integer NOT NULL CHECK (entry_price_impact_bps BETWEEN 0 AND 10000),
  round_trip_loss_bps integer NOT NULL CHECK (round_trip_loss_bps BETWEEN 0 AND 10000),
  exit_depth_usd_micros numeric NOT NULL CHECK (exit_depth_usd_micros >= 0),
  exit_depth_impact_bps integer NOT NULL CHECK (exit_depth_impact_bps BETWEEN 0 AND 10000),
  quote_context_slot bigint NOT NULL CHECK (quote_context_slot >= 0),
  flow_coverage_complete boolean NOT NULL,
  unlinked_buyer_count integer NOT NULL CHECK (unlinked_buyer_count >= 0),
  unlinked_buyer_count_1m integer NOT NULL CHECK (unlinked_buyer_count_1m >= 0),
  unlinked_buyer_count_5m integer NOT NULL CHECK (unlinked_buyer_count_5m >= 0),
  unlinked_buyer_count_1h integer NOT NULL CHECK (unlinked_buyer_count_1h >= 0),
  net_quote_inflow_usd_micros numeric NOT NULL CHECK (net_quote_inflow_usd_micros >= 0),
  net_quote_inflow_usd_micros_1m numeric NOT NULL CHECK (net_quote_inflow_usd_micros_1m >= 0),
  net_quote_inflow_usd_micros_1h numeric NOT NULL CHECK (net_quote_inflow_usd_micros_1h >= 0),
  volume_usd_micros_1m numeric NOT NULL CHECK (volume_usd_micros_1m >= 0),
  volume_usd_micros_5m numeric NOT NULL CHECK (volume_usd_micros_5m >= 0),
  volume_usd_micros_1h numeric NOT NULL CHECK (volume_usd_micros_1h >= 0),
  creator_sold boolean NOT NULL,
  cluster_sold boolean NOT NULL,
  sanctions_hit boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (snapshot_status = 'complete' AND reject_reason = '' AND token_program <> 'unknown')
    OR (snapshot_status = 'rejected' AND reject_reason ~ '^[A-Z][A-Z0-9_]{1,100}$')
  )
);

CREATE INDEX solana_candidate_snapshots_acquisition_time
  ON solana_candidate_snapshots(acquisition_event_id, observed_at_ms DESC);
CREATE INDEX solana_candidate_snapshots_mint_time
  ON solana_candidate_snapshots(mint, observed_at_ms DESC);

CREATE FUNCTION record_solana_candidate_snapshot(p_event jsonb) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload jsonb;
  v_event_id text;
  v_inserted boolean;
  v_key text;
  v_acquisition solana_wallet_acquisitions%ROWTYPE;
BEGIN
  IF jsonb_typeof(p_event) <> 'object'
     OR p_event->>'schemaVersion' <> '1'
     OR p_event->>'eventId' !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR p_event->>'eventType' <> 'SolanaCandidateSnapshot'
     OR p_event->>'observedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR p_event->>'sourceSlot' !~ '^(0|[1-9][0-9]*)$'
     OR COALESCE(p_event->>'sourceSequence', '') = ''
     OR p_event->>'idempotencyKey' !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR p_event->>'rawPayloadHash' !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_event->'payload') <> 'object' THEN
    RAISE EXCEPTION 'invalid Solana candidate snapshot envelope'
      USING ERRCODE = 'check_violation';
  END IF;

  v_payload := p_event->'payload';
  v_event_id := p_event->>'eventId';
  FOREACH v_key IN ARRAY ARRAY[
    'acquisitionEventId', 'wallet', 'signature', 'mint', 'snapshotStatus',
    'rejectReason', 'sourceObservedAtMs', 'tokenProgram', 'tokenExtensions',
    'mintAuthorityDisabled', 'freezeAuthorityDisabled', 'transferFeeBps',
    'transferFeeMaximumAtoms', 'transferFeeBuyAtoms', 'transferFeeSellAtoms',
    'supplyAtoms', 'decimals', 'marketCapUsdMicros',
    'topTenHolderConcentrationBps', 'creator', 'creatorInventoryAtoms',
    'clusterInventoryAtoms', 'marketAgeSlots', 'migrationStatus', 'routeLabels',
    'buyInputUsdMicros', 'buyOutputAtoms', 'sellOutputUsdMicros',
    'entryPriceImpactBps', 'roundTripLossBps', 'exitDepthUsdMicros',
    'exitDepthImpactBps', 'quoteContextSlot', 'flowCoverageComplete',
    'unlinkedBuyerCount', 'unlinkedBuyerCount1m', 'unlinkedBuyerCount5m',
    'unlinkedBuyerCount1h', 'netQuoteInflowUsdMicros',
    'netQuoteInflowUsdMicros1m', 'netQuoteInflowUsdMicros1h',
    'volumeUsdMicros1m', 'volumeUsdMicros5m', 'volumeUsdMicros1h',
    'creatorSold', 'clusterSold', 'sanctionsHit'
  ] LOOP
    IF NOT v_payload ? v_key THEN
      RAISE EXCEPTION 'missing Solana candidate snapshot field: %', v_key
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  FOREACH v_key IN ARRAY ARRAY[
    'sourceObservedAtMs', 'transferFeeBps', 'transferFeeMaximumAtoms',
    'transferFeeBuyAtoms', 'transferFeeSellAtoms', 'supplyAtoms', 'decimals',
    'marketCapUsdMicros', 'topTenHolderConcentrationBps',
    'creatorInventoryAtoms', 'clusterInventoryAtoms', 'marketAgeSlots',
    'buyInputUsdMicros', 'buyOutputAtoms', 'sellOutputUsdMicros',
    'entryPriceImpactBps', 'roundTripLossBps', 'exitDepthUsdMicros',
    'exitDepthImpactBps', 'quoteContextSlot', 'unlinkedBuyerCount',
    'unlinkedBuyerCount1m', 'unlinkedBuyerCount5m', 'unlinkedBuyerCount1h',
    'netQuoteInflowUsdMicros', 'netQuoteInflowUsdMicros1m',
    'netQuoteInflowUsdMicros1h', 'volumeUsdMicros1m', 'volumeUsdMicros5m',
    'volumeUsdMicros1h'
  ] LOOP
    IF v_payload->>v_key !~ '^(0|[1-9][0-9]*)$' THEN
      RAISE EXCEPTION 'invalid Solana candidate snapshot integer: %', v_key
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  FOREACH v_key IN ARRAY ARRAY[
    'mintAuthorityDisabled', 'freezeAuthorityDisabled', 'flowCoverageComplete',
    'creatorSold', 'clusterSold', 'sanctionsHit'
  ] LOOP
    IF jsonb_typeof(v_payload->v_key) IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'invalid Solana candidate snapshot boolean: %', v_key
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  IF v_payload->>'wallet' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
     OR v_payload->>'mint' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
     OR (v_payload->>'creator' <> ''
       AND v_payload->>'creator' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$')
     OR COALESCE(v_payload->>'signature', '') = ''
     OR p_event->>'source' <> 'solana-candidate:' || (v_payload->>'mint')
     OR p_event->>'sourceSequence' <> v_payload->>'signature'
     OR v_payload->>'snapshotStatus' NOT IN ('complete', 'rejected')
     OR v_payload->>'tokenProgram' NOT IN ('spl-token', 'token-2022', 'unknown')
     OR v_payload->>'migrationStatus'
       NOT IN ('pre_migration', 'post_migration', 'not_applicable', 'unknown')
     OR jsonb_typeof(v_payload->'tokenExtensions') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_payload->'tokenExtensions') > 32
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_payload->'tokenExtensions') item
       WHERE jsonb_typeof(item) <> 'string' OR item #>> '{}' = ''
     )
     OR jsonb_typeof(v_payload->'routeLabels') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_payload->'routeLabels') > 32
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_payload->'routeLabels') item
       WHERE jsonb_typeof(item) <> 'string' OR item #>> '{}' = ''
     )
     OR (v_payload->>'sourceObservedAtMs')::bigint > (p_event->>'observedAtMs')::bigint
     OR (v_payload->>'decimals')::integer > 18
     OR (v_payload->>'transferFeeBps')::integer > 10000
     OR (v_payload->>'topTenHolderConcentrationBps')::integer > 10000
     OR (v_payload->>'entryPriceImpactBps')::integer > 10000
     OR (v_payload->>'roundTripLossBps')::integer > 10000
     OR (v_payload->>'exitDepthImpactBps')::integer > 10000
     OR (v_payload->>'buyInputUsdMicros')::numeric = 0
     OR (v_payload->>'snapshotStatus' = 'complete'
       AND (v_payload->>'rejectReason' <> '' OR v_payload->>'tokenProgram' = 'unknown'))
     OR (v_payload->>'snapshotStatus' = 'rejected'
       AND v_payload->>'rejectReason' !~ '^[A-Z][A-Z0-9_]{1,100}$') THEN
    RAISE EXCEPTION 'invalid Solana candidate snapshot payload'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_acquisition
  FROM solana_wallet_acquisitions
  WHERE event_id = v_payload->>'acquisitionEventId';
  IF NOT FOUND
     OR v_acquisition.wallet <> v_payload->>'wallet'
     OR v_acquisition.signature <> v_payload->>'signature'
     OR v_acquisition.output_mint <> v_payload->>'mint'
     OR v_acquisition.slot <> (p_event->>'sourceSlot')::bigint
     OR v_acquisition.observed_at_ms > (v_payload->>'sourceObservedAtMs')::bigint THEN
    RAISE EXCEPTION 'Solana candidate snapshot does not match its acquisition'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    v_event_id, 1, 'SolanaCandidateSnapshot', p_event->>'source',
    (p_event->>'observedAtMs')::bigint, (p_event->>'sourceSlot')::bigint,
    p_event->>'sourceSequence', p_event->>'idempotencyKey',
    p_event->>'rawPayloadHash', p_event
  ) ON CONFLICT (idempotency_key) DO NOTHING;
  v_inserted := FOUND;
  IF NOT v_inserted THEN
    IF NOT EXISTS (
      SELECT 1 FROM normalized_events
      WHERE idempotency_key = p_event->>'idempotencyKey'
        AND id = v_event_id
        AND raw_payload_hash = p_event->>'rawPayloadHash'
        AND canonical_payload = p_event
    ) THEN
      RAISE EXCEPTION 'Solana candidate snapshot idempotency conflict';
    END IF;
    RETURN jsonb_build_object('inserted', false, 'eventId', v_event_id);
  END IF;

  INSERT INTO solana_candidate_snapshots VALUES (
    v_event_id, v_payload->>'acquisitionEventId', v_payload->>'wallet',
    v_payload->>'signature', v_payload->>'mint', v_payload->>'snapshotStatus',
    v_payload->>'rejectReason', (p_event->>'observedAtMs')::bigint,
    (v_payload->>'sourceObservedAtMs')::bigint, (p_event->>'sourceSlot')::bigint,
    v_payload->>'tokenProgram', v_payload->'tokenExtensions',
    (v_payload->>'mintAuthorityDisabled')::boolean,
    (v_payload->>'freezeAuthorityDisabled')::boolean,
    (v_payload->>'transferFeeBps')::integer,
    (v_payload->>'transferFeeMaximumAtoms')::numeric,
    (v_payload->>'transferFeeBuyAtoms')::numeric,
    (v_payload->>'transferFeeSellAtoms')::numeric,
    (v_payload->>'supplyAtoms')::numeric, (v_payload->>'decimals')::integer,
    (v_payload->>'marketCapUsdMicros')::numeric,
    (v_payload->>'topTenHolderConcentrationBps')::integer,
    v_payload->>'creator', (v_payload->>'creatorInventoryAtoms')::numeric,
    (v_payload->>'clusterInventoryAtoms')::numeric,
    (v_payload->>'marketAgeSlots')::bigint, v_payload->>'migrationStatus',
    v_payload->'routeLabels', (v_payload->>'buyInputUsdMicros')::numeric,
    (v_payload->>'buyOutputAtoms')::numeric,
    (v_payload->>'sellOutputUsdMicros')::numeric,
    (v_payload->>'entryPriceImpactBps')::integer,
    (v_payload->>'roundTripLossBps')::integer,
    (v_payload->>'exitDepthUsdMicros')::numeric,
    (v_payload->>'exitDepthImpactBps')::integer,
    (v_payload->>'quoteContextSlot')::bigint,
    (v_payload->>'flowCoverageComplete')::boolean,
    (v_payload->>'unlinkedBuyerCount')::integer,
    (v_payload->>'unlinkedBuyerCount1m')::integer,
    (v_payload->>'unlinkedBuyerCount5m')::integer,
    (v_payload->>'unlinkedBuyerCount1h')::integer,
    (v_payload->>'netQuoteInflowUsdMicros')::numeric,
    (v_payload->>'netQuoteInflowUsdMicros1m')::numeric,
    (v_payload->>'netQuoteInflowUsdMicros1h')::numeric,
    (v_payload->>'volumeUsdMicros1m')::numeric,
    (v_payload->>'volumeUsdMicros5m')::numeric,
    (v_payload->>'volumeUsdMicros1h')::numeric,
    (v_payload->>'creatorSold')::boolean, (v_payload->>'clusterSold')::boolean,
    (v_payload->>'sanctionsHit')::boolean, now()
  );
  RETURN jsonb_build_object('inserted', true, 'eventId', v_event_id);
END;
$$;

INSERT INTO schema_meta(version) VALUES (43);

COMMIT;
