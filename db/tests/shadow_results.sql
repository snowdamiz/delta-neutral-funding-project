\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_body jsonb := '{
    "schemaVersion": 1,
    "intent": {
      "schemaVersion": 1,
      "intentId": "intent-conformance-1",
      "strategyRunId": "run-conformance-1",
      "stateVersion": "7",
      "variant": "jitosol_carry",
      "operation": "REBALANCE",
      "leg": "PERP",
      "instrument": "SOL-PERP",
      "side": "SELL",
      "maxQuantityAtoms": "38271565",
      "limitPriceAtoms": "149980000",
      "maxSlippageBps": "50",
      "reduceOnly": false,
      "expiresAtMs": "1785024005000",
      "policyProfile": "shadow-v1",
      "snapshotIds": ["snapshot-1"],
      "configHash": "0000000000000000000000000000000000000000000000000000000000000000"
    },
    "action": {
      "schemaVersion": 1,
      "commandId": "intent-conformance-1:shadow:1",
      "intentHash": "7c88cd7bd82785f67ef4b232b287ef33c18500060b321f0f0883de0abe408f03",
      "programIds": ["qualified-perp-program"],
      "accounts": ["paper-perp-account", "paper-margin-account"],
      "market": "SOL-PERP",
      "mint": "So11111111111111111111111111111111111111112",
      "destination": "paper-margin-account",
      "quantityAtoms": "38271565",
      "limitPriceAtoms": "149980000",
      "priorityFeeLamports": "500000",
      "computeUnitLimit": "300000",
      "simulateOnly": true,
      "submit": false,
      "messageHash": "c27cd9068bf3c54364ed4782cdd1ae0cf3ed7f98fb38ec769764bd7512a8e52d",
      "simulatedQuantityAtoms": "38271565",
      "simulatedAveragePriceAtoms": "149980000",
      "simulatedFeeAtoms": "6000",
      "computeUnitsConsumed": "220000",
      "accountDeltas": [
        {"account":"paper-perp-account","asset":"SOL-PERP","deltaAtoms":"-38271565"}
      ]
    },
    "report": {
      "schemaVersion": 1,
      "intentId": "intent-conformance-1",
      "commandId": "intent-conformance-1:shadow:1",
      "mode": "shadow",
      "status": "PLANNED",
      "observedAtMs": "1785024000000",
      "filledQuantityAtoms": "0",
      "averagePriceAtoms": "0",
      "feeAtoms": "0",
      "authoritativeReference": "c27cd9068bf3c54364ed4782cdd1ae0cf3ed7f98fb38ec769764bd7512a8e52d",
      "simulatedQuantityAtoms": "38271565",
      "simulatedAveragePriceAtoms": "149980000",
      "simulatedFeeAtoms": "6000",
      "computeUnitsConsumed": "220000",
      "accountDeltas": [
        {"account":"paper-perp-account","asset":"SOL-PERP","deltaAtoms":"-38271565"}
      ]
    },
    "paperEstimate": {
      "quantityAtoms": "38271565",
      "averagePriceAtoms": "149980000",
      "feeAtoms": "5500"
    }
  }'::jsonb;
  v_unknown jsonb;
  v_first text;
  v_second text;
BEGIN
  v_first := record_shadow_result(repeat('c', 64), v_body);
  v_second := record_shadow_result(repeat('c', 64), v_body);
  IF v_first <> 'inserted'
     OR v_second <> 'duplicate'
     OR NOT EXISTS (
       SELECT 1
       FROM shadow_execution_results
       WHERE command_id = 'intent-conformance-1:shadow:1'
         AND status = 'PLANNED'
         AND quantity_error_atoms = '0'
         AND price_error_atoms = '0'
         AND fee_error_atoms = '500'
         AND reconciliation_count = 0
     ) THEN
    RAISE EXCEPTION 'planned shadow result was not recorded idempotently';
  END IF;

  v_unknown := jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(v_body, '{intent,intentId}', '"unknown-intent"'),
          '{action,commandId}', '"unknown-intent:shadow:1"'
        ),
        '{action,messageHash}', to_jsonb(repeat('b', 64))
      ),
      '{report,intentId}', '"unknown-intent"'
    ),
    '{report,commandId}', '"unknown-intent:shadow:1"'
  );
  v_unknown := jsonb_set(
    jsonb_set(v_unknown, '{report,status}', '"UNKNOWN"'),
    '{report,authoritativeReference}', to_jsonb(repeat('b', 64))
  );

  v_first := record_shadow_result(repeat('d', 64), v_unknown);
  IF v_first <> 'inserted'
     OR (SELECT status FROM shadow_execution_results
         WHERE command_id = 'unknown-intent:shadow:1') <> 'UNKNOWN' THEN
    RAISE EXCEPTION 'unknown shadow result was not retained';
  END IF;

  v_unknown := jsonb_set(v_unknown, '{report,status}', '"PLANNED"');
  v_first := record_shadow_result(repeat('d', 64), v_unknown);
  IF v_first <> 'reconciled'
     OR NOT EXISTS (
       SELECT 1 FROM shadow_execution_results
       WHERE command_id = 'unknown-intent:shadow:1'
         AND status = 'PLANNED'
         AND reconciliation_count = 1
     ) THEN
    RAISE EXCEPTION 'unknown shadow result was not reconciled';
  END IF;

  BEGIN
    PERFORM record_shadow_result(repeat('e', 64), v_body);
    RAISE EXCEPTION 'conflicting command binding was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'shadow command binding changed' THEN
        RAISE;
      END IF;
  END;
END;
$$;

ROLLBACK;
