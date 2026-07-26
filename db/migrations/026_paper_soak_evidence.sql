BEGIN;

CREATE FUNCTION paper_soak_evidence(
  p_now_ms bigint,
  p_max_gap_ms bigint
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH ordered AS (
    SELECT
      event.id,
      event.source,
      event.observed_at_ms,
      event.canonical_payload#>>'{payload,epoch}' AS epoch,
      lag(event.observed_at_ms) OVER (
        ORDER BY event.observed_at_ms, event.id
      ) AS prior_observed_at_ms,
      lag(event.canonical_payload#>>'{payload,epoch}') OVER (
        ORDER BY event.observed_at_ms, event.id
      ) AS prior_epoch
    FROM normalized_events event
    WHERE event.event_type = 'MarketSnapshot'
      AND event.source LIKE 'authoritative:%'
  ),
  snapshots AS (
    SELECT
      count(*) AS snapshot_count,
      count(DISTINCT source) AS source_sessions,
      count(DISTINCT epoch) AS epochs_observed,
      count(*) FILTER (
        WHERE prior_epoch IS NOT NULL AND epoch <> prior_epoch
      ) AS epoch_transitions,
      min(observed_at_ms) AS first_ms,
      max(observed_at_ms) AS last_ms,
      COALESCE(max(observed_at_ms - prior_observed_at_ms), 0) AS max_gap_ms
    FROM ordered
  ),
  paired AS (
    SELECT count(*) AS snapshot_count
    FROM (
      SELECT ordered.id
      FROM ordered
      JOIN opportunity_decisions decision
        ON decision.source_event_id = ordered.id
      GROUP BY ordered.id
      HAVING count(DISTINCT decision.variant) = 2
    ) complete_pair
  ),
  funding AS (
    SELECT count(DISTINCT event.idempotency_key) AS interval_count
    FROM normalized_events event
    CROSS JOIN snapshots
    WHERE event.event_type = 'FundingSettlement'
      AND event.source = 'phoenix-funding:SOL'
      AND snapshots.first_ms IS NOT NULL
      AND event.observed_at_ms >= snapshots.first_ms
  ),
  issues AS (
    SELECT
      (
        SELECT count(*)
        FROM risk_events event
        WHERE event.severity = 'critical'
          AND event.resolved_at IS NULL
          AND snapshots.first_ms IS NOT NULL
          AND extract(epoch FROM event.created_at) * 1000 >= snapshots.first_ms
      ) AS unresolved_critical,
      (
        SELECT count(*)
        FROM reconciliations reconciliation
        WHERE reconciliation.result <> 'matched'
          AND snapshots.first_ms IS NOT NULL
          AND extract(epoch FROM reconciliation.started_at) * 1000 >= snapshots.first_ms
      ) AS reconciliation_mismatches
    FROM snapshots
  ),
  evidence AS (
    SELECT
      snapshots.*,
      paired.snapshot_count AS paired_snapshot_count,
      funding.interval_count,
      issues.unresolved_critical,
      issues.reconciliation_mismatches,
      COALESCE(snapshots.last_ms - snapshots.first_ms, 0) AS elapsed_ms,
      CASE
        WHEN snapshots.last_ms IS NULL THEN p_now_ms
        ELSE GREATEST(p_now_ms - snapshots.last_ms, 0)
      END AS stale_ms
    FROM snapshots
    CROSS JOIN paired
    CROSS JOIN funding
    CROSS JOIN issues
  ),
  result AS (
    SELECT
      evidence.*,
      (
        evidence.snapshot_count > 0
        AND evidence.paired_snapshot_count = evidence.snapshot_count
        AND evidence.max_gap_ms <= p_max_gap_ms
        AND evidence.stale_ms <= p_max_gap_ms
      ) AS continuous,
      (
        evidence.elapsed_ms >= 2592000000
        AND evidence.interval_count >= 100
        AND evidence.epoch_transitions >= 2
        AND evidence.snapshot_count > 0
        AND evidence.paired_snapshot_count = evidence.snapshot_count
        AND evidence.max_gap_ms <= p_max_gap_ms
        AND evidence.stale_ms <= p_max_gap_ms
        AND evidence.unresolved_critical = 0
        AND evidence.reconciliation_mismatches = 0
      ) AS complete
    FROM evidence
  )
  SELECT jsonb_build_object(
    'status', CASE WHEN complete THEN 'passed' ELSE 'collecting' END,
    'authoritativeSnapshots', snapshot_count::text,
    'pairedDecisionSnapshots', paired_snapshot_count::text,
    'fundingIntervals', interval_count::text,
    'epochsObserved', epochs_observed::text,
    'epochTransitions', epoch_transitions::text,
    'sourceSessions', source_sessions::text,
    'firstObservedAtMs', COALESCE(first_ms, 0)::text,
    'lastObservedAtMs', COALESCE(last_ms, 0)::text,
    'elapsedMs', elapsed_ms::text,
    'maximumGapMs', max_gap_ms::text,
    'staleForMs', stale_ms::text,
    'unresolvedCriticalRisks', unresolved_critical::text,
    'reconciliationMismatches', reconciliation_mismatches::text,
    'requiredElapsedMs', '2592000000',
    'requiredFundingIntervals', '100',
    'requiredEpochTransitions', '2',
    'maximumAllowedGapMs', p_max_gap_ms::text,
    'continuous', continuous,
    'complete', complete
  )
  FROM result
  WHERE p_now_ms >= 0 AND p_max_gap_ms > 0;
$$;

INSERT INTO schema_meta(version) VALUES (26);

COMMIT;
