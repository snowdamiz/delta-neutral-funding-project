# Kamino lending-market qualification

Status: **qualified for read-only paper evidence only**. This does not approve
transaction construction, borrowing, or live capital.

## Pinned integration

- Protocol: Kamino Lend, mainnet KLend program
  `KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD`.
- Market: `SOL/BTC Market`,
  `7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF`.
- SOL reserve:
  `d4A2prbA2whesmvHaL88BH6Ewn5N4bTSU2Ze8P6Bc4Q`;
  mint `So11111111111111111111111111111111111111112`.
- JTO reserve:
  `9Ukd2MSw5RvVFaN8jLhWxjHLEGiF1F6Hf7v3Zq5hZsKB`;
  mint `jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL`.

The adapter reads the public reserve-metrics endpoint documented by Kamino and
requires an exact market/reserve/mint match. No address is accepted from the
response as configuration. See [program addresses][programs] and
[market reserve APYs][reserve-api].

## Rate and liquidity mechanics

Kamino documents variable borrow rates as reserve-specific utilization curves:
rates rise with utilization and become steep near full utilization. Interest
accrues continuously, while the metrics API reports `borrowApy`,
`totalSupplyUsd`, and `totalBorrowUsd`. There is no origination fee in the
standard borrow flow. See [fees and interest rates][rates] and
[borrowing mechanics][borrowing].

Each hourly funding capture takes a same-cycle borrow snapshot. The adapter:

1. converts decimal USD values to integer micros;
2. computes available liquidity as supply less borrow;
3. computes utilization from those two live totals; and
4. converts APY to a conservative hourly ppm cost by rounding
   `APY / 8,760` upward.

The upstream API does not promise a publication cadence. Evidence is therefore
timestamped locally and expires after `SOURCE_MAX_BORROW_AGE_MS` (two hours by
default); stale or malformed data fails closed.

Entry needs at least twice the target notional in currently available
liquidity and utilization no higher than
`REVERSE_MAX_BORROW_UTILIZATION_PPM` (95% by default). A live rate at or above
the current absolute funding rate, loss of borrow data, insufficient
liquidity, or excessive utilization is an immediate exit breaker. The rate is
never averaged. This treats lender withdrawal pressure as a liquidity and
rate-spike risk; Kamino is peer-to-pool, so there is no matched lender recall.

## Liquidation and oracle risk

Kamino borrowing is overcollateralized. Debt grows with variable interest and
an obligation becomes liquidatable when its risk-adjusted debt breaches the
configured liquidation threshold. Borrow factors can make the effective
buffer smaller than headline LTV. Liquidations are permissionless. See
[borrowing][borrowing] and [infrastructure monitoring][infrastructure].

Reserve parameters, including LTV, liquidation threshold, borrow factor,
interest curve, caps, status, and oracle configuration, are mutable. Kamino
supports Scope, Pyth, and Switchboard mappings plus emergency price blocking;
an accepted parameter update applies to existing positions. See
[reserve management][reserve-management].

The Phase 2 implementation does not construct an obligation and therefore does
not pretend the REST metrics snapshot proves live obligation health. Before
live use, the adapter must additionally pin and validate:

- the selected collateral reserve and its live max/liquidation LTV;
- borrow factor, caps, reserve status, and oracle accounts/age limits;
- obligation health and debt balance after every refresh; and
- an executable repay-and-close path under stressed collateral and asset
  prices.

Any failure pauses live eligibility. Paper portfolios remain accounting
simulations and use the existing fixed notional envelope.

## Program control, audits, and incidents

The pinned KLend address is currently an executable upgradeable-loader
program. Kamino publishes multiple KLend audits, including reports from
OtterSec, Certora, Offside Labs, and Ackee; the reports and scope dates are
linked from its [audit inventory][audits]. Audit coverage reduces but does not
remove smart-contract or governance risk.

Market and reserve ownership can update risk parameters, and emergency controls
can disable borrowing or price use. The paper integration records the pinned
program and market but does not yet attest the program-data upgrade authority,
market owner, multisig threshold, or timelock. Those identities must be
captured from chain and reviewed again at the live-release freeze.

Kamino reports that its liquidation system processed the February 2026 stress
event without bad debt, but that is protocol-published evidence rather than an
independent incident registry. The qualification therefore treats incident
history and control authority as unresolved live gates, not proof of safety.

## Decision

The public metrics source is adequate for Phase 2 paper ranking and variable
borrow-cost attribution. Live borrowing remains disallowed until transaction
construction, collateral/oracle health, program authority, legal eligibility,
and an independent incident review are completed.

[programs]: https://kamino.com/docs/build/resources/program-addresses
[reserve-api]: https://kamino.com/docs/build/borrow/get-market-reserve-apys
[rates]: https://kamino.com/docs/products/borrow/fees
[borrowing]: https://kamino.com/docs/products/borrow/borrowing
[infrastructure]: https://kamino.com/docs/security/infrastructure
[reserve-management]: https://kamino.com/docs/curators/markets/reserve-management
[audits]: https://kamino.com/docs/security/audits
