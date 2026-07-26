BEGIN;

CREATE FUNCTION apply_synchronized_paper_position_plans(
  p_comparison_group_id text,
  p_source_event_id text,
  p_sol_record jsonb,
  p_jito_record jsonb
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
        id = p_sol_record->>'portfolioRunId'
        AND variant = 'sol_control'
        AND p_sol_record#>>'{plan,variant}' = 'sol_control'
      )
      OR (
        id = p_jito_record->>'portfolioRunId'
        AND variant = 'jitosol_carry'
        AND p_jito_record#>>'{plan,variant}' = 'jitosol_carry'
      )
    );
  IF v_members <> 2 THEN
    RAISE EXCEPTION 'synchronized position plans do not match comparison membership';
  END IF;
  IF (
    p_sol_record#>>'{plan,action}' IN ('exit', 'emergency')
  ) <> (
    p_jito_record#>>'{plan,action}' IN ('exit', 'emergency')
  ) THEN
    RAISE EXCEPTION 'synchronized position plans must share exit schedule';
  END IF;

  PERFORM 1
  FROM portfolio_runs
  WHERE comparison_group_id = p_comparison_group_id
  ORDER BY id
  FOR UPDATE;

  v_sol_applied := apply_paper_position_plan(
    p_sol_record->>'portfolioRunId',
    (p_sol_record->>'expectedStateVersion')::bigint,
    p_source_event_id,
    p_sol_record->'plan',
    p_sol_record->'spotIntent',
    (p_sol_record->>'spotIntentHash')::char(64),
    p_sol_record->'perpIntent',
    (p_sol_record->>'perpIntentHash')::char(64)
  );
  IF NOT v_sol_applied THEN
    RAISE EXCEPTION 'SOL comparison portfolio state changed';
  END IF;

  v_jito_applied := apply_paper_position_plan(
    p_jito_record->>'portfolioRunId',
    (p_jito_record->>'expectedStateVersion')::bigint,
    p_source_event_id,
    p_jito_record->'plan',
    p_jito_record->'spotIntent',
    (p_jito_record->>'spotIntentHash')::char(64),
    p_jito_record->'perpIntent',
    (p_jito_record->>'perpIntentHash')::char(64)
  );
  IF NOT v_jito_applied THEN
    RAISE EXCEPTION 'JitoSOL comparison portfolio state changed';
  END IF;

  RETURN true;
END;
$$;

INSERT INTO schema_meta(version) VALUES (17);

COMMIT;
