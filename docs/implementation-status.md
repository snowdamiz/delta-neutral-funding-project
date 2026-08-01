# Implementation status

## 2026-08-01 refocus

The platform was refocused on the strategies that can actually reach real
money at the operator's capital and jurisdiction. Four strategies were
retired and their decision logic, registrations, routes, and UI removed
(historical evidence tables are preserved; schema 53):

| Retired | Why |
|---|---|
| `sol_control` / `jitosol_carry` (Phoenix SOL carry pair) | Phoenix's 2026-07-27 terms bar US/CA/UK persons; the trade opened zero of 1,722 recorded gates and its best case was ~$180/year |
| `cross_venue_funding` | Requires two live perp venues; Phoenix is read-only and restricted, Hyperliquid is restricted, Drift is paused mid-reboot |
| `hyperliquid_wallet_flow` / `_mirror` / `_fade` | The venue is closed to the operator, so no mode could ever monetize |

The MarketSnapshot ingest (Phoenix + JitoSOL + Jupiter capture) survives:
the cross-asset scanner uses the Phoenix funding row as its SOL venue and
the NAV-discount strategy consumes the JitoSOL snapshot and the epoch-aware
direct-unstake counterfactual ledger. FundingSettlement events now feed only
that counterfactual ledger.

## Registered strategies

| Strategy | State | Evidence |
|---|---|---|
| `solana_wallet_flow_quant` (centerpiece) | v2 implemented; frozen 90-day validation not started | Schema 50 replaces the v1 broker's amputated exit path (15-minute hard stop, no profit-taking, exit-on-migration, exit-on-one-bad-print) with a recoup-then-ride engine: $100 positions, up to 3 slots, take-profit ladder that recoups cost at 2×, trailing stop on the executable quote's high-water mark, hard stop-loss, flat-only time stop, debounced flow-collapse and no-liquidity exits, and hold-through-migration with the crossing recorded. Schema 51 adds wallet discovery: every candidate snapshot persists its earliest unlinked buyers, and wallets repeatedly early into mints that later ran are nominated in the read model — promotion is the existing audited cohort mutation. Schema 52 adds default-off live execution (below). `db/tests/solana_paper_broker.sql`, `wallet_discovery.sql`, `solana_live_mode.sql`, adapter and UI tests are executable evidence |
| `cross_asset_funding` | Implemented; 30-day paper gate not yet passed | Hourly Hyperliquid all-perp capture plus the Phoenix SOL row; schema 33 gates on 24h averages, clean history, and 2× exit depth. Live execution requires a US-accessible perp venue that does not currently exist |
| `negative_funding_reverse` | Implemented; paper gate not yet passed | Kamino borrow economics against deeply negative funding; the borrow-rate spike breaker exits immediately. Same live-venue constraint as the scanner |
| `jitosol_nav_discount` | Implemented; 30-day paper gate not yet passed | Schema 35 gates each JitoSOL snapshot on executable ask vs protocol NAV net of all costs; direct cycles reuse the epoch-aware unstake ledger. The only carry-family strategy whose venues (Jupiter, the Jito stake pool) are accessible to the operator |

Benchmark declarations were removed with `sol_control`; strategies stand on
their own recorded net. The synchronized comparison books ended with it, and
the surviving scanners' synchronized gates were patched out in schema 53.

## Live execution

The collector remains a paper system: `EXECUTION_MODE` stays `paper`, CI
still asserts a live-mode boot fails, and the paper broker trades every
decision regardless of mode. Live trading for `solana_wallet_flow_quant` is
a default-off mirror with two independent switches:

1. **The arm switch** (`POST /v1/strategies/solana_wallet_flow_quant/mode`)
   is HMAC-signed, requires the literal approval `ARM LIVE TRADING`, an
   active frozen live config, a configured cohort, and a started strategy.
   Stopping the strategy or emptying the cohort disarms automatically.
   While armed, every FILLED paper action enqueues a live intent capped by
   the frozen per-trade ($250) and daily ($1,000) limits with a 60-second
   TTL.
2. **The executor** (`solana-live-executor` compose profile, off by
   default) holds the only signing key, claims intents over the
   adapter-HMAC surface, executes them through Jupiter with the configured
   slippage bound, and reports authoritative fills back. It refuses to
   start without a keypair, only signs single-signer transactions whose fee
   payer is its own key, and treats expiry, failed preflight, and expired
   blockhashes as terminal failures.

Unexecuted intents expire visibly; live fills, positions, spend, and
failures are all in the read model and console. Confirmation-timeout
outcomes are reported with the signature for manual reconciliation.
<!-- ponytail: no automatic live reconciler yet; add one before scaling past
     the frozen caps. -->

## Validation gates (unchanged in spirit)

The frozen 90-day wallet-flow validation window (schema 46) still requires
100 eligible entries, a positive lower 95% bootstrap bound, positive net
after removing the best three trades, drawdown inside the declared limit,
beating both raw-copy and quant-only controls, separate pump/established
cohort passes, and all four stress scenarios. The v2 broker keeps exact
per-position realized P&L semantics, so the gate machinery is unchanged.
Live caps are intentionally small until that gate passes.
