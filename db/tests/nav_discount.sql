\set ON_ERROR_STOP on
BEGIN;

INSERT INTO build_manifests (
  id, code_commit, mesh_commit, schema_version, config_hash
) VALUES (
  'nav-discount-test-build', 'code', 'mesh', 35, repeat('3', 64)
);
INSERT INTO strategy_runs (
  id, execution_mode, config_hash, build_manifest_id,
  prng_seed, prng_version
) VALUES (
  'nav-discount-test-run', 'paper', repeat('3', 64),
  'nav-discount-test-build', 1, 'test'
);
INSERT INTO comparison_groups (
  id, strategy_run_id, mode, target_notional_usd_micros,
  entry_policy_version, exit_policy_version
) VALUES
  ('nav-discount-independent', 'nav-discount-test-run', 'independent',
    500000000, 'nav-discount-v1', 'nav-discount-v1'),
  ('nav-discount-controlled', 'nav-discount-test-run', 'synchronized',
    500000000, 'nav-discount-v1', 'nav-discount-v1');
INSERT INTO portfolio_runs (
  id, strategy_run_id, comparison_group_id, variant,
  execution_mode, initial_capital_usd_micros
) VALUES
  ('nav-discount-independent', 'nav-discount-test-run',
    'nav-discount-independent', 'jitosol_nav_discount', 'paper', 1000000000),
  ('nav-discount-controlled', 'nav-discount-test-run',
    'nav-discount-controlled', 'jitosol_nav_discount', 'paper', 1000000000),
  ('nav-discount-sol-independent', 'nav-discount-test-run',
    'nav-discount-independent', 'sol_control', 'paper', 1000000000),
  ('nav-discount-sol-controlled', 'nav-discount-test-run',
    'nav-discount-controlled', 'sol_control', 'paper', 1000000000);
UPDATE portfolio_runs
SET state = 'hedged'
WHERE id = 'nav-discount-sol-controlled';

INSERT INTO normalized_events (
  id, schema_version, event_type, source, observed_at_ms, source_slot,
  source_sequence, idempotency_key, raw_payload_hash, canonical_payload
) VALUES (
  'nav-open', 1, 'MarketSnapshot', 'nav-discount-test', 1785024000000,
  320000001, '1', 'nav-discount-test:1', repeat('a', 64),
  '{
    "schemaVersion": 1,
    "eventId": "nav-open",
    "eventType": "MarketSnapshot",
    "source": "nav-discount-test",
    "observedAtMs": "1785024000000",
    "sourceSlot": "320000001",
    "sourceSequence": "1",
    "idempotencyKey": "nav-discount-test:1",
    "rawPayloadHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "payload": {
      "epoch": "900",
      "oracleStatus": "valid",
      "totalPoolLamports": "12500000000",
      "supplyAtoms": "10000000000",
      "jitosolAtoms": "4000000000",
      "notionalUsdMicros": "500000000",
      "shortReceiptPpm": "0",
      "solPriceUsdMicros": "100000000",
      "priorNavLamports": "1240000000",
      "costsUsdMicros": "200000",
      "riskHaircutUsdMicros": "50000",
      "collateralUsdMicros": "500000000",
      "maintenanceRequirementUsdMicros": "100000000",
      "liquidationDistanceBps": "5000",
      "jitosolSpotBidPriceUsdMicros": "123900000",
      "jitosolSpotAskPriceUsdMicros": "124000000",
      "jitosolExitDepthLamports": "10000000000",
      "perpExitDepthLamports": "10000000000"
    }
  }'::jsonb
);

DO $$
DECLARE
  result jsonb;
  next_event jsonb;
  event_id text;
  i integer;
