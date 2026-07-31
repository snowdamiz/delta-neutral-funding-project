\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  result jsonb;
BEGIN
  result := apply_wallet_tracking_config(
    'wallet-config-test-1',
    'updated from the operator console',
    repeat('a', 64),
    '[
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222"
    ]'::jsonb
  );

  IF result->>'status' <> 'applied'
     OR result->>'version' <> '1'
     OR result->>'count' <> '2'
     OR (SELECT jsonb_agg(wallet ORDER BY ordinal)
         FROM wallet_tracking_wallets) <> result->'wallets' THEN
    RAISE EXCEPTION 'wallet cohort was not replaced atomically: %', result;
  END IF;

  BEGIN
    PERFORM apply_wallet_tracking_config(
      'wallet-config-test-invalid',
      'invalid update',
      repeat('b', 64),
      '["not-a-wallet"]'::jsonb
    );
    RAISE EXCEPTION 'invalid wallet cohort was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'invalid Hyperliquid wallet cohort' THEN
        RAISE;
      END IF;
  END;

  result := apply_wallet_tracking_config(
    'wallet-config-test-1',
    'updated from the operator console',
    repeat('a', 64),
    '[
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222"
    ]'::jsonb
  );
  IF result->>'duplicate' <> 'true'
     OR result->>'version' <> '1'
     OR (SELECT version FROM wallet_tracking_config_state) <> 1 THEN
    RAISE EXCEPTION 'wallet configuration retry was not idempotent: %', result;
  END IF;

  BEGIN
    PERFORM apply_wallet_tracking_config(
      'wallet-config-test-1',
      'different update',
      repeat('c', 64),
      '[]'::jsonb
    );
    RAISE EXCEPTION 'conflicting wallet configuration retry was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'idempotency key reused for a different operator command' THEN
        RAISE;
      END IF;
  END;
END;
$$;

ROLLBACK;
