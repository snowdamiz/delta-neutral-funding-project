BEGIN;

CREATE FUNCTION apply_synchronized_paper_entries(
  p_comparison_group_id text,
  p_source_event_id text,
  p_sol_entry jsonb,
  p_jito_entry jsonb
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_members integer;
  v_sol_applied boolean;
  v_jito_applied boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM comparison_groups
    WHERE id = p_comparison_group_id
      AND mode = 'synchronized'
  ) THEN
    RAISE EXCEPTION 'synchronized comparison group not found';
  END IF;

  SELECT count(*)
  INTO v_members
  FROM portfolio_runs
  WHERE comparison_group_id = p_comparison_group_id
    AND (
      (
        id = p_sol_entry->>'portfolioRunId'
        AND variant = 'sol_control'
        AND p_sol_entry#>>'{plan,variant}' = 'sol_control'
      )
      OR (
        id = p_jito_entry->>'portfolioRunId'
        AND variant = 'jitosol_carry'
        AND p_jito_entry#>>'{plan,variant}' = 'jitosol_carry'
      )
    );
  IF v_members <> 2 THEN
    RAISE EXCEPTION 'synchronized entries do not match comparison membership';
  END IF;
  IF COALESCE(p_sol_entry#>>'{plan,perpRequestedQuantityAtoms}', '') !~ '^[1-9][0-9]*$'
     OR COALESCE(p_jito_entry#>>'{plan,perpRequestedQuantityAtoms}', '') !~ '^[1-9][0-9]*$'
     OR (p_sol_entry#>>'{plan,perpRequestedQuantityAtoms}')::numeric
        <> (p_jito_entry#>>'{plan,perpRequestedQuantityAtoms}')::numeric THEN
    RAISE EXCEPTION 'synchronized entries must share positive SOL notional';
  END IF;

  PERFORM 1
  FROM portfolio_runs
  WHERE comparison_group_id = p_comparison_group_id
  ORDER BY id
  FOR UPDATE;

  v_sol_applied := apply_paper_plan(
    p_sol_entry->>'portfolioRunId',
    (p_sol_entry->>'expectedStateVersion')::bigint,
    p_source_event_id,
    p_sol_entry->'plan',
    p_sol_entry->'spotIntent',
    (p_sol_entry->>'spotIntentHash')::char(64),
    p_sol_entry->'perpIntent',
    (p_sol_entry->>'perpIntentHash')::char(64)
  );
  IF NOT v_sol_applied THEN
    RAISE EXCEPTION 'SOL comparison portfolio state changed';
  END IF;

  v_jito_applied := apply_paper_plan(
    p_jito_entry->>'portfolioRunId',
    (p_jito_entry->>'expectedStateVersion')::bigint,
    p_source_event_id,
    p_jito_entry->'plan',
    p_jito_entry->'spotIntent',
    (p_jito_entry->>'spotIntentHash')::char(64),
    p_jito_entry->'perpIntent',
    (p_jito_entry->>'perpIntentHash')::char(64)
  );
  IF NOT v_jito_applied THEN
    RAISE EXCEPTION 'JitoSOL comparison portfolio state changed';
  END IF;

  RETURN true;
END;
$$;

INSERT INTO schema_meta(version) VALUES (16);

COMMIT;
