BEGIN;

-- Two things the first live run exposed.
--
-- A wallet that is unfollowed keeps its durable cursor, so a wallet whose
-- capture latched gapped stays gapped forever — removing and re-adding it,
-- the obvious operator remedy, changed nothing. Drop the cursor with the
-- wallet so following it again starts a fresh baseline.
CREATE OR REPLACE FUNCTION apply_solana_wallet_config(
  p_idempotency_key text,
  p_reason text,
  p_request_hash text,
  p_wallets jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_existing operator_commands%ROWTYPE;
  v_state solana_wallet_config_state%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_idempotency_key !~ '^[A-Za-z0-9:_-]{1,200}$'
     OR length(p_reason) NOT BETWEEN 1 AND 500
     OR p_request_hash !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_wallets) <> 'array'
     OR jsonb_array_length(p_wallets) > 100
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_wallets) submitted(value)
       WHERE jsonb_typeof(value) <> 'string'
          OR value #>> '{}' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
     )
     OR (
       SELECT count(*) <> count(DISTINCT value #>> '{}')
       FROM jsonb_array_elements(p_wallets) submitted(value)
     ) THEN
    RAISE EXCEPTION 'invalid Solana wallet cohort';
  END IF;

  LOCK TABLE operator_commands, solana_followed_wallets
    IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_existing
  FROM operator_commands
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.action <> 'solana_wallet_config'
       OR v_existing.target <> 'solana_followed_wallets'
       OR v_existing.reason <> p_reason
       OR v_existing.request_hash <> p_request_hash
       OR v_existing.result->'wallets' <> p_wallets THEN
      RAISE EXCEPTION 'idempotency key reused for a different operator command';
    END IF;
    RETURN v_existing.result || jsonb_build_object('duplicate', true);
  END IF;

  DELETE FROM solana_followed_wallets;
  INSERT INTO solana_followed_wallets(wallet, ordinal)
  SELECT value, ordinality - 1
  FROM jsonb_array_elements_text(p_wallets)
    WITH ORDINALITY AS submitted(value, ordinality);

  -- An unfollowed wallet keeps no capture state, so following it again
  -- baselines from its next transaction instead of resuming a cursor nobody
  -- is watching — the remedy an operator already reaches for.
  DELETE FROM solana_wallet_cursors
  WHERE wallet NOT IN (SELECT wallet FROM solana_followed_wallets);

  UPDATE solana_wallet_config_state
  SET version = version + 1,
      updated_at = now()
  WHERE singleton
  RETURNING * INTO v_state;

  v_result := jsonb_build_object(
    'commandId', 'operator:' || p_idempotency_key,
    'status', 'applied',
    'duplicate', false,
    'version', v_state.version::text,
    'count', jsonb_array_length(p_wallets)::text,
    'wallets', p_wallets
  );

  INSERT INTO operator_commands (
    id, action, target, idempotency_key, reason, request_hash,
    control_version, result
  ) VALUES (
    'operator:' || p_idempotency_key,
    'solana_wallet_config',
    'solana_followed_wallets',
    p_idempotency_key,
    p_reason,
    p_request_hash,
    (SELECT version FROM control_state WHERE singleton),
    v_result
  );

  RETURN v_result;
END;
$$;

-- Every candidate was scored against a page of evidence — token program,
-- authorities, concentration, executable quotes at size, organic flow — and
-- none of it left the database. Only watched or held candidates were served,
-- so a rejected mint disappeared entirely and the console could not say what
-- had been examined or why it failed.
CREATE OR REPLACE FUNCTION solana_wallet_flow_read_model() RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH cursor_items AS (
    SELECT jsonb_build_object(
      'wallet', wallet,
      'latestSignature', latest_signature,
      'latestSlot', latest_slot::text,
      'captureComplete', capture_complete,
      'gapReason', gap_reason,
      'observedAtMs', observed_at_ms::text
    ) AS item
    FROM solana_wallet_cursors ORDER BY wallet
  ), latest_candidates AS (
    SELECT DISTINCT ON (s.acquisition_event_id)
      jsonb_strip_nulls(jsonb_build_object(
        'acquisition', e.canonical_payload,
        'snapshotEventId', d.snapshot_event_id,
        'snapshotObservedAtMs', s.observed_at_ms::text,
        'decision', d.decision,
        'reason', d.reason,
        'configId', d.config_id,
        'positionAtoms', CASE WHEN p.status = 'open'
          THEN p.remaining_quantity_atoms::text END
      )) AS item,
      s.acquisition_event_id,
      s.observed_at_ms
    FROM solana_candidate_decisions d
    JOIN solana_candidate_snapshots s ON s.event_id = d.snapshot_event_id
    JOIN normalized_events e ON e.id = s.acquisition_event_id
    LEFT JOIN solana_paper_positions p
      ON p.acquisition_event_id = s.acquisition_event_id
    WHERE (d.decision IN ('WATCH', 'ENTER') OR p.status = 'open')
      AND (p.id IS NULL OR p.status = 'open')
    ORDER BY s.acquisition_event_id, s.observed_at_ms DESC, s.event_id DESC
  ), position_items AS (
    SELECT jsonb_build_object(
      'id', p.id,
      'acquisitionEventId', p.acquisition_event_id,
      'wallet', p.wallet,
      'mint', p.mint,
      'status', p.status,
      'openedAtMs', p.opened_at_ms::text,
      'closedAtMs', CASE WHEN p.closed_at_ms IS NULL THEN NULL ELSE p.closed_at_ms::text END,
      'decisionLatencyMs', p.decision_latency_ms::text,
      'entryCostUsdMicros', p.entry_cost_usd_micros::text,
      'quantityAtoms', p.quantity_atoms::text,
      'remainingQuantityAtoms', p.remaining_quantity_atoms::text,
      'recouped', p.recouped,
      'peakReturnBps', p.peak_return_bps::text,
      'flowBreachCount', p.flow_breach_count,
      'noLiquidityCount', p.no_liquidity_count,
      'migrationCrossed', p.migration_crossed,
      'entryMigrationStatus', p.entry_migration_status,
      'exitReason', p.exit_reason,
      'exitProceedsUsdMicros', CASE WHEN p.exit_proceeds_usd_micros IS NULL
        THEN NULL ELSE p.exit_proceeds_usd_micros::text END,
      'realizedPnlUsdMicros', CASE WHEN p.realized_pnl_usd_micros IS NULL
        THEN NULL ELSE p.realized_pnl_usd_micros::text END,
      'exitLegs', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'legNo', l.leg_no,
          'reason', l.reason,
          'quantityAtoms', l.quantity_atoms::text,
          'quoteUsdMicros', l.quote_usd_micros::text,
          'proceedsUsdMicros', l.proceeds_usd_micros::text,
          'feeUsdMicros', l.fee_usd_micros::text,
          'exitedAtMs', l.exited_at_ms::text
        ) ORDER BY l.leg_no)
        FROM solana_paper_exit_legs l WHERE l.position_id = p.id
      ), '[]'::jsonb)
    ) AS item, p.opened_at_ms, p.id
    FROM solana_paper_positions p
    ORDER BY p.opened_at_ms DESC, p.id DESC
    LIMIT 100
  ), candidate_items AS (
    SELECT jsonb_build_object(
      'snapshotEventId', s.event_id,
      'mint', s.mint,
      'wallet', s.wallet,
      'observedAtMs', s.observed_at_ms::text,
      'decision', d.decision,
      'reason', d.reason,
      'tokenProgram', s.token_program,
      'decimals', s.decimals,
      'migrationStatus', s.migration_status,
      'routeLabels', s.route_labels,
      'marketCapUsdMicros', s.market_cap_usd_micros::text,
      'supplyAtoms', s.supply_atoms::text,
      'buyInputUsdMicros', s.buy_input_usd_micros::text,
      'buyOutputAtoms', s.buy_output_atoms::text,
      'sellOutputUsdMicros', s.sell_output_usd_micros::text,
      'entryPriceImpactBps', s.entry_price_impact_bps,
      'roundTripLossBps', s.round_trip_loss_bps,
      'exitDepthUsdMicros', s.exit_depth_usd_micros::text,
      'topTenHolderConcentrationBps', s.top_ten_holder_concentration_bps,
      'creatorInventoryAtoms', s.creator_inventory_atoms::text,
      'clusterInventoryAtoms', s.cluster_inventory_atoms::text,
      'unlinkedBuyerCount', s.unlinked_buyer_count,
      'netQuoteInflowUsdMicros', s.net_quote_inflow_usd_micros::text,
      'volumeUsdMicros5m', s.volume_usd_micros_5m::text,
      'creatorSold', s.creator_sold,
      'clusterSold', s.cluster_sold,
      'mintAuthorityDisabled', s.mint_authority_disabled,
      'freezeAuthorityDisabled', s.freeze_authority_disabled,
      'walletScoreBps', d.wallet_score_bps,
      'tokenScoreBps', d.token_score_bps,
      'liquidityScoreBps', d.liquidity_score_bps,
      'flowScoreBps', d.flow_score_bps,
      'totalScoreBps', d.total_score_bps
    ) AS item, s.observed_at_ms, s.event_id
    FROM solana_candidate_decisions d
    JOIN solana_candidate_snapshots s ON s.event_id = d.snapshot_event_id
    ORDER BY s.observed_at_ms DESC, s.event_id DESC
    LIMIT 50
  ), action_items AS (
    SELECT jsonb_build_object(
      'id', id,
      'snapshotEventId', snapshot_event_id,
      'acquisitionEventId', acquisition_event_id,
      'action', action,
      'status', status,
      'reason', reason,
      'quoteObservedAtMs', quote_observed_at_ms::text,
      'quoteExpiresAtMs', quote_expires_at_ms::text,
      'processedAtMs', processed_at_ms::text,
      'quantityAtoms', quantity_atoms::text,
      'quoteUsdMicros', quote_usd_micros::text,
      'feeUsdMicros', fee_usd_micros::text,
      'cashDeltaUsdMicros', cash_delta_usd_micros::text
    ) AS item, processed_at_ms, id
    FROM solana_paper_actions
    ORDER BY processed_at_ms DESC, id DESC
    LIMIT 100
  )
  SELECT jsonb_build_object(
    'cursors', COALESCE((SELECT jsonb_agg(item) FROM cursor_items), '[]'::jsonb),
    'openMints', COALESCE((SELECT jsonb_agg(item ORDER BY observed_at_ms, acquisition_event_id)
      FROM latest_candidates), '[]'::jsonb),
    'paperAccount', (
      SELECT jsonb_build_object(
        'initialCapitalUsdMicros', initial_capital_usd_micros::text,
        'reserveCapitalUsdMicros', reserve_capital_usd_micros::text,
        'cashBalanceUsdMicros', cash_balance_usd_micros::text,
        'realizedPnlUsdMicros', realized_pnl_usd_micros::text,
        'updatedAtMs', updated_at_ms::text
      ) FROM solana_paper_accounts WHERE id = 'solana-wallet-flow-paper'
    ),
    'positions', COALESCE((SELECT jsonb_agg(item ORDER BY opened_at_ms DESC, id DESC)
      FROM position_items), '[]'::jsonb),
    'actions', COALESCE((SELECT jsonb_agg(item ORDER BY processed_at_ms DESC, id DESC)
      FROM action_items), '[]'::jsonb),
    'candidates', COALESCE((SELECT jsonb_agg(item ORDER BY observed_at_ms DESC, event_id DESC)
      FROM candidate_items), '[]'::jsonb),
    'strategyConfig', (SELECT jsonb_build_object(
      'id', id, 'configHash', config_hash, 'values', config_json
    ) FROM solana_strategy_configs WHERE active),
    'brokerConfig', (SELECT jsonb_build_object(
      'id', id, 'configHash', config_hash, 'values', config_json
    ) FROM solana_paper_broker_configs WHERE active)
  );
$$;

INSERT INTO schema_meta(version) VALUES (55);

COMMIT;
