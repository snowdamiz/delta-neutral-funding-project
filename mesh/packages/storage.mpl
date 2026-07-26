from Packages.Opportunity import OpportunitySet
from Packages.ProtocolContracts import MarketSnapshot

fn bool_string(value :: Bool) -> String do
  if value do
    "true"
  else
    "false"
  end
end

fn reason(eligible :: Bool) -> String do
  if eligible do
    "positive_net_carry"
  else
    "entry_gate_failed"
  end
end

pub fn persist_opportunities(pool :: PoolHandle, body :: String, snapshot :: MarketSnapshot, result :: OpportunitySet, config_hash :: String) -> Int ! String do
  let sql = "WITH source_event AS (INSERT INTO normalized_events (id, schema_version, event_type, source, observed_at_ms, source_sequence, idempotency_key, raw_payload_hash, canonical_payload) VALUES ($1, 1, 'MarketSnapshot', 'protocol-adapter', $2::bigint, $3, $4, $5, $6::jsonb) ON CONFLICT (idempotency_key) DO NOTHING RETURNING id), decisions AS (INSERT INTO opportunity_decisions (id, source_event_id, variant, observed_at_ms, nav_lamports, hedge_lamports, expected_funding_usd_micros, nav_reward_usd_micros, net_carry_usd_micros, eligible, reason_code, config_hash) SELECT $1 || ':sol', id, 'sol_control', $2::bigint, $7, $8, $9, '0', $10, $11::boolean, $12, $17 FROM source_event UNION ALL SELECT $1 || ':jitosol', id, 'jitosol_carry', $2::bigint, $7, $8, $9, $13, $14, $15::boolean, $16, $17 FROM source_event RETURNING id) SELECT count(*)::text AS inserted FROM decisions"
  let rows = Pool.query(pool, sql, [
    snapshot.event_id,
    "${snapshot.observed_at_ms}",
    snapshot.source_sequence,
    snapshot.idempotency_key,
    snapshot.raw_payload_hash,
    body,
    "${result.nav_lamports}",
    "${result.hedge_lamports}",
    "${result.expected_funding_usd_micros}",
    "${result.sol_net_carry_usd_micros}",
    bool_string(result.sol_eligible),
    reason(result.sol_eligible),
    "${result.nav_reward_usd_micros}",
    "${result.jitosol_net_carry_usd_micros}",
    bool_string(result.jitosol_eligible),
    reason(result.jitosol_eligible),
    config_hash
  ]) ?
  if List.length(rows) == 0 do
    Ok(0)
  else
    case String.to_int(Map.get(List.head(rows), "inserted")) do
      Some(count) -> Ok(count)
      None -> Err("database returned invalid insert count")
    end
  end
end

fn rows_to_json(rows, index :: Int, acc :: List<String>) -> String do
  if index >= List.length(rows) do
    "[${String.join(acc, ",")}]"
  else
    let row = List.get(rows, index)
    let encoded = json {
      id : Map.get(row, "id"),
      sourceEventId : Map.get(row, "source_event_id"),
      variant : Map.get(row, "variant"),
      observedAtMs : Map.get(row, "observed_at_ms"),
      navLamports : Map.get(row, "nav_lamports"),
      hedgeLamports : Map.get(row, "hedge_lamports"),
      expectedFundingUsdMicros : Map.get(row, "expected_funding_usd_micros"),
      navRewardUsdMicros : Map.get(row, "nav_reward_usd_micros"),
      netCarryUsdMicros : Map.get(row, "net_carry_usd_micros"),
      eligible : Map.get(row, "eligible") == "true",
      reasonCode : Map.get(row, "reason_code")
    }
    rows_to_json(rows, index + 1, List.append(acc, encoded))
  end
end

pub fn list_opportunities(pool :: PoolHandle) -> String ! String do
  let rows = Pool.query(pool, "SELECT id, source_event_id, variant::text, observed_at_ms::text, nav_lamports, hedge_lamports, expected_funding_usd_micros, nav_reward_usd_micros, net_carry_usd_micros, eligible::text, reason_code FROM opportunity_decisions ORDER BY observed_at_ms DESC, variant LIMIT 100", []) ?
  Ok(rows_to_json(rows, 0, List.new()))
end

pub fn bootstrap_paper_runs(pool :: PoolHandle, code_commit :: String, mesh_commit :: String, config_hash :: String) -> Int ! String do
  let sql = "WITH build AS (INSERT INTO build_manifests (id, code_commit, mesh_commit, schema_version, config_hash) VALUES ('local-paper-build', $1, $2, 1, $3) ON CONFLICT (id) DO UPDATE SET code_commit = EXCLUDED.code_commit, mesh_commit = EXCLUDED.mesh_commit, config_hash = EXCLUDED.config_hash RETURNING id), run AS (INSERT INTO strategy_runs (id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version) SELECT 'local-paper-run', 'paper', $3, id, 42, 'xorshift64star-v1' FROM build ON CONFLICT (id) DO NOTHING RETURNING id), portfolios AS (INSERT INTO portfolio_runs (id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros) VALUES ('local-sol-control', 'local-paper-run', 'sol_control', 'paper', 1000000000), ('local-jitosol-carry', 'local-paper-run', 'jitosol_carry', 'paper', 1000000000) ON CONFLICT (id) DO NOTHING RETURNING id), batches AS (INSERT INTO ledger_batches (id, portfolio_run_id, event_type, event_id, batch_hash) SELECT id || ':opening', id, 'opening_capital', id || ':opening', repeat('0', 64) FROM portfolios RETURNING id, portfolio_run_id) INSERT INTO ledger_entries (ledger_batch_id, account_debit, account_credit, asset, amount_atoms, usd_value_atoms) SELECT id, 'paper_cash', 'paper_equity', 'USDC', '1000000000', '1000000000' FROM batches"
  Pool.execute(pool, sql, [code_commit, mesh_commit, config_hash])
end
