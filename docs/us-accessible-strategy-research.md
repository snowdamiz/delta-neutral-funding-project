# Solana Wallet-Flow Quant Strategy

**Status:** researched candidate; paper only

**Research checked:** 2026-07-31

**Capital envelope:** approximately $1,000

**Audience:** the operator implementing and validating this strategy

> This is not legal, tax, or investment advice. An SPL token is a technical
> asset format, not a blanket legal, safe, or tradable classification. Recheck
> the exact token, route, provider terms, sanctions exposure, and applicable
> law before any live transaction.

## Decision

Build one new research strategy: **Solana wallet-flow plus quant survival**.

When a configured wallet acquires a token, analyze the token and surrounding
flow before deciding `ENTER`, `WATCH`, or `REJECT`. The wallet acquisition is a
trigger, never an automatic copy order.

The candidate universe includes every exact SPL or Token-2022 mint acquired in
a confirmed swap, including swaps routed through Jupiter, Pump, PumpSwap, or
another Solana venue. Pump.fun-like launches are the primary target, but the
observer is aggregator-agnostic.

This strategy is directional and can lose the entire position. It remains
paper-only until the validation gate in this document passes. Paper deployment
has no signer or path to submit a transaction.

## Viability with $1,000

Small sizing fits this strategy, but profit is unproven and the failure rate
is high:

- public wallet acquisitions and subsequent flow are observable;
- a $10-$20 paper position can reproduce fees, price impact, and exit depth;
- recent research supports useful rug, bundle, concentration, and flow
  features; but
- wallet-ring membership alone has not shown a causal profit edge, very few
  Pump launches graduate, and simulated profit can depend on a handful of
  extreme winners.

**Verdict:** high potential upside, high probability of failure, and no
defensible expected-profit estimate before a frozen out-of-sample paper test.

## Data and credentials

No new secret is required to start acquisition capture.

| Source | Paper use | Upgrade condition |
|---|---|---|
| Existing Solana RPC and WebSocket | Confirm wallet transactions, load pre/post balances, inspect mints and accounts, and replay history | Upgrade only if measured gaps, latency, or rate limits fail the paper-fidelity gate |
| Pump and PumpSwap on-chain state | Reproduce curve/pool quotes, current fees, migration state, and fills | Keep program layouts versioned and fail closed on unknown versions |
| Jupiter Swap API | Obtain two-way quotes and route plans for broader SPL tokens | Keyless low-rate access can bootstrap capture; add an API key only when measured quote cadence requires it |
| Jupiter Tokens API | Optional metadata, verification, organic score, holder count, and trading metrics | Never let third-party metadata override on-chain safety or executable-liquidity gates |

An RPC URL or API key authorizes data access, not signing. Live execution would
require a separate signer design, exact route/legal review, and explicit
authorization.

## Acquisition detection

For each configured followed wallet:

1. subscribe to new signatures and backfill missed signatures after reconnect;
2. wait for the configured confirmation level;
3. load the transaction and compute wallet-owned pre/post token balances and
   lamports;
4. identify every exact mint whose wallet-owned balance increased;
5. require a decoded swap or an economically consistent
   input-spent/output-received pair; and
6. persist the signature, slot, confirmation timestamp, observation timestamp,
   input/output amounts, route programs, and exact mint.

Transfers, airdrops, account creation, staking receipts, liquidity-position
tokens, rebases, and rewards are not buys. Never identify an asset by symbol.
One transaction may acquire multiple output mints; evaluate each separately.

RPC capture is considered incomplete if a reconnect gap cannot be backfilled.
No decision may use a transaction before the collector actually observed it.

## Wallet and cluster markers

Freeze the followed-wallet cohort before each evaluation window. Score only
history that existed before the current decision:

- executable net markouts at 30 seconds, 2, 5, 15, and 60 minutes after prior
  acquisitions;
- win rate, median return, downside tail, maximum drawdown, and results after
  removing the wallet's three best trades;
- common funders, same-slot acquisitions, recurring co-buy groups, first-buyer
  rank, synchronized exits, and circular transfers;
- links to the creator, deployer, initial liquidity funder, and prior launch
  clusters;
- prior token survival, graduation, and creator- or cluster-dump behavior; and
- the wallet's acquired inventory relative to immediately executable exit
  depth.

A wallet needs at least 20 prior eligible acquisitions before its historical
performance receives full weight. A single followed-wallet buy may trigger
`WATCH`, but `ENTER` also requires either a second unlinked qualified wallet or
strong independent organic-flow confirmation.

"Linked cluster" and "cabal" are statistical risk labels, not allegations of
illegal conduct.

## Token, liquidity, and flow markers

