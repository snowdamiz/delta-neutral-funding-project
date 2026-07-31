# Multi-Strategy Expansion Plan

## Phased Roadmap Beyond Single-Venue SOL Funding Carry

**Document status:** Implementation-ready roadmap derived from a full review of the running paper system
**Parent document:** `solana_delta_neutral_funding_collector_plan.md` (2026-07-25)
**Review evidence:** Live collector API, `opportunity_decisions` history, July 27 soak backup, live Hyperliquid funding data
**Capital envelope:** $5,000 or less working capital; strategies are ordered for this constraint
**Default operating mode:** `paper` — every strategy, every phase, no exceptions
**Live policy:** One live experiment at a time, first live notional capped at $500, only after its own paper and shadow gates pass
**First implementation step:** Phase 0 — generalize the operator console so every later phase lands in it without rework
**Prepared:** July 30, 2026

> **Risk notice:** Every strategy in this document can lose money, including the "market-neutral" ones. Funding can reverse, borrow rates can spike past collected funding, an LST can depeg below its protocol NAV for longer than an unstake epoch, two perp venues can diverge, a copied wallet's edge can be unmirrorable at any latency, and keeper income can be competed to zero. Paper results are not guarantees of live performance. Venue eligibility and applicable laws must be checked before live trading; access restrictions must not be bypassed.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Review of the Current System](#2-review-of-the-current-system)
3. [Capital Reality and Ordering Principle](#3-capital-reality-and-ordering-principle)
4. [Phase 0: Multi-Strategy Operator Console](#4-phase-0-multi-strategy-operator-console)
5. [Phase 1: Cross-Asset Funding Scanner](#5-phase-1-cross-asset-funding-scanner)
6. [Phase 2: Negative-Funding Reverse Carry](#6-phase-2-negative-funding-reverse-carry)
7. [Phase 3: JitoSOL NAV Discount Arbitrage](#7-phase-3-jitosol-nav-discount-arbitrage)
8. [Phase 4: Cross-Venue Funding Arbitrage](#8-phase-4-cross-venue-funding-arbitrage)
9. [Phase 5: Hyperliquid Wallet Tracking](#9-phase-5-hyperliquid-wallet-tracking)
10. [Phase 6: Drift Keeper and Liquidator Bot](#10-phase-6-drift-keeper-and-liquidator-bot)
11. [Deliberate Exclusions](#11-deliberate-exclusions)
12. [Shared Infrastructure Reuse](#12-shared-infrastructure-reuse)
13. [Phased Implementation Plan](#13-phased-implementation-plan)
14. [Paper and Go-Live Gates](#14-paper-and-go-live-gates)
15. [Definition of Done](#15-definition-of-done)
16. [Reference Sources](#16-reference-sources)

---

# 1. Executive Summary

The delta-neutral funding collector is correct, disciplined, and idle. Its
entry gates have vetoed every one of the 1,722 recorded opportunity decisions
because the trade it watches — short SOL-PERP funding carry — pays
approximately nothing in the current regime. That is the gates working, not
failing.

This document reorders the project around three facts the review established:

1. **Regime:** SOL funding is 0.6–0.9% APR across venues today and was
   *negative* for much of 2026 (–18% annualized on Hyperliquid in February).
   A single-asset, single-direction carry system spends most of its life
   waiting.
2. **Capital:** At $5,000 or less, every percentage-of-capital strategy is
   bounded near $1,000/year even at an excellent 20% APY. The bottleneck is
   capital, not code.
3. **Infrastructure:** The Mesh core — fixed-point finance, opportunity
   gates, paper broker, evidence trail, replay — is strategy-agnostic and
   dramatically over-provisioned for one trade. It should amortize across
   many.

Implementation starts with **Phase 0**: generalizing the operator console
from a hardcoded two-variant comparison into a strategy-registry-driven
surface, so each later phase lands as data and registry metadata rather than
UI rework. Six strategies follow, ordered by infrastructure reuse, edge
honesty, and fit for the capital envelope. The current system is retained as
the regime monitor and control. The blended goal for Phases 1–4 is a book
that earns $1,000–2,000/year across regimes instead of ~$0 waiting for one.
Phases 5–6 are the only entries with a ceiling not set by the bankroll, and
they carry the strictest paper gates for exactly that reason.

The operating doctrine is unchanged from the parent plan:

- Paper mode is the default and the only initially approved mode.
- One broker interface; no `if paper` branches in strategy code.
- Fail-closed gates with written go/no-go criteria *before* the paper run starts.
- PostgreSQL is authoritative; every decision leaves evidence.
- A strategy that misses its paper gate is archived, not tuned until it passes.

---

# 2. Review of the Current System

## 2.1 Findings (2026-07-30)

| Fact | Value |
|---|---|
| SOL funding, Phoenix (authoritative adapter) | 1 ppm/hour ≈ 0.9% APR |
| SOL funding, Hyperliquid (independent cross-check) | 0.59% APR |
| BTC / JTO funding, Hyperliquid, same moment | 10.95% APR |
| Combined carry needed to open the entry gate | ~10.4 ppm/hour ≈ 9.1% APR |
| Funding component needed (after 3.5% JitoSOL reward carry) | ~6.4 ppm/hour ≈ 5.6% APR |
| Gate openings, current run (160 decisions) | 0 |
| Gate openings, July 27 soak (1,562 decisions) | 0 |
| Position notional at current config | ~$499 |
| Modeled entry cost + risk haircut | $0.25 (~5 bps) |
| Best-case annual return at current sizing | ~$180 |

## 2.2 Verdict

The system is a well-built instrument pointed at a silent market:

- **The math is right.** Entry gates, break-even projection, cost model, and
  the JitoSOL reward haircut all check out against independent data.
- **The trade is regime-locked.** Short-perp carry pays only when longs crowd
  the book. 2026 is the opposite regime, and the system has no reverse gear.
- **The venue has no live path.** Phoenix perps are private beta; the 30-day
  soak has not started; live execution is correctly gated off.
- **The ceiling is structural.** Even a great year at this sizing is a few
  hundred dollars. No amount of additional engineering on this one trade
  changes that.

**Disposition:** keep it running unmodified as the SOL regime monitor and the
control against which every new strategy is compared. Stop investing in it as
the main event.

---

# 3. Capital Reality and Ordering Principle

## 3.1 The arithmetic

```text
$5,000 × 20% APY (excellent, rarely sustained)  =  $1,000 / year
$5,000 × 10% APY (good, realistic when deployed) =    $500 / year
```

Any strategy whose income is a percentage of deployed capital obeys this
bound. Nothing in this document claims otherwise, and any strategy that
appears to should fail its paper gate.

## 3.2 What the ordering optimizes

1. **Build the surface once.** Every phase reports through the same console;
   generalizing it first means each strategy lands as registry metadata, not
   a UI rewrite (Phase 0).
2. **Widen when capital can earn.** A scanner that finds carry on *some*
   asset beats waiting for SOL's regime (Phase 1, 2, 4).
3. **Harvest data already collected.** The NAV/market comparison is already
   in PostgreSQL doing nothing (Phase 3).
4. **Escape the capital bound last, deliberately.** Service-income and
   skill-income strategies (Phase 5, 6) have uncapped ceilings and the
   weakest prior evidence, so they run last with the longest paper periods.

## 3.3 Standing capital rules

- Total at risk across all live strategies never exceeds the envelope.
- First live deployment of any strategy: **$500 notional maximum** (10% of
  bankroll), scaling only after 30 live days match paper within tolerance.
- Perp collateral intentionally overcollateralized; reduce exposure rather
  than add collateral, exactly as the parent plan requires.
- If any strategy goes live on Drift, use JitoSOL as perp collateral where
  supported: the same dollars earn staking yield and margin the short,
  roughly doubling capital efficiency over the separate-collateral model.

---

# 4. Phase 0: Multi-Strategy Operator Console

## 4.1 Objective

Turn the operator console from a page *about one thesis* into a surface
*over N strategies*, before any new strategy exists. Every later phase
delivers its evidence — rankings, gates, positions, attribution, paper
results — through this console; retrofitting a hardcoded two-variant UI six
times costs more than generalizing it once.

## 4.2 Current state (review findings)

The console (`ui/src/`) is a single-page React app with eight sections —
Signal, Thesis, Book, Attribution, Risk, Opportunity, Ledger, Platform —
composed in `App.tsx` around one fixed narrative:

- `api.ts` hardcodes the strategy universe as a closed union:
  `export type Variant = "sol_control" | "jitosol_carry"`, and models
  comparison fields (`jitosolNetRecordedUsd`,
  `jitosolIncrementalNetRecordedUsd`) as top-level names.
- The header copy, Thesis section, and Attribution framing assume exactly
  two portfolios answering one question ("does JitoSOL's staking yield
  survive the carry?").
- Start/Stop paper controls are global (resume / pause-all through the
  HMAC-signing localhost proxy), with no per-strategy scope.
- The read API already carries `variant` on positions, opportunities, P&L,
  and risk decisions, so the data layer is closer to generic than the UI.

## 4.3 Scope

### Read API

- Add a strategy catalog endpoint (`/v1/strategies`): one entry per
  registered strategy with id, display name, family (carry, arbitrage,
  signal, service), leg descriptions, benchmark strategy id, mode
  (paper/shadow/live), and run state. The collector owns this list; the UI
  must never hardcode it.
- Keep every existing endpoint's integer-string fixed-point contract
  unchanged; new strategies appear as new `variant`/strategy ids in the same
  streams.

### Console

- Replace the closed `Variant` union with the catalog: strategy identity
  becomes data (`string` id + catalog metadata), and the UI renders whatever
  the collector registers.
- Generalize the page structure: an overview grid (one card per strategy —
  state, gate status, net paper P&L, last decision reason code) with
  per-strategy detail views composed from the existing section components,
  parameterized by strategy id.
- Generalize the comparison frame from "JitoSOL vs SOL" to "strategy vs its
  declared benchmark," driven by the catalog's benchmark field, so
  SOL_CONTROL keeps its role for the carry family and Phase 1's scanner can
  declare it too.
- Reason-code and gate displays render any code the read API emits; no
  client-side enumeration of gate reasons.
- Scope Start/Stop paper controls per strategy run (the proxy signs the same
  two mutations, now carrying a strategy id), with pause-all retained.
- Reserve an overview slot for the Phase 1 funding leaderboard (per-asset
  funding, EMA, gate distance) so the scanner lands into an existing frame.

## 4.4 Exclusions

- No new mutation surface beyond per-strategy start/stop; destructive
  operations stay in `bin/collector`.
- No dashboard-driven mode switching — unchanged from the parent plan.
- No speculative rendering for strategy families that carry no data yet
  beyond the overview card and reserved leaderboard slot.

## 4.5 Gate (definition of done for Phase 0)

**Status: passed, 2026-07-30.** Evidence in `docs/implementation-status.md`. Two
scope notes recorded against the plan as written:

- The collector's pause state is a singleton (`control_state`), so per-strategy
  Start/Stop is plumbed but not honoured: the catalog declares
  `controlScope: "global"`, and the console keeps a single collector-wide switch
  in the overview status banner rather than offering N per-card buttons that all
  stop everything. The
  strategy id is signed into each command's reason, so the evidence trail records
  which strategy an operator acted on. A per-strategy pause needs a migration and
  a change to `apply_operator_command` — a schema bump this phase's own
  "do not touch strategy logic or build identity" constraint forbids. Flip
  `control_scope` to `strategy` when that lands; the console needs no change.
- `/v1/pnl/comparison` is unchanged and still served, but the console no longer
  reads it: benchmark comparison is computed from `/v1/pnl` paired through
  `/v1/portfolios`, which generalises to any declared benchmark without naming a
  variant in a field name.
- Hued strategy identity stops at three slots. A fourth categorical hue cannot
  clear the all-pairs CVD and normal-vision floors on this surface, and cards are
  compared in any order, so slot 4+ render a neutral key with the name beside it.


- Adding a strategy requires **zero UI code changes**: register it in the
  collector, and the console renders its card, detail view, gates, and
  ledger from the catalog. Verified by registering a synthetic third
  strategy in a dev build and confirming the console renders it correctly.
- Existing two-variant views reproduce today's information without loss:
  the JitoSOL-vs-SOL comparison, attribution split, margin floors, and
  capability matrix all survive the generalization.
- `npm test` extends to the catalog contract and per-strategy control
  signing; existing proxy-signature and fixed-point tests stay green.
- The soak currently running is not interrupted: read-only API additions
  and console changes deploy without touching the collector's strategy
  logic, build identity pinning, or the paper evidence trail.

---

# 5. Phase 1: Cross-Asset Funding Scanner

## 5.1 Strategy definition

```text
For every perp asset A on qualified venues (Hyperliquid, Drift):
  observe funding_A hourly
  rank by projected net carry using the existing opportunity model
  when gate opens for asset A:
    Spot leg:       +N A          (via Jupiter, or venue spot)
    Perpetual leg:  -N A-PERP
    Target net:      0 A delta
```

Same trade as the current system with the asset as a parameter. On review
day, JTO and BTC funding paid 10.95% APR while SOL paid 0.59% — an 18x
spread inside identical infrastructure.

## 5.2 Why this is first after the console

- Smallest delta from what exists: the fixed-point pipeline, entry gates,
  paper broker, and `opportunity_decisions` evidence already work; the
  snapshot needs an asset identifier.
- Its multi-asset funding feed is a prerequisite for Phases 2, 4, and 5.
- It converts "wait months for one regime" into "something is usually paying
  somewhere."

## 5.3 Sources of expected return

```text
Net return
  = realized funding received on the ranked asset
  - spot and perp entry/exit fees
  - spread and slippage
  - chain and execution fees
  - hedge-error and recovery losses
```

## 5.4 Scope

- Funding capture for every perp on Hyperliquid
  (`POST https://api.hyperliquid.xyz/info`, `{"type":"metaAndAssetCtxs"}` —
  one keyless call returns funding, mark, and open interest for all assets)
  and Drift's public data API.
- Per-asset funding EMA and percentile columns. Funding is autocorrelated;
  the gate consumes the 24h average, never a single hourly print.
- Paper portfolios on the top-ranked asset, using the existing independent
  and controlled comparison machinery with SOL_CONTROL as the benchmark.
- Depth-qualified assets only: executable exit depth at 2× position size,
  same discipline as the JitoSOL exit-depth veto.
- Ranking surfaced in the Phase 0 leaderboard slot: per-asset funding, EMA,
  and distance-to-gate.

## 5.5 Exclusions

- Long-tail assets without qualified exit depth.
- More than one concurrently open paper position per venue initially.
- Any execution path; this phase is capture, ranking, and paper only.

## 5.6 Paper gate (go/no-go, written before the run)

- **Duration:** 30 days of multi-asset capture.
- **Go:** entry gate opens on ≥3 distinct assets with positive paper net
  carry after modeled costs; scanner finds strictly more gate-hours per
  month than SOL alone.
- **Kill:** fewer gate-hours than SOL alone, or realized paper carry
  negative after costs across the window.

## 5.7 Realistic expectation at $5,000

8–15% APY *when deployed* → $400–750/year. Modest, but it earns during
regimes where the current system earns zero.

---

# 6. Phase 2: Negative-Funding Reverse Carry

## 6.1 Strategy definition

```text
When funding_A is deeply negative (shorts pay longs):
  Borrow leg:     borrow N A on Kamino/marginfi, sell for stable
  Perpetual leg:  +N A-PERP
  Target net:      0 A delta
  Income:          |funding| received on the long perp
  Cost:            variable borrow APR + fees
```

The mirror of the current trade. The parent plan excluded it deliberately
(§2.4) as MVP scope control; the 2026 regime is the argument for adding it
now. February's –18% SOL funding was a better opportunity than anything
positive funding offered all year, and this codebase watched it with no way
to act.

## 6.2 Why this is second

- Requires Phase 1's funding feed and reuses its per-asset gates with one
  new term (borrow cost) in the carry math.
- Doubles the harvestable regimes: the book earns on both signs of the
  funding distribution.
- Adds exactly one new integration: a qualified lending market.

## 6.3 Sources of expected return

```text
Net return
  = |realized negative funding| received
  - realized borrow interest        (variable; live input, never a constant)
  - spot sell/buy-back fees and slippage
  - perp entry/exit fees
  - chain and execution fees
  - recovery losses
```

## 6.4 Lending-market qualification (before paper)

Apply the parent plan's venue-qualification discipline:

- Borrow APR mechanics, update cadence, and utilization curve.
- Recall/withdrawal risk when utilization spikes.
- Liquidation mechanics on the borrow position.
- Oracle sources and staleness behavior.
- Program IDs, audits, upgrade authority, incident history.

## 6.5 Entry gate

- 24h average funding below a configured negative threshold.
- Projected |funding| − borrow APR − costs positive over the hold horizon,
  with break-even inside the configured maximum, mirroring the existing gate.
- Borrow APR is a live snapshot field; a spike above collected funding is a
  breaker that exits the position, not a value to average away.

## 6.6 Paper gate

- **Duration:** 30 days or 5 negative-funding episodes, whichever first.
- **Go:** positive net carry after modeled borrow cost on ≥60% of
  episode-days; no episode where a modeled borrow-rate spike would have
  produced an unbounded loss.
- **Kill:** borrow costs consume funding on the majority of episodes.

## 6.7 Realistic expectation at $5,000

Regime-dependent, comparable to Phase 1 in magnitude. The value is
availability: Phases 1 + 2 together roughly double deployed-days per year.

---

# 7. Phase 3: JitoSOL NAV Discount Arbitrage

## 7.1 Strategy definition

```text
When jitosol_market_bid < protocol_nav − threshold:
  Buy leg:     +Q JitoSOL at the discount
  Hedge leg:   -(Q × NAV rate) SOL-PERP during the unstake wait
  Exit:        direct unstake at protocol NAV (one epoch ≈ 2 days),
               or instant-unstake route when its fee nets better
  Income:      discount captured per cycle
```

At review time JitoSOL bid sat ~8 bps below NAV. The system already computes
every input: protocol NAV, executable bid, exit depth, epoch state, and the
`direct_unstake_counterfactuals` table *is this trade's ledger*, currently
running as an un-acted-on counterfactual.

## 7.2 Why this is third

- Smallest strategy build on the list: a new opportunity variant wired to
  numbers already in PostgreSQL, hedged by the perp short the paper broker
  already models.
- Nearly risk-free when the gate is honest about costs, and uncorrelated
  with funding regimes — it earns while Phases 1–2 wait.
- Small by nature; treat it as an opportunistic side-book, never the main
  event.

## 7.3 Sources of expected return

```text
Net return per cycle
  = (protocol NAV − executable buy price) × Q
  - unstake fee (direct) or instant-unstake fee
  - hedge entry/exit fees and funding paid/received during the wait
  - chain and execution fees
```

Cycled continuously at an 8 bps discount every 2–3 days this compounds
toward 8–12% APR, *if the discount persists* — which it will not always do.
The gate, not the projection, decides.

## 7.4 Entry gate

- `discount_bps > costs_bps + configured haircut` at the executable bid for
  the full position size, using the existing depth-qualification checks.
- Existing JitoSOL vetoes remain in force: invalid pool ownership, NAV
  mismatch, decreasing unexplained NAV, stale epoch state, insufficient exit
  depth.
- Route selection (epoch unstake vs instant) picks the higher net per cycle.

## 7.5 Paper gate

- **Duration:** 30 days.
- **Go:** ≥5 profitable paper cycles net of modeled fees and hedge costs.
- **Kill:** discount capture consistently consumed by hedge funding costs, or
  fewer than 3 gate openings in the window.

## 7.6 Realistic expectation at $5,000

$300–500/year, low variance.

---

# 8. Phase 4: Cross-Venue Funding Arbitrage

## 8.1 Strategy definition

```text
Same asset A, two qualified perp venues:
  Short leg:  -N A-PERP on venue with high funding
  Long leg:   +N A-PERP on venue with low or negative funding
  Target net:  0 A delta
  Income:      funding spread between venues
```

No spot leg, no staking leg, no borrow leg: roughly 2× the capital
efficiency of cash-and-carry. The venue spread is documented to persist —
Hyperliquid has paid ~5–7% more annualized than Binance on majors,
one-sided ~90% of the time on 90-day rolling windows.

## 8.2 Why this is fourth

Highest engineering cost of the carry family — two execution venues, two
margin accounts, and mark-price basis risk between them. By the time this
phase starts, Phase 1 already collects both funding feeds, so the signal is
free; only execution and margin management are new.

## 8.3 Sources of expected return

```text
Net return
  = realized funding spread (venue_high − venue_low)
  - both venues' entry/exit fees
  + or - mark-divergence P&L between the two venues
  - chain and execution fees
  - recovery losses
```

## 8.4 Scope and risks

- Start with one asset (whichever Phase 1 ranks most persistent) and two
  venues from: Hyperliquid, Drift, Phoenix-when-live.
- Doubled venue risk is the honest price of removing the spot leg: two
  smart-contract surfaces, two liquidation engines, two oracle stacks.
- Margin must be maintained independently on both sides; a liquidation on
  one leg converts the book to naked direction. Breakers treat one-leg
  uncertainty as an emergency flatten of both.

## 8.5 Paper gate

- **Duration:** 30 days papering both legs with *realized* funding prints,
  never predicted rates.
- **Go:** spread net of both venues' fees positive on ≥70% of days; maximum
  drawdown from mark divergence under one week of carry.
- **Kill:** divergence drawdowns repeatedly exceed a week of carry, or the
  spread compresses below round-trip costs when observed at execution size.

## 8.6 Realistic expectation at $5,000

10–20% APY on deployed capital in normal conditions → $500–1,000/year.

---

# 9. Phase 5: Hyperliquid Wallet Tracking

**Implementation status (2026-07-30):** schema 39, runtime wallet-cohort
configuration, configured-wallet indexing, look-ahead-safe scoring,
measured-latency paper modes, shadow Phase 1–4 flow columns, read API, and
console evidence are implemented. The authenticated console replaces the
database cohort atomically and the adapter reloads it without a restart. The
60-day gate has not elapsed and no mode is approved for live capital.

## 9.1 Strategy definition

```text
Data:    any explicitly configured Hyperliquid wallet's live positions,
         leverage, and PnL are queryable through the public info API
Rank:    wallets by risk-adjusted consistency
         (drawdown-adjusted, fee-adjusted — never raw PnL)
Modes:   (a) aggregated smart-money flow as an entry/exit FILTER
             for Phases 1–4
         (b) mirror high-consistency wallets, seconds of latency,
             same venue
         (c) fade consistently losing wallets
```

## 9.2 Why this is fifth, not first

It is the most attractive-looking item and carries the worst honesty
problem on the list. Wallets that look profitable are often snipers or
insiders whose edge dies in the seconds between their fill and yours;
leaderboard survivorship is brutal; by the time a copied entry confirms, the
copier is frequently the exit liquidity. Hyperliquid is chosen precisely
because its full position transparency makes rigorous paper falsification
*possible* — the paper phase exists to kill modes (b) and (c) if they
deserve it, and the expected survivor is mode (a).

## 9.3 Scope

- Wallet indexer over an explicit configured cohort through the public API:
  positions, entries, exits, leverage, and realized PnL per wallet, persisted
  to the evidence store on the existing normalized-event pattern. The API does
  not provide a wallet-enumeration endpoint.
- Consistency scoring with explicit look-ahead protection: scores computed
  only from data available at decision time.
- Paper mirroring engine that models real latency (measured RPC/API
  round-trips, not assumed) and real slippage at copied size.
- Mode (a) delivered as a signal column consumed by Phase 1–4 gates.

## 9.4 Exclusions

- Solana memecoin wallet copy-execution (see §11).
- Any live capital before the extended paper gate passes.
- Copying position *size* — only direction and timing are ever mirrored;
  sizing always comes from this system's own risk limits.

## 9.5 Paper gate

- **Duration:** 60 days minimum — signal decay and regime dependence need
  more evidence than the carry strategies.
- **Go (per mode, independently):** beats holding SOL *and* beats Phase 1 on
  risk-adjusted return, with modeled latency and slippage included, across
  ≥20 mirrored decisions.
- **Kill:** any mode that survives only when latency or slippage assumptions
  are relaxed. Expect most tracked wallets to fail; that is the test
  working.

## 9.6 Realistic expectation at $5,000

Honestly unknown: the only entry with uncapped upside and uncapped downside.
Paper evidence or nothing.

---

# 10. Phase 6: Drift Keeper and Liquidator Bot

## 10.1 Strategy definition

```text
Run permissionless keeper infrastructure on Drift:
  - liquidations of undercollateralized accounts
  - order matching / filler flow where rewarded
Income scales with volatility, uptime, and latency — not bankroll.
```

The only strategy family where $5,000 is not the bottleneck, and the only
one whose income *rises* in bear markets.

## 10.2 Why this is last despite the best capital fit

It shares the least with the existing stack — event-driven, latency-
sensitive, competing against established keepers — and it has real fixed
costs (dedicated RPC, a low-latency host) that the strategies above do not.
It belongs after the carry book runs unattended, as a second, uncorrelated
income line. Start in the lowest-competition niches: deleveraging events and
long-tail markets, not racing incumbents on SOL-PERP liquidations.

## 10.3 Observation-mode gate (this strategy's paper equivalent)

- **Duration:** 30 days in pure observation mode: log every liquidation and
  fill opportunity the bot *would* have won, using honest latency measured
  from this deployment's actual RPC round-trips.
- **Go:** simulated win-rate × fee income ≥ 2× infrastructure cost
  (RPC + host), sustained across the window.
- **Kill:** the 2× bar is not met, or wins concentrate in events the latency
  measurements say this deployment cannot actually reach.

## 10.4 Realistic expectation

From $0 (outcompeted) to well past everything else in this document. The
observation phase is cheap and tells the truth; no capital moves until it
has.

---

# 11. Deliberate Exclusions

Excluded from this roadmap entirely, with reasons:

- **Solana memecoin copy-execution.** Structurally adverse selection: the
  profitable wallets are snipers and insiders whose edge is unmirrorable at
  any retail latency. Aggregated flow as a *signal* is Phase 5 mode (a);
  1:1 copying is not built.
- **Spot triangular / cyclic arbitrage via Jupiter.** A latency race that is
  fully picked over by specialized searchers.
- **Market making with inventory.** A full-time job disguised as a strategy;
  inventory risk plus adverse selection at exactly the moments it hurts.
- **Flash-loan strategies, cross-margin stacking, leverage as yield.**
  Complexity and tail risk misfit for a $5k book and a paper-first doctrine.
- **Any strategy requiring third-party capital or deposits.** Unchanged from
  the parent plan.
- **An LLM deciding whether to trade.** Unchanged from the parent plan.

---

# 12. Shared Infrastructure Reuse

The parent plan's architecture carries over intact. New strategies are new
opportunity variants and adapters, not new systems.

| Component | Reused by |
|---|---|
| Operator console over the strategy catalog (Phase 0) | All phases |
| Fixed-point finance package (`finance.mpl`, checked arithmetic) | All phases |
| Opportunity gate pattern (`opportunity.mpl`, `strategy_core.mpl`) | Phases 1–4 |
| Paper broker and fill model (`broker_paper.mpl`, `paper_engine.mpl`) | Phases 1–5 |
| Normalized-event recorder and evidence trail (PostgreSQL) | All phases |
| `direct_unstake_counterfactuals` machinery | Phase 3 (it is the trade) |
| Risk engine, breakers, fail-closed lifecycles | All phases |
| HMAC-guarded controls, CLI | All phases |
| Deterministic replay and rollback gates | Phases 1–4 (5–6 get replay of recorded feeds) |
| Adapter contract (versioned integer-string envelopes) | New Hyperliquid/Drift/lending adapters conform to it |

New adapter work, in build order:

1. Strategy catalog read endpoint (`/v1/strategies`) — Phase 0.
2. Hyperliquid info-API adapter (keyless, one endpoint) — Phase 1, feeds 2/4/5.
3. Drift data-API funding adapter — Phase 1, feeds 4 and 6.
4. Lending-market adapter (Kamino or marginfi, read-only first) — Phase 2.
5. Hyperliquid wallet indexer — Phase 5.
6. Drift keeper event pipeline — Phase 6.

---

# 13. Phased Implementation Plan

Phase 0 is the first implementation step; strategy phases overlap where the
dependency arrows allow, and paper clocks run concurrently once capture
exists.

```text
Phase 0  Multi-strategy console
         strategy catalog endpoint + registry-driven UI;
         done when a synthetic third strategy renders with zero UI changes
             |
Phase 1  Cross-asset scanner
         capture + ranking first (lands in the Phase 0 leaderboard slot),
         paper trading on top-ranked asset once 7 days of feed are clean
             |
             ├──> Phase 2  Reverse carry      (needs Phase 1 feed + lending adapter)
             ├──> Phase 4  Cross-venue arb    (needs both venue feeds from Phase 1)
             └──> Phase 5  Wallet tracking    (needs Hyperliquid adapter from Phase 1)

Phase 3  NAV discount arb — independent; can start once Phase 0 lands,
         its data pipeline already exists

Phase 6  Keeper bot — independent; starts in observation mode
         whenever Phases 1–3 are running unattended
```

Suggested calendar, assuming part-time effort:

| Window | Work |
|---|---|
| Weeks 1–2 | Phase 0 console generalization; Phase 1 capture + ranking begins behind it |
| Weeks 3–4 | Phase 0 gate closed; Phase 3 gate wiring; Phase 1 feed soaking |
| Weeks 5–8 | Phase 1 and Phase 3 paper runs; build Phase 2 lending adapter |
| Weeks 9–12 | Phase 2 paper (regime permitting); build Phase 4 second-venue execution model |
| Weeks 13–16 | Phase 4 paper; build Phase 5 wallet indexer; Phase 5 60-day paper clock starts |
| Weeks 17+ | First live candidate from whichever of Phases 1–4 passed its gate; Phase 6 observation mode |

No calendar entry authorizes live trading; only §14 does.

---

# 14. Paper and Go-Live Gates

## 14.1 Universal paper requirements (every phase)

- Pinned configuration and build identity before the run starts, exactly as
  the current system enforces (a changed commit or policy cannot attach to
  an existing run).
- Written go/no-go criteria committed to this repository *before* the paper
  clock starts. Criteria are never negotiated during a drawdown.
- Entry gates veto by default; every decision persisted with reason codes.
- Costs modeled adversely: executable prices at size, not mids; realized
  funding prints, not predicted; measured latency, not assumed.
- SOL_CONTROL comparison retained as the standing benchmark.

## 14.2 Universal go-live gates (any phase)

- The phase's paper gate passed as written.
- Shadow-equivalent validation where a construction path exists (unchanged
  from the parent plan's shadow doctrine).
- Venue eligibility and legal access confirmed; no restriction bypass.
- First live notional ≤ $500; one live strategy at a time.
- Kill switches, emergency flatten, and reconciliation proven on the live
  venue with dust-sized test volume before strategy capital moves.
- 30 live days matching paper within written tolerance before any scale-up.

## 14.3 Standing kill criteria (any live strategy)

- Live results diverge from paper beyond tolerance for 7 consecutive days.
- Any unknown-outcome event that reconciliation cannot resolve.
- Venue incident, oracle invalidity, or depth loss tripping existing breakers.
- Drawdown exceeding the written per-strategy limit — archived, not tuned.

---

# 15. Definition of Done

This roadmap is complete when:

1. Phase 0's gate holds: a new strategy registers in the collector and
   renders in the console with zero UI code changes.
2. The current collector runs unmodified as regime monitor and control.
3. Phases 1–4 have each either passed their paper gate and joined the book,
   or been archived with their evidence and a written kill note.
4. The blended paper-plus-live book demonstrates positive net carry in at
   least two distinct funding regimes (positive and negative SOL funding).
5. Phase 5 has delivered a verdict on all three modes from 60 days of
   evidence, with mode (a) either feeding Phases 1–4 gates or archived.
6. Phase 6 observation mode has produced a costed go/no-go decision.
7. Total live capital at risk has never exceeded the envelope, and every
   live deployment traces to a passed gate in this document.

The honest ceiling stands: capital-bounded strategies at $5,000 top out
near $1,000–2,000/year blended. The two paths past that ceiling are Phase 6
(income from service, not capital) and growing the bankroll. Any strategy
claiming to beat that arithmetic should fail its paper gate — and that
gate failing is the system working.

---

# 16. Reference Sources

- Parent plan: `solana_delta_neutral_funding_collector_plan.md` (2026-07-25)
- Console under review: `ui/src/App.tsx`, `ui/src/api.ts`,
  `ui/src/sections/`, localhost HMAC proxy in `ui/operator.ts`
- Review evidence: live collector read API (`/v1/opportunities`, `/v1/status`,
  `/v1/pnl`), `opportunity_decisions` table (current run and July 27 soak
  backup `pre-f303667-20260727-funding.dump`)
- Live funding cross-check: Hyperliquid public info API
  (`https://api.hyperliquid.xyz/info`, `metaAndAssetCtxs`), queried 2026-07-30
- Venue spread persistence: BitMEX Q2 2026 Derivatives Report
  (`https://www.bitmex.com/blog/2026q2-derivatives-report`)
- Phoenix venue status: `docs/venue-qualification-paper.md`
- Drift status and reboot notice: `docs/venue-qualification-paper.md` (Drift
  withdrawal, 2026-07-25); re-qualify before Phase 4, 6, or any Drift leg
- Funding data aggregation: CoinGlass (`https://www.coinglass.com/FundingRate/SOL`)
