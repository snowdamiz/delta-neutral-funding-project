# Solana wallet-flow paper validation

This strategy is paper-only. The observer has no signer and the collector has
no route that can submit a Solana transaction.

## Start capture

Start the opt-in profile:

```sh
docker compose --profile solana-wallet-flow up --build
./bin/collector solana-wallet-flow
```

Add or remove wallets under **Market scans → Solana wallet flow** in the local
console. Each change atomically replaces the durable Postgres cohort; the
observer reads the new version on its next poll and does not need a restart.
Removing the final wallet stops new acquisition capture while existing paper
positions continue to receive exit checks.

Do not start a validation window until every configured cursor reports
`captureComplete: true`. A gap permanently fails capture continuity for the
affected window.

## Freeze a 90-day window

Create a request file whose start is later than the newest persisted event.
The end is fixed at exactly 90 days; the strategy and broker config hashes,
wallet cohort, training cutoff, drawdown limit, bootstrap seed, and sample
count become immutable.

```json
{
  "windowId": "solana-validation-2026q4",
  "startAtMs": "1790812800000",
  "trainingCutoffMs": "1790812799999",
  "maximumDrawdownBps": "5000",
  "wallets": ["11111111111111111111111111111111"]
}
```

```sh
OPERATOR_HMAC_SECRET=... \
./bin/collector solana-validation-start ./validation-window.json
```

The latest gate report is returned under `validation` by
`./bin/collector solana-wallet-flow`. It remains failed until all duration,
capture, sample-size, bootstrap, best-three-removal, drawdown, control,
cohort, latency/cost, and stress gates pass.

## Attach replay evidence

Raw-wallet-copy and quant-only control replays use `kind: control`:

```json
{
  "windowId": "solana-validation-2026q4",
  "kind": "control",
  "variant": "raw_wallet_copy",
  "tradeId": "control-trade-1",
  "cohort": "pump_launch",
  "enteredAtMs": "1790812805000",
  "exitedAtMs": "1790813705000",
  "netPnlUsdMicros": "-10000000",
  "evidenceHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
```

The four required stress scenarios are `creator_cluster_dump`, `rpc_gap`,
`quote_expiry`, and `total_loss`:

```json
{
  "windowId": "solana-validation-2026q4",
  "kind": "stress",
  "scenario": "total_loss",
  "passed": true,
  "completedAtMs": "1790813800000",
  "evidenceHash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
```

Submit either evidence body with:

```sh
OPERATOR_HMAC_SECRET=... \
./bin/collector solana-validation-evidence ./evidence.json
```

Evidence is append-only and hash-bound. Reusing an identity with different
contents is rejected. A failed untouched window stays failed; create a later,
newly frozen version after training changes instead of modifying this one.

## Live execution (default off)

Two independent switches must both be on before a lamport moves; each alone
does nothing.

1. **Arm** — console: open the Solana wallet-flow strategy and use the
   two-step "Arm live trading" control. The localhost proxy signs the
   request and generates the `ARM LIVE TRADING` approval literal itself.
   Preconditions enforced by the database: an active frozen live config, a
   non-empty followed cohort, and a started strategy. Stopping the strategy
   or emptying the cohort disarms automatically; disarm is always accepted.
2. **Executor** — start the profile with a signer directory containing
   `id.json` (a standard 64-byte Solana keypair array):

   ```sh
   SOLANA_SIGNER_KEYPAIR_DIR=/path/to/keydir \
     docker compose --profile solana-live up -d solana-live-executor
   ```

   The executor refuses to start without a key, signs only single-signer
   transactions whose fee payer is its own public key, bounds slippage to
   the intent's frozen cap, and reports authoritative fills from the
   confirmed transaction.

While armed, every FILLED paper action mirrors into a live intent bounded by
the frozen per-trade and daily caps with a 60-second TTL; without the
executor running, intents expire visibly in the console. A report of
`CONFIRMATION_TIMEOUT:<signature>` means the outcome is unknown — reconcile
that signature by hand before rearming.

Kill switch, fastest first: stop the strategy (disarms and halts entries),
`docker compose stop solana-live-executor`, or remove the signer directory.
