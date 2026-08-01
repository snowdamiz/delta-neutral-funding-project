# Strategy contracts and invariants

## Shared contract

Every portfolio starts from its configured USD capital and never shares
balances, orders, fills, or ledger batches with another. All quantities,
prices, rates, fees, and P&L are fixed-scale signed integers. Every
multiplication or division names its rounding policy.

Entry is allowed only when normalized short funding receipt is positive after
fees and haircuts, all source data is fresh and gap-free, an executable exit is
deep enough, margin and liquidation limits pass, and expected net carry remains
positive over the configured holding period.

No state becomes `HEDGED` until confirmed spot and perp quantities reconcile.
An in-flight intent is persisted before any side effect. Duplicate source events
and commands are idempotent. Unknown outcomes pause the portfolio and reconcile
before retry.



## NEGATIVE_FUNDING_REVERSE

- Select only the top qualified market per venue after seven clean days and a
  24-hour average below the configured negative-funding threshold.
- Borrow and sell the spot asset at the executable bid; long the same quantity
  of its perpetual at the executable ask.
- Attribute realized long-perp funding, spot/perp basis, trading costs, and
  variable borrow interest separately.
- Require a fresh, identity-pinned Kamino snapshot, at least 2× target notional
  in available borrow liquidity, and utilization below the configured ceiling.
- Exit on the current observation when borrow APR reaches the absolute funding
  rate, borrow evidence becomes stale or invalid, or borrow liquidity and
  utilization breakers fail. Never average a borrow spike away.
- This contract is paper-only; live use additionally requires on-chain
  obligation health, collateral/liquidation, oracle, and program-authority
  checks listed in `kamino-qualification.md`.

## JITOSOL_NAV_DISCOUNT

- Buy only when the executable JitoSOL ask is below protocol NAV and the
  better of direct redemption and instant exit remains positive after modeled
  costs and the configured risk haircut.
- Positive short funding may improve a genuine discount but never makes a
  zero-discount trade eligible.
- Hedge the purchased quantity at its protocol-NAV SOL equivalent and require
  both JitoSOL and perp exit depth for the full hedge.
- Direct redemption reuses the epoch-aware counterfactual state machine and
  attributes realized discount basis separately from actual cooldown funding.
- Invalid oracle state, decreasing NAV, stale source data, insufficient depth,
  unsafe margin, paused entries, and an unhedged synchronized SOL benchmark
  veto entry.
- This contract is paper-only; direct unstake remains unavailable for
  immediate perp-margin protection and live execution remains unapproved.



## Fail-closed conditions

Schema mismatch, integer parse failure, overflow, stale data, source gap, invalid
oracle, missing or stale borrow evidence, leader loss, unbalanced ledger batch,
risk actor failure, adapter identity mismatch, and executor uncertainty all
stop new entries.

## SOLANA_WALLET_FLOW (v2)

- A followed wallet's confirmed acquisition is a trigger, never a copy
  order: the exact mint must clear token-control, concentration,
  linked-inventory, executable round-trip, exit-depth, and organic
  confirmation gates before a $100 paper entry, and at most three positions
  are open at once.
- Exits are recoup-then-ride: at the configured multiple the broker sells
  exactly enough to recoup entry cost plus fees, then trails the remainder
  on the executable quote's high-water mark. Positions that never progress
  stop out on the flat time stop or hard stop-loss; migration is recorded
  and held through, never sold reflexively.
- Creator/cluster sells, sanctions hits, authority changes, and depth loss
  exit immediately. Flow-collapse and no-liquidity exits require the
  configured consecutive confirming snapshots, so a rug realizes at the
  executable (possibly zero) quote while a quote blip does not.
- Wallet discovery only nominates: a wallet joins the cohort exclusively
  through the audited atomic cohort mutation.
- Live mode is default-off and doubly switched: the HMAC-signed arm with
  its literal approval string, and the separately-run executor holding the
  only signing key. Armed intents mirror FILLED paper actions inside frozen
  per-trade and daily caps and expire in 60 seconds; live fills are
  recorded from the confirmed transaction, never from the quote.
- The frozen 90-day validation gate is unchanged and no result authorizes
  raising the live caps by itself.
