BEGIN;

DO $$
DECLARE
  v_report jsonb;
BEGIN
  PERFORM record_solana_wallet_flow_event('{
    "schemaVersion":1,
    "eventId":"validation-checkpoint",
    "eventType":"SolanaWalletCheckpoint",
    "source":"solana-wallet:11111111111111111111111111111111",
    "observedAtMs":"1000",
    "sourceSlot":"0",
    "sourceSequence":"1000",
    "idempotencyKey":"validation-checkpoint",
    "rawPayloadHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "payload":{
      "wallet":"11111111111111111111111111111111",
      "status":"complete",
      "reason":"backfill_complete",
      "previousSignature":"",
      "previousSlot":"0",
      "latestSignature":"",
      "latestSlot":"0"
    }
  }'::jsonb);

  PERFORM start_solana_validation_window('{
    "windowId":"solana-validation-test",
    "startAtMs":"2000",
    "trainingCutoffMs":"1999",
    "maximumDrawdownBps":"5000",
    "wallets":["11111111111111111111111111111111"]
  }'::jsonb);
  v_report := solana_validation_report('solana-validation-test', 2000);
  IF v_report->>'passed' <> 'false'
     OR v_report->'gates'->>'durationComplete' <> 'false'
     OR v_report->'gates'->>'selectionFrozen' <> 'true' THEN
    RAISE EXCEPTION 'new validation window did not fail closed: %', v_report;
  END IF;

  PERFORM record_solana_validation_evidence('{
    "windowId":"solana-validation-test",
    "kind":"stress",
    "scenario":"quote_expiry",
    "passed":true,
    "completedAtMs":"2000",
    "evidenceHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }'::jsonb);
  IF solana_validation_report('solana-validation-test', 2000)
      ->'counts'->>'passingStressScenarios' <> '1' THEN
    RAISE EXCEPTION 'stress evidence was not included in the report';
  END IF;

  IF deterministic_bootstrap_lower_95(ARRAY[100, 200, 300]::numeric[], 200, 42) <= 0
     OR deterministic_bootstrap_lower_95(ARRAY[-300, -200, -100]::numeric[], 200, 42) >= 0 THEN
    RAISE EXCEPTION 'deterministic bootstrap bound has the wrong sign';
  END IF;

  BEGIN
    UPDATE solana_strategy_configs
    SET config_json = jsonb_set(config_json, '{maxEntryImpactBps}', '"201"')
    WHERE id = 'solana-wallet-flow-v1';
    RAISE EXCEPTION 'frozen strategy config was mutable';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

ROLLBACK;
