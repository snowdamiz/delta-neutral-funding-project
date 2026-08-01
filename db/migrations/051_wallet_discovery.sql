BEGIN;

-- Wallet discovery: the cohort is the strategy's actual edge, and today it is
-- hand-typed. Every candidate snapshot already carries a price observation and
-- a scan of the mint's recent buyers; this migration persists the earliest
-- unlinked buyers per mint and nominates the wallets that were repeatedly
-- early into mints that later ran. Nominations are read-only evidence: a
-- wallet joins the followed cohort only through the existing audited
-- solana_wallet_config mutation.

CREATE TABLE solana_candidate_buyers (
  mint text NOT NULL CHECK (mint ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  owner text NOT NULL CHECK (owner ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  first_seen_ms bigint NOT NULL CHECK (first_seen_ms >= 0),
  bought_atoms numeric NOT NULL CHECK (bought_atoms > 0),
  last_snapshot_event_id text NOT NULL REFERENCES solana_candidate_snapshots(event_id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (mint, owner)
);
CREATE INDEX solana_candidate_buyers_owner ON solana_candidate_buyers(owner);

-- The adapter appends an optional flowBuyers array (earliest unlinked buyers
-- seen by the flow scan) to each snapshot payload. Older snapshots without it
-- are simply skipped.
CREATE FUNCTION record_solana_candidate_buyers() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_buyers jsonb;
  v_buyer jsonb;
BEGIN
  SELECT canonical_payload->'payload'->'flowBuyers' INTO v_buyers
  FROM normalized_events WHERE id = NEW.event_id;
  IF v_buyers IS NULL OR jsonb_typeof(v_buyers) <> 'array' THEN
    RETURN NEW;
  END IF;
  IF jsonb_array_length(v_buyers) > 20 THEN
    RAISE EXCEPTION 'snapshot flow buyers exceed the bound'
      USING ERRCODE = 'check_violation';
  END IF;
  FOR v_buyer IN SELECT * FROM jsonb_array_elements(v_buyers) LOOP
    IF v_buyer->>'owner' !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
       OR v_buyer->>'firstSeenMs' !~ '^(0|[1-9][0-9]*)$'
       OR v_buyer->>'boughtAtoms' !~ '^[1-9][0-9]*$' THEN
      RAISE EXCEPTION 'invalid snapshot flow buyer'
        USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO solana_candidate_buyers (
      mint, owner, first_seen_ms, bought_atoms, last_snapshot_event_id
    ) VALUES (
      NEW.mint, v_buyer->>'owner', (v_buyer->>'firstSeenMs')::bigint,
      (v_buyer->>'boughtAtoms')::numeric, NEW.event_id
    )
    ON CONFLICT (mint, owner) DO UPDATE SET
      first_seen_ms = LEAST(solana_candidate_buyers.first_seen_ms,
        EXCLUDED.first_seen_ms),
      bought_atoms = GREATEST(solana_candidate_buyers.bought_atoms,
        EXCLUDED.bought_atoms),
      last_snapshot_event_id = EXCLUDED.last_snapshot_event_id,
      updated_at = now();
  END LOOP;
  RETURN NEW;
END;
$$;
CREATE TRIGGER record_solana_candidate_buyers
AFTER INSERT ON solana_candidate_snapshots
FOR EACH ROW EXECUTE FUNCTION record_solana_candidate_buyers();

-- Nominations: wallets repeatedly early into mints whose executable price
-- later reached the runner multiple. Price per atom is buy_input/buy_output,
-- normalized across config-size changes.
CREATE FUNCTION solana_wallet_discovery(
  p_runner_multiple_bps bigint,
  p_max_rank integer,
  p_limit integer
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH firsts AS (
    SELECT DISTINCT ON (mint)
      mint, creator, observed_at_ms, buy_input_usd_micros, buy_output_atoms
    FROM solana_candidate_snapshots
    WHERE snapshot_status = 'complete' AND buy_output_atoms > 0
    ORDER BY mint, observed_at_ms, event_id
  ), runners AS (
    SELECT f.mint, f.creator, f.observed_at_ms AS first_observed_at_ms,
      max(
        later.buy_input_usd_micros * f.buy_output_atoms * 10000
        / (later.buy_output_atoms * f.buy_input_usd_micros)
      )::bigint AS peak_multiple_bps
    FROM firsts f
    JOIN solana_candidate_snapshots later ON later.mint = f.mint
      AND later.snapshot_status = 'complete'
      AND later.buy_output_atoms > 0
      AND later.observed_at_ms > f.observed_at_ms
    GROUP BY f.mint, f.creator, f.observed_at_ms
    HAVING max(
      later.buy_input_usd_micros * f.buy_output_atoms * 10000
      / (later.buy_output_atoms * f.buy_input_usd_micros)
    ) >= p_runner_multiple_bps
  ), early AS (
    SELECT b.owner, b.mint, r.peak_multiple_bps, b.first_seen_ms,
      rank() OVER (PARTITION BY b.mint ORDER BY b.first_seen_ms, b.owner)
        AS buy_rank
    FROM solana_candidate_buyers b
    JOIN runners r ON r.mint = b.mint
    WHERE b.owner <> r.creator
  ), nominations AS (
    SELECT owner,
      count(*) AS runner_count,
      min(buy_rank) AS best_rank,
      max(peak_multiple_bps) AS best_multiple_bps,
      jsonb_agg(jsonb_build_object(
        'mint', mint,
        'peakMultipleBps', peak_multiple_bps::text,
        'buyRank', buy_rank,
        'firstSeenMs', first_seen_ms::text
      ) ORDER BY first_seen_ms) AS evidence
    FROM early
    WHERE buy_rank <= p_max_rank
    GROUP BY owner
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'wallet', n.owner,
    'runnerCount', n.runner_count,
    'bestRank', n.best_rank,
    'bestMultipleBps', n.best_multiple_bps::text,
    'alreadyFollowed', EXISTS (
      SELECT 1 FROM solana_followed_wallets w WHERE w.wallet = n.owner
    ),
    'evidence', n.evidence
  ) ORDER BY n.runner_count DESC, n.best_rank, n.owner), '[]'::jsonb)
  FROM (
    SELECT * FROM nominations
    ORDER BY runner_count DESC, best_rank, owner
    LIMIT p_limit
  ) n;
$$;

INSERT INTO schema_meta(version) VALUES (51);

COMMIT;
