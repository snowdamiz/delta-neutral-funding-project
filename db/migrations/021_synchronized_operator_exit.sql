BEGIN;

DO $migration$
DECLARE
  v_definition text;
  v_rewritten text;
BEGIN
  SELECT pg_get_functiondef(
    'apply_operator_command(text,text,text,text,text)'::regprocedure
  ) INTO v_definition;

  v_rewritten := replace(
    v_definition,
    $old$AND p_target NOT IN ('local-sol-control', 'local-jitosol-carry')$old$,
    $new$AND p_target NOT IN (
       'local-sol-control',
       'local-jitosol-carry',
       'local-sync-sol-control',
       'local-sync-jitosol-carry'
     )$new$
  );
  v_rewritten := replace(
    v_rewritten,
    $old$WHERE id = p_target
      AND state = 'hedged';$old$,
    $new$WHERE state = 'hedged'
      AND (
        id = p_target
        OR (
          p_target IN ('local-sync-sol-control', 'local-sync-jitosol-carry')
          AND id IN ('local-sync-sol-control', 'local-sync-jitosol-carry')
        )
      );$new$
  );
  IF v_rewritten = v_definition THEN
    RAISE EXCEPTION 'operator exit function was not rewritten';
  END IF;
  EXECUTE v_rewritten;
END;
$migration$;

INSERT INTO schema_meta(version) VALUES (21);

COMMIT;
