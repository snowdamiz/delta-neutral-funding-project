BEGIN;

-- The monitor never let go.
--
-- A candidate is re-quoted for as long as the read model lists it, and the
-- list filtered to WATCH/ENTER rows BEFORE picking the newest row per
-- acquisition. A candidate watched once and rejected a thousand times
-- afterwards still matched — on its stale WATCH row — and so stayed in the
-- monitor set permanently. 65 mints accumulated 17,180 snapshots, roughly 264
-- re-quotes each, around 250 Jupiter calls a minute.
--
-- That traffic provoked the rate limiting which a bare `catch` in the adapter
-- then recorded as REJECT_NO_ROUND_TRIP: 13,451 candidates written off as
-- untradeable while quoting perfectly well. The adapter now tells a throttled
-- quote from a venue's verdict; this stops manufacturing the throttling.
--
-- Take the newest decision first, then ask whether it is still worth watching.

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
  -- The newest decision per acquisition, whatever it happens to say.
  ), newest_decision AS (
    SELECT DISTINCT ON (s.acquisition_event_id)
      d.snapshot_event_id, d.decision, d.reason, d.config_id,
      s.acquisition_event_id, s.observed_at_ms
    FROM solana_candidate_decisions d
    JOIN solana_candidate_snapshots s ON s.event_id = d.snapshot_event_id
    ORDER BY s.acquisition_event_id, s.observed_at_ms DESC, s.event_id DESC
  ), latest_candidates AS (
    SELECT
      jsonb_strip_nulls(jsonb_build_object(
        'acquisition', e.canonical_payload,
        'snapshotEventId', n.snapshot_event_id,
        'snapshotObservedAtMs', n.observed_at_ms::text,
        'decision', n.decision,
        'reason', n.reason,
        'configId', n.config_id,
        'positionAtoms', CASE WHEN p.status = 'open'
          THEN p.remaining_quantity_atoms::text END
      )) AS item,
      n.acquisition_event_id,
      n.observed_at_ms
    FROM newest_decision n
    JOIN normalized_events e ON e.id = n.acquisition_event_id
    JOIN solana_wallet_acquisitions a ON a.event_id = n.acquisition_event_id
    LEFT JOIN solana_paper_positions p
      ON p.acquisition_event_id = n.acquisition_event_id
    WHERE p.status = 'open'
       -- An unentered candidate is worth re-quoting only while entering it is
       -- still the trade. How long it has been watched — its newest snapshot
       -- against its acquisition — is measured against the horizon the broker
       -- already uses to give up on a position going nowhere. Wall-clock has
       -- no place in a read model over recorded observations.
       OR (n.decision IN ('WATCH', 'ENTER')
           AND p.id IS NULL
           AND n.observed_at_ms - a.observed_at_ms
               < (SELECT (config_json->>'flatTimeStopMs')::bigint
                  FROM solana_paper_broker_configs WHERE active))
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

INSERT INTO schema_meta(version) VALUES (61);

COMMIT;