Evaluate exact mint/account state, confirmed transactions, and executable
route data:

- token program and every Token-2022 extension;
- mint, freeze, permanent-delegate, transfer-hook, and transfer-fee authority;
- supply changes and circulating-supply market cap where derivable;
- launch and market programs, pool/curve age, reserves, migration status, and
  current fee structure;
- executable $10 and $20 buy/sell quotes, price impact, immediate round-trip
  loss, and independent exit routes;
- top-holder and creator-linked concentration after excluding known program,
  curve, pool, burn, and lock accounts;
- creator- and cluster-controlled inventory relative to exit depth;
- unique-buyer growth after linked clusters are removed;
- 1-minute, 5-minute, and 1-hour volume, net new quote inflow, buy-size
  diversity, and acceleration/deceleration; and
- wash, circular, self-funded, bundled, or synchronized flow.

Metadata and social presence are low-weight evidence. They may add confidence
but can never override token-control, concentration, liquidity, or sellability
checks.

## Initial paper thresholds

These are conservative starting values, not claims of optimality. Record them
as a versioned strategy configuration and freeze them during each test window.

- proposed position: $10 initially, $20 only after the $10 cohort passes;
- maximum quoted entry price impact: 2%;
- maximum immediate buy-then-sell loss: 8%, including route and token fees;
- minimum executable exit depth inside 10% impact: 10 times position size;
- maximum top-ten non-program holder concentration: 40%;
- mint and freeze authorities: disabled, unless their exact program-controlled
  behavior is decoded, immutable for the trade horizon, and explicitly
  approved by the scorer;
- independent confirmation: a second unlinked qualified wallet or at least 10
  unlinked net buyers with positive quote inflow after the trigger; and
- no creator or linked-cluster sell between trigger and entry.

Tune thresholds only on a training window. Never select a threshold using the
untouched paper window it is meant to evaluate.

## Token-2022 policy

Token-2022 is not automatically rejected. Decode every extension and include
its effects in both entry and exit:

- transfer fees must be applied in both directions using current and pending
  fee configuration;
- transfer hooks require known accounts and successful simulation;
- permanent delegates, default-frozen, non-transferable, confidential, or
  unknown behavior are hard rejects until explicitly modeled; and
- any authority or extension change invalidates the prior score and forces a
  fresh evaluation.

## Decision rules

### `ENTER`

Enter paper only when:

- the acquisition, token state, and route snapshots are complete and fresh;
- wallet/cluster evidence and independent organic-flow evidence both pass;
- every token-control and concentration gate passes;
- a proposed-size buy and sell path is executable;
- all modeled costs fit within the round-trip threshold; and
- no hard-reject reason is present.

Paper fill price is the first executable quote available **after** the recorded
decision latency, never the followed wallet's fill or a candle midpoint.

### `WATCH`

Use `WATCH` when the acquisition is valid but confirmation is incomplete—for
example, a strong wallet without independent buyers. Re-evaluate only on new
confirmed state. Never turn elapsed time alone into a pass.

### `REJECT`

Hard-reject on:

- missing, expired, or failed buy/sell quote or simulation;
- stale RPC state or an unrecoverable capture gap;
- unknown token extension, program layout, or route side effect;
- transfer restrictions the broker cannot reproduce;
- sanctions-screening hit;
- creator or linked-cluster inventory capable of overwhelming exit depth;
- creator, followed-wallet, or linked-cluster selling before entry;
- excessive price impact, round-trip loss, or concentration;
- unmodeled Pump Mayhem behavior; or
- an asset promoted as equity, debt, revenue/profit share, pooled investment,
  or promised yield pending exact legal review.

If no round-trip route exists, return `REJECT_NO_ROUND_TRIP`. Do not add a
speculative venue adapter just to force a candidate through the gate.

## Paper execution and exits

Treat the full position as the risk amount because a token can gap to zero and
a stop quote is not a guaranteed fill.

- hold one position at a time;
- start at $10 and never exceed $20 during validation;
- never average down;
- model route fees, token transfer fees, Solana base/priority fees, account
  rent, slippage, quote expiry, and price impact;
- re-quote the entire position on every exit decision; and
- keep at least $300 of the $1,000 capital envelope untouched.

Exit at the first executable sell quote when:

- the followed wallet, creator, or linked cluster sells;
- organic quote inflow reverses or buyer growth collapses;
- executable exit depth breaches its minimum;
- token authorities/extensions or route programs change;
- the frozen time-stop fires; or
- source freshness or execution simulation fails.

Do not hold through Pump migration initially. Validate pre- and post-migration
regimes separately before allowing a position to cross that boundary.

