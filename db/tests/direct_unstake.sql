\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'direct-unstake-build', 'test', 'test', 23, repeat('0', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version
) VALUES (
  'direct-unstake-run', 'paper', repeat('0', 64),
  'direct-unstake-build', 42, 'xorshift64star-v1'
);
INSERT INTO portfolio_runs (
  id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros
) VALUES (
  'direct-unstake-jito', 'direct-unstake-run', 'jitosol_carry', 'paper',
  1000000000
);
INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES
  ('direct-exit', 1, 'MarketSnapshot', 'direct-test', 1, 1, '1',
   'direct-test:1', repeat('a', 64), '{}'::jsonb),
  ('direct-deactivating', 1, 'MarketSnapshot', 'direct-test', 2, 2, '2',
   'direct-test:2', repeat('b', 64), '{}'::jsonb),
  ('direct-waiting', 1, 'MarketSnapshot', 'direct-test', 3, 3, '3',
   'direct-test:3', repeat('c', 64), '{}'::jsonb),
  ('direct-withdrawable', 1, 'MarketSnapshot', 'direct-test', 4, 4, '4',
   'direct-test:4', repeat('d', 64), '{}'::jsonb),
  ('direct-missed', 1, 'MarketSnapshot', 'direct-test', 5, 5, '5',
   'direct-test:5', repeat('e', 64), '{}'::jsonb),
  ('direct-withdrawn', 1, 'MarketSnapshot', 'direct-test', 6, 6, '6',
   'direct-test:6', repeat('f', 64), '{}'::jsonb);

DO $$
DECLARE
  v_plan jsonb := '{
    "variant": "jitosol_carry",
    "action": "exit",
    "directUnstake": {
      "enabled": true,
      "state": "requested",
      "requestedEpoch": "900",
      "availableEpoch": "901",
      "jitosolQuantityAtoms": "2000000000",
      "hedgeQuantityAtoms": "2000000000",
      "protocolRedemptionLamports": "2500000000",
      "withdrawalFeeLamports": "2500000",
      "netRedemptionLamports": "2497500000",
      "protocolRedemptionUsdMicros": "375000000",
      "withdrawalFeeUsdMicros": "375000",
      "cooldownFundingUsdMicros": "0",
      "chainFeesUsdMicros": "20000",
      "hedgeCostUsdMicros": "0",
      "capitalDelayHaircutUsdMicros": "1000000",
      "finalHedgeCloseCostUsdMicros": "250000",
      "netUsdMicros": "373355000"
    }
  }'::jsonb;
  v_id text;
BEGIN
  v_id := record_direct_unstake_exit(
    'direct-unstake-jito',
    'direct-exit',
    v_plan
  );
  IF v_id <> 'direct-exit:direct-unstake-jito:direct-unstake'
     OR (SELECT state FROM direct_unstake_counterfactuals WHERE id = v_id)
        <> 'requested'
     OR (SELECT count(*) FROM direct_unstake_ledger_entries
         WHERE counterfactual_id = v_id) <> 6
     OR EXISTS (
       SELECT 1 FROM direct_unstake_ledger_entries
       WHERE counterfactual_id = v_id AND usd_value_micros = '-0'
     )
     OR EXISTS (
       SELECT 1 FROM ledger_batches
       WHERE portfolio_run_id = 'direct-unstake-jito'
     ) THEN
    RAISE EXCEPTION 'direct unstake start was not isolated or complete';
  END IF;

  PERFORM advance_direct_unstake_counterfactuals(
    'direct-deactivating', 900, 'withdraw'
  );
  PERFORM advance_direct_unstake_counterfactuals(
    'direct-waiting', 900, 'withdraw'
  );
  PERFORM advance_direct_unstake_counterfactuals(
    'direct-withdrawable', 901, 'withdraw'
  );
  IF (SELECT state FROM direct_unstake_counterfactuals WHERE id = v_id)
     <> 'withdrawable' THEN
    RAISE EXCEPTION 'direct unstake did not cross the recorded epoch';
  END IF;

  PERFORM advance_direct_unstake_counterfactuals(
    'direct-missed', 901, 'miss'
  );
  IF (SELECT state FROM direct_unstake_counterfactuals WHERE id = v_id)
     <> 'withdrawable'
     OR NOT EXISTS (
       SELECT 1 FROM direct_unstake_events
       WHERE counterfactual_id = v_id AND reason = 'missed_withdrawal'
     ) THEN
    RAISE EXCEPTION 'missed direct withdrawal was not retained for recovery';
  END IF;

  PERFORM advance_direct_unstake_counterfactuals(
    'direct-withdrawn', 901, 'withdraw'
  );
  IF (SELECT state FROM direct_unstake_counterfactuals WHERE id = v_id)
     <> 'withdrawn' THEN
    RAISE EXCEPTION 'direct unstake did not complete';
  END IF;
END;
$$;

DO $$
DECLARE
  v_event jsonb := '{
    "schemaVersion": 1,
    "eventType": "FundingSettlement",
    "eventId": "direct-funding",
    "source": "direct-test",
    "observedAtMs": "7",
    "sourceSlot": "7",
    "sourceSequence": "7",
    "idempotencyKey": "direct-test:funding:7",
    "rawPayloadHash": "7777777777777777777777777777777777777777777777777777777777777777",
    "payload": {
      "venuePaymentId": "direct-venue-7",
      "effectiveAtMs": "7",
      "realizedShortRatePpm": "-100",
      "solPriceUsdMicros": "150000000"
    }
  }'::jsonb;
  v_payment jsonb := '[{
    "counterfactualId": "direct-exit:direct-unstake-jito:direct-unstake",
    "positionQuantityAtoms": "2000000000",
    "amountUsdMicros": "-30000"
  }]'::jsonb;
  v_result jsonb;
BEGIN
  UPDATE direct_unstake_counterfactuals
  SET state = 'waiting_for_epoch'
  WHERE id = 'direct-exit:direct-unstake-jito:direct-unstake';

  v_result := apply_funding_settlements(v_event, '[]'::jsonb, v_payment);
  IF (v_result->>'counterfactualPayments')::integer <> 1
     OR (SELECT cooldown_funding_usd_micros
         FROM direct_unstake_counterfactuals
         WHERE id = 'direct-exit:direct-unstake-jito:direct-unstake') <> '-30000'
     OR (SELECT net_usd_micros
         FROM direct_unstake_counterfactuals
         WHERE id = 'direct-exit:direct-unstake-jito:direct-unstake') <> '373325000'
     OR NOT EXISTS (
       SELECT 1 FROM direct_unstake_ledger_entries
       WHERE source_event_id = 'direct-funding'
         AND component = 'cooldown_funding'
         AND usd_value_micros = '-30000'
     ) THEN
    RAISE EXCEPTION 'actual cooldown funding was not attributed: %', v_result;
  END IF;

  v_result := apply_funding_settlements(v_event, '[]'::jsonb, v_payment);
  IF (v_result->>'counterfactualPayments')::integer <> 0
     OR (SELECT count(*) FROM direct_unstake_ledger_entries
         WHERE source_event_id = 'direct-funding') <> 1 THEN
    RAISE EXCEPTION 'direct unstake funding retry was not idempotent';
  END IF;

  BEGIN
    PERFORM record_direct_unstake_funding(
      v_event,
      jsonb_set(v_payment, '{0,amountUsdMicros}', '"-0"')
    );
    RAISE EXCEPTION 'negative zero funding was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'direct unstake hedge changed before funding settlement' THEN
        RAISE;
      END IF;
  END;
END;
$$;

ROLLBACK;
