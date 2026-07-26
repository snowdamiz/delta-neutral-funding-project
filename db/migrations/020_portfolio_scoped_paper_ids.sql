BEGIN;

DO $migration$
DECLARE
  v_signature text;
  v_definition text;
  v_rewritten text;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'apply_paper_entry_plan(text,bigint,text,jsonb,jsonb,character,jsonb,character)',
    'apply_paper_position_plan(text,bigint,text,jsonb,jsonb,character,jsonb,character)',
    'apply_paper_recovery_plan(text,bigint,text,jsonb,jsonb,character,jsonb,character)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure(v_signature))
    INTO v_definition;
    IF v_definition IS NULL THEN
      RAISE EXCEPTION 'paper function not found: %', v_signature;
    END IF;

    v_rewritten := replace(
      v_definition,
      $needle$p_source_event_id || ':' || (p_plan->>'variant')$needle$,
      $replacement$p_source_event_id || ':' || p_portfolio_id || ':' || (p_plan->>'variant')$replacement$
    );
    IF v_rewritten = v_definition THEN
      RAISE EXCEPTION 'paper function identity was not rewritten: %', v_signature;
    END IF;
    EXECUTE v_rewritten;
  END LOOP;
END;
$migration$;

INSERT INTO schema_meta(version) VALUES (20);

COMMIT;