The strategy cannot guarantee an exit before a rug or coordinated dump. Paper
replay must realize gaps at the next executable quote, including a zero-value
exit when no liquidity remains.

## Paper validation gate

Do not add a signer or live allocation until one frozen strategy version has:

- at least 90 consecutive days and 100 eligible `ENTER` decisions;
- recorded observation, decision, quote, and simulated-fill latency;
- actual route/curve/pool outputs and all current costs;
- a positive lower 95% bootstrap bound on net return;
- positive net return after removing the best three trades;
- drawdown within the declared limit;
- better net results than both raw-wallet-copy and quant-only controls;
- separate passing results for Pump/new-launch and established-token cohorts;
- creator/cluster dump, RPC-gap, quote-expiry, and 100%-loss stress tests; and
- no wallet, feature, or threshold reselection using the test window.

If the gate fails, keep collecting evidence or archive the strategy. Do not
optimize against the failed untouched window and call it a new test.

## Minimal implementation order

| Step | Deliverable | Exit gate |
|---|---|---|
| Q0 | Confirmed acquisition capture, reconnect backfill, and replay | Seven continuous days with every gap accounted for |
| Q1 | Mint, holder, cluster, Pump, and Jupiter route snapshots | Every observed acquisition produces a complete snapshot or durable reject reason |
| Q2 | Versioned wallet/token scorer | Historical replay reproduces every `ENTER`, `WATCH`, and `REJECT` decision |
| Q3 | Latency-aware paper broker and exit monitor | Fees, quote expiry, route failure, zero-liquidity exits, and restarts replay correctly |
| Q4 | Frozen 90-day validation | Every paper-validation gate above passes without reselection |
| Q5 | Optional dust live canary | Separate legal review and explicit operator authorization |

Q0 through Q4 require no signer.

## Conduct and legal boundary

Use only confirmed public on-chain transactions. Do not coordinate with
followed wallets or creators, use private tips, promote positions, wash trade,
spoof flow, or attempt validator/mempool front-running. Screen wallet and route
links against current sanctions data.

Typical meme coins may not themselves be securities under current SEC staff
guidance, but that is not a blanket rule. The exact asset and transaction can
still create securities, fraud, manipulation, sanctions, terms-of-use, or
state-law issues. Public API access does not decide legal eligibility.

## Primary sources

### Protocol and market data

- [Solana address-history RPC](https://solana.com/docs/rpc/http/getsignaturesforaddress)
- [Solana transaction RPC](https://solana.com/docs/rpc/http/gettransaction)
- [Solana log subscription](https://solana.com/docs/rpc/websocket/logssubscribe)
- [Solana token basics](https://solana.com/docs/tokens/basics)
- [Solana Token-2022 transfer fees](https://solana.com/docs/tokens/extensions/transfer-fees)
- [Solana transaction fees](https://solana.com/docs/core/fees)
- [Jupiter Swap API V2](https://developers.jup.ag/docs/swap/index)
- [Jupiter Tokens API V2](https://developers.jup.ag/docs/tokens/index)
- [Jupiter market-routing qualification](https://developers.jup.ag/docs/swap/routing/market-listing)
- [Pump program documentation](https://github.com/pump-fun/pump-public-docs/blob/main/docs/PUMP_PROGRAM_README.md)
- [PumpSwap program documentation](https://github.com/pump-fun/pump-public-docs/blob/main/docs/PUMP_SWAP_README.md)
- [Pump dynamic-fee program](https://github.com/pump-fun/pump-public-docs/blob/main/docs/FEE_PROGRAM_README.md)

### Eligibility and conduct

- [Jupiter terms](https://developers.jup.ag/docs/legal/terms-of-use)
- [Pump.fun terms](https://pump.fun/docs/terms-and-conditions)
- [SEC interpretation of federal securities laws for crypto assets](https://www.sec.gov/rules-regulations/2026/03/s7-2026-09)
- [SEC staff statement on meme coins](https://www.sec.gov/newsroom/speeches-statements/staff-statement-meme-coins)
- [OFAC virtual-currency sanctions guidance](https://ofac.treasury.gov/system/files/126/virtual_currency_guidance_brochure.pdf)

### Edge research, treated as preliminary rather than proof

- [SolRugDetector: Solana rug-pull detection](https://arxiv.org/abs/2603.24625)
- [MemeTrans: launch-transaction risk features](https://arxiv.org/abs/2602.13480)
- [Pump.fun graduation study](https://arxiv.org/abs/2607.02823)
- [Solana early-buyer cohort study](https://arxiv.org/abs/2607.02795)
- [Execution-realistic memecoin paper-trading fragility](https://arxiv.org/abs/2606.08232)
