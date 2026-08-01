\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_result jsonb;
BEGIN
  UPDATE strategy_controls SET enabled = false;

  IF position('strategy_enabled(''cross_asset_funding'')' IN
       pg_get_functiondef('run_cross_asset_paper_scan'::regproc)) = 0
     OR position('strategy_enabled(''negative_funding_reverse'')' IN
       pg_get_functiondef('run_reverse_carry_paper_scan'::regproc)) = 0
     OR position('strategy_enabled(''jitosol_nav_discount'')' IN
       pg_get_functiondef('run_nav_discount_paper_cycle'::regproc)) = 0
     OR position('strategy_enabled(''cross_venue_funding'')' IN
       pg_get_functiondef('run_cross_venue_paper_scan'::regproc)) = 0
     OR position('strategy_enabled(v_variant)' IN
       pg_get_functiondef('process_wallet_paper_fill'::regproc)) = 0 THEN
    RAISE EXCEPTION 'one or more strategy entry gates are missing';
  END IF;

  v_result := apply_strategy_control(
    'jitosol_carry',
    true,
    'strategy-control:start',
    'started from contract test',
    repeat('a', 64)
  );
  IF v_result->>'status' <> 'applied'
     OR v_result->>'strategy' <> 'jitosol_carry'
     OR NOT (v_result->>'enabled')::boolean
     OR NOT strategy_enabled('jitosol_carry')
     OR strategy_enabled('sol_control') THEN
    RAISE EXCEPTION 'strategy start was not isolated: %', v_result;
  END IF;

  v_result := apply_strategy_control(
    'jitosol_carry',
    true,
    'strategy-control:start',
    'started from contract test',
    repeat('a', 64)
  );
  IF NOT (v_result->>'duplicate')::boolean THEN
    RAISE EXCEPTION 'exact strategy control retry was not idempotent';
  END IF;

  BEGIN
    PERFORM apply_strategy_control(
      'jitosol_carry',
      false,
      'strategy-control:start',
      'conflicting retry',
      repeat('b', 64)
    );
    RAISE EXCEPTION 'conflicting strategy control retry was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'idempotency key reused for a different operator command' THEN
        RAISE;
      END IF;
  END;

  v_result := apply_strategy_control(
    'jitosol_carry',
    false,
    'strategy-control:stop',
    'stopped from contract test',
    repeat('c', 64)
  );
  IF (v_result->>'enabled')::boolean OR strategy_enabled('jitosol_carry') THEN
    RAISE EXCEPTION 'strategy stop did not persist: %', v_result;
  END IF;

  BEGIN
    PERFORM apply_strategy_control(
      'not_a_strategy',
      true,
      'strategy-control:invalid',
      'invalid target',
      repeat('d', 64)
    );
    RAISE EXCEPTION 'unknown strategy was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'unknown strategy' THEN
        RAISE;
      END IF;
  END;
END;
$$;

ROLLBACK;
