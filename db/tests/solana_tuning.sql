\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.tune(p_key text, p_changes jsonb, p_now_ms bigint DEFAULT 1000000000000)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT apply_solana_tuning(p_key, 'tuned from the operator console',
                             repeat('a', 64), p_changes, p_now_ms);
$$;

CREATE FUNCTION pg_temp.refused(p_key text, p_changes jsonb, p_expect text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_temp.tune(p_key, p_changes);
  RAISE EXCEPTION 'tuning was accepted but should have been refused: %', p_expect;
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE p_expect THEN
    RAISE EXCEPTION 'wrong refusal for %: got "%", wanted "%"', p_changes, SQLERRM, p_expect;
  END IF;
END;
$$;

DO $$
DECLARE
  v_result jsonb;
  v_hash text;
  v_json jsonb;
BEGIN
  -- The guardrails, each refused for its own stated reason.
  PERFORM pg_temp.refused('t-unknown', '{"nonsense": "1"}'::jsonb,
    'unknown tunable parameter%');
  PERFORM pg_temp.refused('t-word', '{"maxEntryImpactBps": "wide"}'::jsonb,
    '%must be a whole number');
  PERFORM pg_temp.refused('t-under', '{"maxEntryImpactBps": "10"}'::jsonb,
    '%must be between 50 and 600');
  PERFORM pg_temp.refused('t-over', '{"maxEntryImpactBps": "9000"}'::jsonb,
    '%must be between 50 and 600');
  -- 200 -> 400 is +100%, past the 50% single-adjustment guardrail, and is
  -- refused even though 400 is inside the absolute bounds.
  PERFORM pg_temp.refused('t-leap', '{"maxEntryImpactBps": "400"}'::jsonb,
    '%may move at most 5000 bps away from 200 in one adjustment');
  PERFORM pg_temp.refused('t-noop', '{"maxEntryImpactBps": "200"}'::jsonb,
    'no parameter changed');
  PERFORM pg_temp.refused('t-empty', '{}'::jsonb, 'invalid Solana tuning request');

  -- A move inside the guardrail mints a new frozen config and promotes it.
  v_result := pg_temp.tune('t-ok', '{"maxEntryImpactBps": "300", "maxOpenPositions": "4"}'::jsonb);
  IF v_result->>'status' <> 'applied'
     OR jsonb_array_length(v_result->'changes') <> 2 THEN
    RAISE EXCEPTION 'a permitted adjustment was not applied: %', v_result;
  END IF;
  IF (SELECT config_json->>'maxEntryImpactBps' FROM solana_strategy_configs WHERE active) <> '300'
     OR (SELECT config_json->>'maxOpenPositions' FROM solana_paper_broker_configs WHERE active) <> '4' THEN
    RAISE EXCEPTION 'the promoted configuration does not carry the new values';
  END IF;
  IF (SELECT count(*) FROM solana_strategy_configs WHERE active) <> 1
     OR (SELECT count(*) FROM solana_strategy_configs) <> 3 THEN
    RAISE EXCEPTION 'promotion did not leave exactly one active config beside its history';
  END IF;
  -- The superseded config is untouched: past decisions still describe the
  -- parameters that produced them.
  IF (SELECT config_json->>'maxEntryImpactBps'
      FROM solana_strategy_configs WHERE id = 'solana-wallet-flow-v2') <> '200' THEN
    RAISE EXCEPTION 'promotion rewrote the superseded configuration';
  END IF;

  -- The minted hash is the same recipe the authored configs use.
  SELECT config_hash, config_json INTO v_hash, v_json
  FROM solana_strategy_configs WHERE active;
  IF v_hash <> solana_config_hash(v_json) THEN
    RAISE EXCEPTION 'the minted config hash does not match its own configuration';
  END IF;
  IF (SELECT config_hash FROM solana_strategy_configs WHERE id = 'solana-wallet-flow-v2')
     <> solana_config_hash((SELECT config_json FROM solana_strategy_configs
                            WHERE id = 'solana-wallet-flow-v2')) THEN
    RAISE EXCEPTION 'the shared hash recipe does not reproduce an authored config hash';
  END IF;

  -- Same key, same request: applied once.
  v_result := pg_temp.tune('t-ok', '{"maxEntryImpactBps": "300", "maxOpenPositions": "4"}'::jsonb);
  IF v_result->>'duplicate' <> 'true'
     OR (SELECT count(*) FROM solana_strategy_configs) <> 3 THEN
    RAISE EXCEPTION 'a retried adjustment was applied twice: %', v_result;
  END IF;

  -- Cooldown: the same knob may not move again immediately, and the console
  -- is told how long it has to wait.
  PERFORM pg_temp.refused('t-again', '{"maxEntryImpactBps": "350"}'::jsonb,
    '%is settling');
  IF (jsonb_path_query_first(solana_tuning_read_model(1000000000000),
        '$.knobs[*] ? (@.knob == "maxEntryImpactBps")')->>'readyInMs')::bigint <= 0 THEN
    RAISE EXCEPTION 'the console was not told the knob is still settling';
  END IF;

  -- Past the cooldown it moves again, and only within the guardrail measured
  -- against the NEW value: 300 -> 450, not 300 -> 600.
  PERFORM pg_temp.tune('t-later', '{"maxEntryImpactBps": "450"}'::jsonb, 1000000901000);
  IF (SELECT config_json->>'maxEntryImpactBps' FROM solana_strategy_configs WHERE active) <> '450' THEN
    RAISE EXCEPTION 'the knob did not move after its cooldown elapsed';
  END IF;

  -- Live capital is not the place to discover a parameter change.
  INSERT INTO strategy_execution_modes (strategy_id, mode)
  VALUES ('solana_wallet_flow_quant', 'live')
  ON CONFLICT (strategy_id) DO UPDATE SET mode = 'live';
  PERFORM pg_temp.refused('t-live', '{"minimumOrganicBuyerCount": "8"}'::jsonb,
    'cannot tune while live trading is armed');
  IF solana_tuning_read_model()->>'lockedReason' <> 'live trading is armed' THEN
    RAISE EXCEPTION 'the console was not told why tuning is locked';
  END IF;
  UPDATE strategy_execution_modes SET mode = 'paper'
  WHERE strategy_id = 'solana_wallet_flow_quant';

  -- A validation window measures a frozen configuration; retuning would void
  -- the result it exists to produce.
  INSERT INTO solana_validation_windows (
    id, start_at_ms, end_at_ms, training_cutoff_ms, wallets,
    strategy_config_id, strategy_config_hash, broker_config_id, broker_config_hash,
    maximum_drawdown_bps
  )
  SELECT 'window-under-test', 999999999999, 999999999999 + 7776000000, 999999999998,
         '["11111111111111111111111111111111"]'::jsonb,
         s.id, s.config_hash, b.id, b.config_hash, 3000
  FROM solana_strategy_configs s, solana_paper_broker_configs b
  WHERE s.active AND b.active;
  PERFORM pg_temp.refused('t-window', '{"minimumOrganicBuyerCount": "8"}'::jsonb,
    'cannot tune during an open validation window');
END;
$$;

ROLLBACK;
