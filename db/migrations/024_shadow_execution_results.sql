BEGIN;

CREATE TABLE shadow_execution_results (
  command_id text PRIMARY KEY CHECK (
    command_id ~ '^[A-Za-z0-9:_-]+$'
    AND length(command_id) BETWEEN 1 AND 300
  ),
  intent_hash char(64) NOT NULL CHECK (
    intent_hash ~ '^[0-9a-f]{64}$'
  ),
  message_hash char(64) NOT NULL UNIQUE CHECK (
    message_hash ~ '^[0-9a-f]{64}$'
  ),
  binding_hash char(64) NOT NULL CHECK (
    binding_hash ~ '^[0-9a-f]{64}$'
  ),
  market text NOT NULL CHECK (length(btrim(market)) > 0),
  status text NOT NULL CHECK (
    status IN ('PLANNED', 'UNKNOWN', 'REJECTED')
  ),
  intent_json jsonb NOT NULL CHECK (jsonb_typeof(intent_json) = 'object'),
  action_json jsonb NOT NULL CHECK (jsonb_typeof(action_json) = 'object'),
  report_json jsonb NOT NULL CHECK (jsonb_typeof(report_json) = 'object'),
  paper_estimate_json jsonb NOT NULL CHECK (
    jsonb_typeof(paper_estimate_json) = 'object'
  ),
  paper_quantity_atoms text NOT NULL CHECK (
    paper_quantity_atoms ~ '^(0|[1-9][0-9]*)$'
  ),
  paper_price_atoms text NOT NULL CHECK (
    paper_price_atoms ~ '^(0|[1-9][0-9]*)$'
  ),
  paper_fee_atoms text NOT NULL CHECK (
    paper_fee_atoms ~ '^(0|[1-9][0-9]*)$'
  ),
  simulated_quantity_atoms text NOT NULL CHECK (
    simulated_quantity_atoms ~ '^(0|[1-9][0-9]*)$'
  ),
  simulated_price_atoms text NOT NULL CHECK (
    simulated_price_atoms ~ '^(0|[1-9][0-9]*)$'
  ),
  simulated_fee_atoms text NOT NULL CHECK (
    simulated_fee_atoms ~ '^(0|[1-9][0-9]*)$'
  ),
  quantity_error_atoms text NOT NULL CHECK (
    quantity_error_atoms ~ '^(0|-?[1-9][0-9]*)$'
  ),
  price_error_atoms text NOT NULL CHECK (
    price_error_atoms ~ '^(0|-?[1-9][0-9]*)$'
  ),
  fee_error_atoms text NOT NULL CHECK (
    fee_error_atoms ~ '^(0|-?[1-9][0-9]*)$'
  ),
  reconciliation_count integer NOT NULL DEFAULT 0 CHECK (
    reconciliation_count >= 0
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX shadow_execution_results_latest
  ON shadow_execution_results(updated_at DESC, command_id);

CREATE FUNCTION record_shadow_result(
  p_binding_hash text,
  p_body jsonb
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_intent jsonb := p_body->'intent';
  v_action jsonb := p_body->'action';
  v_report jsonb := p_body->'report';
  v_paper jsonb := p_body->'paperEstimate';
  v_command_id text;
  v_status text;
  v_quantity_error text;
  v_price_error text;
  v_fee_error text;
  v_existing shadow_execution_results%ROWTYPE;
BEGIN
  IF p_binding_hash !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_body) <> 'object'
     OR p_body->>'schemaVersion' <> '1'
     OR (SELECT count(*) FROM jsonb_object_keys(p_body)) <> 5
     OR NOT p_body ?& ARRAY[
       'schemaVersion', 'intent', 'action', 'report', 'paperEstimate'
     ]
     OR jsonb_typeof(v_intent) <> 'object'
     OR jsonb_typeof(v_action) <> 'object'
     OR jsonb_typeof(v_report) <> 'object'
     OR jsonb_typeof(v_paper) <> 'object' THEN
    RAISE EXCEPTION 'invalid shadow result envelope';
  END IF;

  IF (SELECT count(*) FROM jsonb_object_keys(v_intent)) <> 17
     OR NOT v_intent ?& ARRAY[
       'schemaVersion', 'intentId', 'strategyRunId', 'stateVersion',
       'variant', 'operation', 'leg', 'instrument', 'side',
       'maxQuantityAtoms', 'limitPriceAtoms', 'maxSlippageBps',
       'reduceOnly', 'expiresAtMs', 'policyProfile', 'snapshotIds',
       'configHash'
     ]
     OR v_intent->>'schemaVersion' <> '1'
     OR v_intent->>'intentId' !~ '^[A-Za-z0-9:_-]+$'
     OR length(v_intent->>'intentId') NOT BETWEEN 1 AND 280
     OR v_intent->>'stateVersion' !~ '^(0|[1-9][0-9]*)$'
     OR v_intent->>'variant' NOT IN ('sol_control', 'jitosol_carry')
     OR v_intent->>'operation' NOT IN (
       'OPEN', 'REBALANCE', 'CLOSE', 'EMERGENCY_FLATTEN'
     )
     OR v_intent->>'leg' NOT IN ('SPOT', 'PERP')
     OR v_intent->>'side' NOT IN ('BUY', 'SELL')
     OR v_intent->>'maxQuantityAtoms' !~ '^[1-9][0-9]*$'
     OR v_intent->>'limitPriceAtoms' !~ '^[1-9][0-9]*$'
     OR v_intent->>'maxSlippageBps' !~ '^(0|[1-9][0-9]*)$'
     OR (v_intent->>'maxSlippageBps')::numeric > 10000
     OR jsonb_typeof(v_intent->'reduceOnly') <> 'boolean'
     OR v_intent->>'expiresAtMs' !~ '^[1-9][0-9]*$'
     OR jsonb_typeof(v_intent->'snapshotIds') <> 'array'
     OR jsonb_array_length(v_intent->'snapshotIds') = 0
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_intent->'snapshotIds')
       WHERE jsonb_typeof(value) <> 'string'
          OR length(btrim(value #>> '{}')) = 0
     )
     OR v_intent->>'configHash' !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid shadow execution intent';
  END IF;

  IF (SELECT count(*) FROM jsonb_object_keys(v_action)) <> 20
     OR NOT v_action ?& ARRAY[
       'schemaVersion', 'commandId', 'intentHash', 'programIds', 'accounts',
       'market', 'mint', 'destination', 'quantityAtoms', 'limitPriceAtoms',
       'priorityFeeLamports', 'computeUnitLimit', 'simulateOnly', 'submit',
       'messageHash', 'simulatedQuantityAtoms', 'simulatedAveragePriceAtoms',
       'simulatedFeeAtoms', 'computeUnitsConsumed', 'accountDeltas'
     ]
     OR v_action->>'schemaVersion' <> '1'
     OR v_action->'simulateOnly' <> 'true'::jsonb
     OR v_action->'submit' <> 'false'::jsonb
     OR v_action->>'intentHash' !~ '^[0-9a-f]{64}$'
     OR v_action->>'messageHash' !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(v_action->'programIds') <> 'array'
     OR jsonb_array_length(v_action->'programIds') = 0
     OR jsonb_typeof(v_action->'accounts') <> 'array'
     OR jsonb_array_length(v_action->'accounts') = 0
     OR NOT (v_action->'accounts' ? (v_action->>'destination'))
     OR v_action->>'quantityAtoms' !~ '^[1-9][0-9]*$'
     OR v_action->>'limitPriceAtoms' !~ '^[1-9][0-9]*$'
     OR v_action->>'priorityFeeLamports' !~ '^(0|[1-9][0-9]*)$'
     OR v_action->>'computeUnitLimit' !~ '^[1-9][0-9]*$'
     OR v_action->>'simulatedQuantityAtoms' <> v_action->>'quantityAtoms'
     OR v_action->>'simulatedAveragePriceAtoms' <> v_action->>'limitPriceAtoms'
     OR v_action->>'simulatedFeeAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR v_action->>'computeUnitsConsumed' !~ '^(0|[1-9][0-9]*)$'
     OR (v_action->>'computeUnitsConsumed')::numeric
        > (v_action->>'computeUnitLimit')::numeric
     OR jsonb_typeof(v_action->'accountDeltas') <> 'array'
     OR jsonb_array_length(v_action->'accountDeltas') = 0
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_action->'accountDeltas') delta
       WHERE jsonb_typeof(delta) <> 'object'
          OR (SELECT count(*) FROM jsonb_object_keys(delta)) <> 3
          OR NOT delta ?& ARRAY['account', 'asset', 'deltaAtoms']
          OR length(btrim(delta->>'asset')) = 0
          OR delta->>'deltaAtoms' !~ '^(0|-?[1-9][0-9]*)$'
          OR NOT (v_action->'accounts' ? (delta->>'account'))
     ) THEN
    RAISE EXCEPTION 'invalid shadow action';
  END IF;

  IF (SELECT count(*) FROM jsonb_object_keys(v_report)) <> 15
     OR NOT v_report ?& ARRAY[
       'schemaVersion', 'intentId', 'commandId', 'mode', 'status',
       'observedAtMs', 'filledQuantityAtoms', 'averagePriceAtoms', 'feeAtoms',
       'authoritativeReference', 'simulatedQuantityAtoms',
       'simulatedAveragePriceAtoms', 'simulatedFeeAtoms',
       'computeUnitsConsumed', 'accountDeltas'
     ]
     OR v_report->>'schemaVersion' <> '1'
     OR v_report->>'mode' <> 'shadow'
     OR v_report->>'status' NOT IN ('PLANNED', 'UNKNOWN', 'REJECTED')
     OR v_report->>'observedAtMs' !~ '^(0|[1-9][0-9]*)$'
     OR v_report->>'filledQuantityAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR v_report->>'averagePriceAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR v_report->>'feeAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR v_report->>'authoritativeReference' <> v_action->>'messageHash'
     OR v_report->>'simulatedQuantityAtoms'
        <> v_action->>'simulatedQuantityAtoms'
     OR v_report->>'simulatedAveragePriceAtoms'
        <> v_action->>'simulatedAveragePriceAtoms'
     OR v_report->>'simulatedFeeAtoms' <> v_action->>'simulatedFeeAtoms'
     OR v_report->>'computeUnitsConsumed' <> v_action->>'computeUnitsConsumed'
     OR v_report->'accountDeltas' <> v_action->'accountDeltas' THEN
    RAISE EXCEPTION 'invalid shadow execution report';
  END IF;

  IF (SELECT count(*) FROM jsonb_object_keys(v_paper)) <> 3
     OR NOT v_paper ?& ARRAY[
       'quantityAtoms', 'averagePriceAtoms', 'feeAtoms'
     ]
     OR v_paper->>'quantityAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR v_paper->>'averagePriceAtoms' !~ '^(0|[1-9][0-9]*)$'
     OR v_paper->>'feeAtoms' !~ '^(0|[1-9][0-9]*)$' THEN
    RAISE EXCEPTION 'invalid paper estimate';
  END IF;

  v_command_id := v_action->>'commandId';
  v_status := v_report->>'status';
  IF v_command_id <> ((v_intent->>'intentId') || ':shadow:1')
     OR v_report->>'commandId' <> v_command_id
     OR v_report->>'intentId' <> v_intent->>'intentId'
     OR v_action->>'market' <> v_intent->>'instrument' THEN
    RAISE EXCEPTION 'shadow result binding mismatch';
  END IF;

  v_quantity_error := (
    (v_action->>'simulatedQuantityAtoms')::numeric
    - (v_paper->>'quantityAtoms')::numeric
  )::text;
  v_price_error := (
    (v_action->>'simulatedAveragePriceAtoms')::numeric
    - (v_paper->>'averagePriceAtoms')::numeric
  )::text;
  v_fee_error := (
    (v_action->>'simulatedFeeAtoms')::numeric
    - (v_paper->>'feeAtoms')::numeric
  )::text;

  SELECT *
  INTO v_existing
  FROM shadow_execution_results
  WHERE command_id = v_command_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.binding_hash <> p_binding_hash
       OR v_existing.intent_hash <> v_action->>'intentHash'
       OR v_existing.message_hash <> v_action->>'messageHash' THEN
      RAISE EXCEPTION 'shadow command binding changed';
    END IF;
    IF v_existing.status = 'UNKNOWN' THEN
      IF v_status = 'UNKNOWN' THEN
        RETURN 'duplicate';
      END IF;
      UPDATE shadow_execution_results
      SET status = v_status,
          report_json = v_report,
          simulated_quantity_atoms = v_action->>'simulatedQuantityAtoms',
          simulated_price_atoms = v_action->>'simulatedAveragePriceAtoms',
          simulated_fee_atoms = v_action->>'simulatedFeeAtoms',
          quantity_error_atoms = v_quantity_error,
          price_error_atoms = v_price_error,
          fee_error_atoms = v_fee_error,
          reconciliation_count = reconciliation_count + 1,
          updated_at = now()
      WHERE command_id = v_command_id;
      RETURN 'reconciled';
    END IF;
    IF v_existing.status = v_status AND v_existing.report_json = v_report THEN
      RETURN 'duplicate';
    END IF;
    RAISE EXCEPTION 'terminal shadow result changed';
  END IF;

  INSERT INTO shadow_execution_results (
    command_id, intent_hash, message_hash, binding_hash, market, status,
    intent_json, action_json, report_json, paper_estimate_json,
    paper_quantity_atoms, paper_price_atoms, paper_fee_atoms,
    simulated_quantity_atoms, simulated_price_atoms, simulated_fee_atoms,
    quantity_error_atoms, price_error_atoms, fee_error_atoms
  ) VALUES (
    v_command_id,
    v_action->>'intentHash',
    v_action->>'messageHash',
    p_binding_hash,
    v_action->>'market',
    v_status,
    v_intent,
    v_action,
    v_report,
    v_paper,
    v_paper->>'quantityAtoms',
    v_paper->>'averagePriceAtoms',
    v_paper->>'feeAtoms',
    v_action->>'simulatedQuantityAtoms',
    v_action->>'simulatedAveragePriceAtoms',
    v_action->>'simulatedFeeAtoms',
    v_quantity_error,
    v_price_error,
    v_fee_error
  );
  RETURN 'inserted';
END;
$$;

INSERT INTO schema_meta(version) VALUES (24);

COMMIT;
