# Failure operations

Paper and shadow cannot sign or submit. Keep execution paused whenever a row
below is active; never move a key or mutation credential into Mesh to work
around an outage.

| Failure | Detection | Automatic action | Operator action | Resume gate |
|---|---|---|---|---|
| Primary RPC/adapter source | health, sequence, or slot continuity fails | pause entries; use only an approved backup | inspect source status and resnapshot | stable source and reconciled orders/positions |
| All market sources | every authoritative read is stale/unavailable | pause entries and rebalances | use an independent account view; close manually if qualified and required | authoritative margin/position and market data restored |
| Adapter schema/build | capability or schema mismatch | reject event; retain stale last value | deploy compatible pinned images | capability, conformance, and replay gates pass |
| Adapter sequence gap | non-contiguous source sequence | reject incrementals and pause entries | request a full resnapshot | coherent snapshot plus reconciliation |
| Replaceable mailbox overflow | dropped count/depth alert | coalesce latest snapshot; mark source degraded | reduce source rate | depth below threshold and fresh snapshot |
| Critical mailbox rejection | rejected control/accounting item | fail closed and pause all | preserve evidence; restart collector | durable state loaded and reconciliation matched |
| Actor crash/restart storm | structured crash/restart-limit event | pause execution; bounded supervisor restart | inspect the permanent regression and roll back if needed | restart probe, replay, and reconciliation pass |
| Database unavailable | persistence/query failure | stop decisions and intents | restore PostgreSQL; do not dispatch normal actions | restore drill and reconciliation pass |
| Spot acquired, perp failed | partial/rejected second leg | enter emergency recovery timer | confirm quantities; short within bounds or sell excess spot | flat or confirmed hedged; incident reviewed |
| Perp outcome unknown | timeout without authoritative outcome | do not retry | query command/client ID, position, orders, and deltas | outcome classified and recorded |
| JitoSOL NAV anomaly | owner/supply/pool/epoch inconsistency | invalidate JitoSOL and pause its actions | cross-check independent RPC and deployment status | accounts and executable rate agree |
| JitoSOL depth collapse | quote ladder breaches size/discount limit | pause entries; prefer risk reduction | use instant exit only within bounds; otherwise follow delayed-unstake procedure | qualified depth and margin restored |
| Funding negative | realized/forecast carry breaches policy | hold/exit according to persisted thresholds | review sunk costs and basis/margin risk | economics and risk return inside policy |
| Margin warning/critical | venue margin or liquidation-distance threshold | warning pauses entries; critical closes perp reduce-only before spot | confirm the venue position and matching spot quantity | authoritative quantities and margin reconciled |
| Reconciliation mismatch | persisted and derived state differ | pause all; append evidence | classify delay, missed fill, or balance mismatch; never rewrite history | explicit adjustment, if needed, is reviewed and reconciliation matches |
| Executor/signer unavailable | executor health/command lookup fails | pause entries | use only the qualified manual venue/wallet process | isolated executor restored and command state reconciled |
| Compiler/runtime regression | conformance, replay, or runtime probe fails | freeze toolchain promotion | roll back immutable compiler and collector images | native probes, collector tests, replay, and reconciliation pass |
| Emergency flatten partial | confirmed residual exposure remains | stop normal strategy work | reduce liquidation risk and largest delta first using authoritative quantities | flat, reconciled, alerted incident reviewed |

## Manual delayed unstake and hedge

1. Pause JitoSOL entries and automatic rebalancing.
2. Record JitoSOL atoms, protocol exchange rate, epoch, short quantity, margin,
   and the direct-unstake scenario before acting.
3. Keep or resize the short only from confirmed JitoSOL-equivalent exposure;
   the unstake claim is delayed capital, not available collateral.
4. Submit the qualified direct-unstake operation outside Mesh, record its
   signature/claim/epoch, and continue funding and margin monitoring.
5. At claim completion, verify received SOL, close only the matching short
   reduce-only, and record fees, funding, delay haircut, and final close cost.
6. Resume only after wallet, venue, database, and ledger reconciliation.

This procedure is not live-qualified until current Jito program accounts,
unstake rules, wallet tooling, and operator eligibility have authoritative
evidence.

## Manual venue close

Use the venue’s qualified private operator interface, never a new Mesh endpoint:
pause automation, capture position/open orders, cancel entry orders, close the
perp reduce-only, confirm zero short, then sell only the matching spot amount.
Persist command IDs and evidence and reconcile before resuming. Exact buttons,
hosts, account IDs, and support escalation remain blocked on Phoenix
private-beta access, operator eligibility, account qualification, and a
credentialed drill.

## Local drills

Run from the repository:

```sh
scripts/check-recovery.sh
scripts/check-shutdown.sh
scripts/check-shadow-persistence.sh
scripts/check-operator-api.sh
scripts/check-observability.sh
```

The recovery check first proves SIGTERM drains accepted requests, releases the
fenced writer lease, and exits cleanly. It then verifies startup reconciliation
and the persisted schema manifest, restores a Docker PostgreSQL backup into
isolated temporary storage, and reconciles the restored copy. External-source,
venue, signer, operator alert-delivery, and live-response drills remain release
gates.
