# Paper venue qualification: Phoenix

Status: selected for read-only paper data; not approved for live execution.

Drift was withdrawn as the paper-data candidate on 2026-07-25. Its official
recovery updates describe the legacy protocol as paused while a reboot is in
progress, and Velocity documents a new deployment and program ID with no
on-chain state carried over. Treating the old Drift contract as authoritative
would therefore be unsafe.

## Phoenix evidence

- The current Phoenix exchange snapshot reports program
  `EtrnLzgbS7nMMy5fbD42kXiUzGg8XQzJ972Xtk1cjWih`, an active exchange, and an
  active `SOL` perpetual market.
- The documented REST API exposes exchange snapshots, market parameters,
  executable orderbook levels with source slots, mark prices, and hourly
  funding history.
- Funding is positive for shorts when mark is above index: longs pay shorts.
  Hourly funding accumulates continuously and settles every 24 hours.
- Current SOL configuration exposes integer basis-point risk fields, one-hour
  funding intervals, base-lot precision, fee rates, open-interest caps, and
  source slots. Float convenience fields are never forwarded across the
  adapter contract.
- Qualification probes found the documented read endpoints readable without a
  token. The adapter still supports an optional bearer token because the
  OpenAPI contract marks it required.

Official sources:

- https://docs.phoenix.trade/phoenix/perpetual-futures
- https://docs.phoenix.trade/phoenix/margin-and-risk/funding-rate
- https://docs.phoenix.trade/api/exchange/get-exchange-snapshot
- https://docs.phoenix.trade/api/exchange/get-market
- https://docs.phoenix.trade/api/exchange/get-orderbook
- https://docs.phoenix.trade/api/exchange/get-funding-rate-history
- https://docs.phoenix.trade/openapi/phoenix-public-api.json
- https://www.drift.trade/updates/drift-recovery-update-june-3-2026
- https://docs.velocity.exchange/developers/concepts/program-vault-addresses

## Paper normalization

The adapter combines a slotted Phoenix SOL book and funding record, slotted
JitoSOL stake-pool state from Solana RPC, and exact Jupiter spot quotes. It
converts decimal source fields to checked integer atoms at the boundary.
Jupiter's official keyless tier is used at no more than 24 quote requests per
minute at the default interval; a key is optional and never grants mutation
authority. Swap V1 remains necessary for exact-output paper quotes while Swap
V2 supports only exact-input orders, and must be reconsidered if that contract
changes.
Opportunity estimates may use the latest completed hourly rate, but the ledger
settles only from a unique authoritative funding record or reconciled account
delta.

Source timeout, non-2xx responses, invalid account owners, stale stake-pool
epochs, mint-supply mismatches, crossed or empty books, incoherent slots,
missing exact quotes, and invalid decimal fields all fail closed. Paper prices
use exact-size spot quotes and executable L2 with an adverse haircut; they never
use oracle, mark, or midpoint fills.

## Qualification still required for live

- Pin and independently verify the Phoenix program, market, oracle, and account
  layouts at startup.
- Reproduce exact fee, margin, liquidation, funding-cap, and settlement
  behavior from the pinned on-chain program.
- Measure fill depth, partial fills, confirmation latency, and provider
  failover over the required soak.
- Confirm legal, jurisdictional, API, and account eligibility.
- Complete shadow comparison and independent security review.