BEGIN
  result := run_nav_discount_paper_cycle(
    'nav-open', 1785024000000, 60000, 1500000, 1000,
    1000, 20000, 100000, 500000, 100000, 48
  );

  IF result->>'opened' <> '2'
     OR (SELECT count(*) FROM nav_discount_paper_positions
         WHERE status = 'open' AND exit_route = 'direct') <> 2
     OR (SELECT count(*) FROM direct_unstake_counterfactuals
         WHERE portfolio_run_id LIKE 'nav-discount-%'
           AND state = 'requested') <> 2
     OR (SELECT count(*) FROM nav_discount_paper_decisions
         WHERE selected_route = 'direct'
           AND net_carry_usd_micros = 2530000
           AND eligible) <> 2 THEN
    RAISE EXCEPTION 'profitable direct route did not open: %', result;
  END IF;

  FOR i IN 2..5 LOOP
    event_id := 'nav-progress-' || i;
    SELECT canonical_payload INTO next_event
    FROM normalized_events
    WHERE id = 'nav-open';
    next_event := jsonb_set(next_event, '{eventId}', to_jsonb(event_id));
    next_event := jsonb_set(
      next_event, '{observedAtMs}', to_jsonb((1785024000000 + i)::text)
    );
    next_event := jsonb_set(
      next_event, '{sourceSlot}', to_jsonb((320000001 + i)::text)
    );
    next_event := jsonb_set(
      next_event, '{sourceSequence}', to_jsonb(i::text)
    );
    next_event := jsonb_set(
      next_event, '{idempotencyKey}', to_jsonb(('nav-discount-test:' || i)::text)
    );
    IF i >= 4 THEN
      next_event := jsonb_set(next_event, '{payload,epoch}', '"901"');
    END IF;
    INSERT INTO normalized_events (
      id, schema_version, event_type, source, observed_at_ms, source_slot,
      source_sequence, idempotency_key, raw_payload_hash, canonical_payload
    ) VALUES (
      event_id, 1, 'MarketSnapshot', 'nav-discount-test',
      1785024000000 + i, 320000001 + i, i::text,
      'nav-discount-test:' || i, repeat(i::text, 64), next_event
    );

    PERFORM advance_direct_unstake_counterfactuals(
      event_id,
      CASE WHEN i >= 4 THEN 901 ELSE 900 END,
      'withdraw'
    );
    IF i = 3 THEN
      INSERT INTO normalized_events (
        id, schema_version, event_type, source, observed_at_ms, source_slot,
        source_sequence, idempotency_key, raw_payload_hash, canonical_payload
      ) VALUES (
        'nav-funding', 1, 'FundingSettlement', 'nav-funding', 1785024000003,
        1, '1', 'nav-funding:1', repeat('f', 64), '{}'::jsonb
      );
      PERFORM record_direct_unstake_funding(
        jsonb_build_object('eventId', 'nav-funding'),
        (
          SELECT jsonb_agg(jsonb_build_object(
            'counterfactualId', id,
            'positionQuantityAtoms', hedge_quantity_atoms,
            'amountUsdMicros', '-30000'
          ))
          FROM direct_unstake_counterfactuals
          WHERE portfolio_run_id LIKE 'nav-discount-%'
        )
      );
    END IF;
    result := run_nav_discount_paper_cycle(
      event_id, 1785024000000 + i, 60000, 1500000, 1000,
      1000, 20000, 100000, 500000, 100000, 48
    );
    IF i < 5 AND result->>'held' <> '2' THEN
      RAISE EXCEPTION 'direct route did not remain open during cooldown: %',
        result;
    END IF;
  END LOOP;

  IF result->>'closed' <> '2'
     OR EXISTS (
       SELECT 1 FROM nav_discount_paper_positions WHERE status <> 'closed'
     )
     OR (SELECT count(*) FROM nav_discount_paper_positions
         WHERE realized_basis_usd_micros = 2780000
           AND realized_funding_usd_micros = -30000) <> 2
     OR EXISTS (
       SELECT 1 FROM portfolio_runs
       WHERE variant = 'jitosol_nav_discount' AND state <> 'idle'
  ) THEN
    RAISE EXCEPTION 'withdrawn direct route did not close cleanly: %', result;
  END IF;

  SELECT canonical_payload INTO next_event
  FROM normalized_events
  WHERE id = 'nav-open';
  next_event := jsonb_set(next_event, '{eventId}', '"nav-route"');
  next_event := jsonb_set(next_event, '{observedAtMs}', '"1785024000006"');
  next_event := jsonb_set(next_event, '{sourceSlot}', '"320000007"');
  next_event := jsonb_set(next_event, '{sourceSequence}', '"6"');
  next_event := jsonb_set(
    next_event, '{idempotencyKey}', '"nav-discount-test:6"'
  );
  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    'nav-route', 1, 'MarketSnapshot', 'nav-discount-test', 1785024000006,
    320000007, '6', 'nav-discount-test:6', repeat('b', 64), next_event
  );
  result := run_nav_discount_paper_cycle(
    'nav-route', 1785024000006, 60000, 1500000, 1000,
    1000, 20000, 100000, 500000000, 100000, 48
  );
  IF result->>'opened' <> '0'
     OR (SELECT count(*) FROM nav_discount_paper_decisions
         WHERE source_event_id = 'nav-route'
           AND selected_route = 'instant'
           AND NOT eligible
           AND reason_code = 'nav_discount_not_profitable') <> 2 THEN
    RAISE EXCEPTION 'route selection did not fail closed: %', result;
  END IF;

  next_event := jsonb_set(next_event, '{eventId}', '"nav-no-discount"');
  next_event := jsonb_set(next_event, '{observedAtMs}', '"1785024000007"');
  next_event := jsonb_set(next_event, '{sourceSlot}', '"320000008"');
  next_event := jsonb_set(next_event, '{sourceSequence}', '"7"');
  next_event := jsonb_set(
    next_event, '{idempotencyKey}', '"nav-discount-test:7"'
  );
  next_event := jsonb_set(
    next_event, '{payload,shortReceiptPpm}', '"100"'
  );
  next_event := jsonb_set(
    next_event, '{payload,jitosolSpotBidPriceUsdMicros}', '"124900000"'
  );
  next_event := jsonb_set(
    next_event, '{payload,jitosolSpotAskPriceUsdMicros}', '"125000000"'
  );
  INSERT INTO normalized_events (
    id, schema_version, event_type, source, observed_at_ms, source_slot,
    source_sequence, idempotency_key, raw_payload_hash, canonical_payload
  ) VALUES (
    'nav-no-discount', 1, 'MarketSnapshot', 'nav-discount-test',
    1785024000007, 320000008, '7', 'nav-discount-test:7',
    repeat('c', 64), next_event
  );
  result := run_nav_discount_paper_cycle(
    'nav-no-discount', 1785024000007, 60000, 1500000, 1000,
    1000, 20000, 100000, 500000, 100000, 48
  );
  IF result->>'opened' <> '0'
     OR (SELECT count(*) FROM nav_discount_paper_decisions
         WHERE source_event_id = 'nav-no-discount'
           AND NOT eligible
           AND reason_code = 'nav_discount_absent') <> 2 THEN
    RAISE EXCEPTION 'funding opened a trade without a NAV discount: %', result;
  END IF;
END;
$$;

ROLLBACK;
