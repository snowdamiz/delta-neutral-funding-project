\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  result jsonb;
BEGIN
  result := apply_solana_wallet_config(
    'solana-wallet-config-1',
    'updated from the operator console',
    repeat('a', 64),
    '[
      "11111111111111111111111111111111",
      "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ"
    ]'::jsonb
  );
  IF result->>'version' <> '1'
     OR result->>'count' <> '2'
     OR solana_wallet_config()->'wallets' <> result->'wallets' THEN
    RAISE EXCEPTION 'Solana cohort was not replaced atomically: %', result;
  END IF;

  result := apply_solana_wallet_config(
    'solana-wallet-config-1',
    'updated from the operator console',
    repeat('a', 64),
    '[
      "11111111111111111111111111111111",
      "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ"
    ]'::jsonb
  );
  IF result->>'duplicate' <> 'true'
     OR (solana_wallet_config()->>'version') <> '1' THEN
    RAISE EXCEPTION 'Solana cohort retry was not idempotent: %', result;
  END IF;

  BEGIN
    PERFORM apply_solana_wallet_config(
      'solana-wallet-config-invalid',
      'invalid update',
      repeat('b', 64),
      '["0x1111111111111111111111111111111111111111"]'::jsonb
    );
    RAISE EXCEPTION 'invalid Solana cohort was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'invalid Solana wallet cohort' THEN
      RAISE;
    END IF;
  END;

  result := apply_solana_wallet_config(
    'solana-wallet-config-empty',
    'removed all followed wallets',
    repeat('c', 64),
    '[]'::jsonb
  );
  IF result->>'version' <> '2'
     OR result->>'count' <> '0'
     OR jsonb_array_length(solana_wallet_config()->'wallets') <> 0 THEN
    RAISE EXCEPTION 'empty Solana cohort did not stop capture: %', result;
  END IF;
END;
$$;

ROLLBACK;
