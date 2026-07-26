# Paper venue qualification: Drift

Status: selected as a paper-data candidate; not approved for live execution.

## Evidence

- Drift defines funding as one twenty-fourth of the average premium each hour.
  Positive funding means longs pay shorts.
- Historical funding records expose separate long and short rates, cumulative
  rates, oracle/mark TWAPs, slot, timestamp, and transaction signature.
- Funding-payment records describe a positive payment for a long and a negative
  payment for a short. The collector preserves this venue sign and separately
  normalizes `short_receipt_atoms = -funding_payment_atoms`.
- The SDK uses integer `BN` values: price and quote precision are `1e6`, and
  base precision is `1e9`.
- The official SDK supports account subscription, oracle reads, order building,
  funding settlement, and polling or WebSocket data paths.
- SOL-PERP is currently documented as a B-tier contract. Tier, open-interest,
  margin, fee, oracle, and program settings remain runtime inputs, not constants.

Official sources:

- https://docs.drift.trade/glossary
- https://docs.drift.trade/developers/data-api/glossary
- https://docs.drift.trade/developers/drift-sdk/precision-and-types
- https://docs.drift.trade/protocol/trading/market-specs
- https://github.com/drift-labs/protocol-v2/blob/master/sdk/README.md

## Paper normalization

The adapter emits raw integer strings and the source slot. Opportunity estimates
may use a predicted rate, but the ledger settles only from a unique authoritative
funding record or reconciled account delta. Missing intervals, duplicate record
IDs, stale or invalid oracles, and a negative normalized short receipt fail
closed for new entries.

The paper fill model uses executable L2 or an exact venue estimate plus an
adverse haircut. It never fills at the oracle, mark, or midpoint.

## Qualification still required for live

- Pin and verify SDK, program, market, oracle, and account addresses.
- Reproduce exact fee, margin, liquidation, funding cap, and settlement behavior.
- Measure fill depth, partial fills, confirmation latency, and RPC failover.
- Confirm legal, jurisdictional, and account eligibility.
- Complete shadow comparison and independent security review.

