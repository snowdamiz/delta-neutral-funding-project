\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_result jsonb;
BEGIN
  UPDATE strategy_controls SET enabled = false;
  DELETE FROM solana_followed_wallets;

  BEGIN
    PERFORM apply_strategy_control(
      'solana_wallet_flow_quant',
      true,
      'strategy-control:missing-solana-wallet',
      'must reject an empty cohort',
      repeat('f', 64)
    );
    RAISE EXCEPTION 'Solana wallet strategy started without wallets';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'strategy requires at least one configured Solana wallet' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO solana_followed_wallets(wallet, ordinal)
  VALUES ('11111111111111111111111111111111', 0);
  PERFORM apply_strategy_control(
    'solana_wallet_flow_quant',
    true,
    'strategy-control:configured-solana-wallet',
    'start with a configured cohort',
    repeat('2', 64)
  );
  DELETE FROM solana_followed_wallets;
  UPDATE solana_wallet_config_state SET version = version + 1 WHERE singleton;
  IF strategy_enabled('solana_wallet_flow_quant') THEN
    RAISE EXCEPTION 'Solana wallet strategy remained enabled with an empty cohort';
  END IF;

  IF position('strategy_enabled(''cross_asset_funding'')' IN
       pg_get_functiondef('run_cross_asset_paper_scan'::regproc)) = 0
     OR position('strategy_enabled(''negative_funding_reverse'')' IN
       pg_get_functiondef('run_reverse_carry_paper_scan'::regproc)) = 0
     OR position('strategy_enabled(''jitosol_nav_discount'')' IN
       pg_get_functiondef('run_nav_discount_paper_cycle'::regproc)) = 0
     OR position('strategy_enabled(''solana_wallet_flow_quant'')' IN
       pg_get_functiondef('plan_solana_paper_action'::regproc)) = 0 THEN
    RAISE EXCEPTION 'one or more strategy entry gates are missing';
  END IF;

  v_result := apply_strategy_control(
    'cross_asset_funding',
    true,
    'strategy-control:start',
    'started from contract test',
    repeat('a', 64)
  );
  IF v_result->>'status' <> 'applied'
     OR v_result->>'strategy' <> 'cross_asset_funding'
     OR NOT (v_result->>'enabled')::boolean
     OR NOT strategy_enabled('cross_asset_funding')
     OR strategy_enabled('negative_funding_reverse') THEN
    RAISE EXCEPTION 'strategy start was not isolated: %', v_result;
  END IF;

  v_result := apply_strategy_control(
    'cross_asset_funding',
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
      'cross_asset_funding',
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
    'cross_asset_funding',
    false,
    'strategy-control:stop',
    'stopped from contract test',
    repeat('c', 64)
  );
  IF (v_result->>'enabled')::boolean OR strategy_enabled('cross_asset_funding') THEN
    RAISE EXCEPTION 'strategy stop did not persist: %', v_result;
  END IF;

  BEGIN
    PERFORM apply_strategy_control(
      'jitosol_carry',
      true,
      'strategy-control:retired',
      'retired strategies stay unknown',
      repeat('d', 64)
    );
    RAISE EXCEPTION 'retired strategy was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'unknown strategy' THEN
        RAISE;
      END IF;
  END;
END;
$$;

ROLLBACK;
