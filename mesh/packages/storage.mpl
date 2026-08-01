from Packages.Accounting import realized_funding_usd
from Packages.Finance import Lamports
from Packages.ProtocolContracts import FundingObservation, FundingSettlement, MarketSnapshot

fn bool_string(value :: Bool) -> String do
  if value do
    "true"
  else
    "false"
  end
end



fn required_int(value :: String, field :: String) -> Int ! String do
  case String.to_int(value) do
    Some(parsed) -> Ok(parsed)
    None -> Err("database returned invalid ${field}")
  end
end


pub struct FundingPersistence do
  inserted_event :: Bool
  payments :: Int
  counterfactual_payments :: Int
end

pub struct FundingObservationPersistence do
  inserted :: Bool
  scan_complete :: Bool
end
















pub fn persist_market_snapshot(pool :: PoolHandle, body :: String, snapshot :: MarketSnapshot) -> Int ! String do
  let rows = Pool.query(pool, "WITH source_event AS (INSERT INTO normalized_events (id, schema_version, event_type, source, observed_at_ms, source_slot, source_sequence, idempotency_key, raw_payload_hash, canonical_payload) VALUES ($1, 1, 'MarketSnapshot', $2, $3::bigint, $4::bigint, $5, $6, $7, $8::jsonb) ON CONFLICT (idempotency_key) DO NOTHING RETURNING id, raw_payload_hash, canonical_payload), recorded_event AS (SELECT id, raw_payload_hash, canonical_payload FROM source_event UNION ALL SELECT id, raw_payload_hash, canonical_payload FROM normalized_events WHERE idempotency_key = $6) SELECT (SELECT count(*)::text FROM source_event) AS inserted, COALESCE((SELECT bool_and(id = $1 AND raw_payload_hash = $7 AND canonical_payload = $8::jsonb)::text FROM recorded_event), 'false') AS event_matches", [
    snapshot.event_id,
    snapshot.source,
    "${snapshot.observed_at_ms}",
    "${snapshot.source_slot}",
    snapshot.source_sequence,
    snapshot.idempotency_key,
    snapshot.raw_payload_hash,
    body
  ]) ?
  if List.length(rows) == 0 do
    Ok(0)
  else
    if Map.get(List.head(rows), "event_matches") != "true" do
      return Err("idempotency key reused for a different event")
    end
    case String.to_int(Map.get(List.head(rows), "inserted")) do
      Some(count) -> Ok(count)
      None -> Err("database returned invalid insert count")
    end
  end
end

fn direct_unstake_funding_payments(
  rows,
  event :: FundingSettlement,
  index :: Int,
  payments :: List<String>
) -> List<String> ! String do
  if index >= List.length(rows) do
    Ok(payments)
  else
    let row = List.get(rows, index)
    let quantity = Lamports {
      atoms : required_int(
        Map.get(row, "hedge_quantity_atoms"),
        "direct unstake hedge quantity"
      ) ?
    }
    let amount = (quantity
      |> realized_funding_usd(
        event.sol_price_usd_micros,
        event.realized_short_rate_ppm
      )) ?
    direct_unstake_funding_payments(
      rows,
      event,
      index + 1,
      List.append(payments, json {
        counterfactualId : Map.get(row, "id"),
        positionQuantityAtoms : "${quantity.atoms}",
        amountUsdMicros : "${amount.atoms}"
      })
    )
  end
end

pub fn load_direct_unstake_funding_payments(
  pool :: PoolHandle,
  event :: FundingSettlement
) -> List<String> ! String do
  (Pool.query(pool, "SELECT id, hedge_quantity_atoms FROM direct_unstake_counterfactuals WHERE state NOT IN ('withdrawn', 'failed') ORDER BY id", []) ?
    |> direct_unstake_funding_payments(event, 0, List.new()))
end

pub fn advance_direct_unstakes(
  pool :: PoolHandle,
  source_event_id :: String,
  epoch :: Int,
  outcome :: String
) -> Int ! String do
  let rows = Pool.query(pool, "SELECT advance_direct_unstake_counterfactuals($1, $2::bigint, $3)::text AS applied", [
    source_event_id,
    "${epoch}",
    outcome
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned invalid direct unstake advancement")
  else
    required_int(
      Map.get(List.head(rows), "applied"),
      "direct unstake advancement"
    )
  end
end

pub fn persist_funding_settlement(
  pool :: PoolHandle,
  body :: String,
  payments :: List<String>,
  counterfactual_payments :: List<String>
) -> FundingPersistence ! String do
  let rows = Pool.query(pool, "WITH applied AS (SELECT apply_funding_settlements($1::jsonb, $2::jsonb, $3::jsonb) AS result) SELECT result->>'insertedEvent' AS inserted_event, result->>'payments' AS payments, result->>'counterfactualPayments' AS counterfactual_payments FROM applied", [
    body,
    "[${String.join(payments, ",")}]",
    "[${String.join(counterfactual_payments, ",")}]"
  ]) ?
  if List.length(rows) != 1 do
    return Err("database returned invalid funding settlement result")
  end
  let row = List.head(rows)
  Ok(FundingPersistence {
    inserted_event : Map.get(row, "inserted_event") == "true",
    payments : required_int(Map.get(row, "payments"), "funding payment count") ?,
    counterfactual_payments : required_int(
      Map.get(row, "counterfactual_payments"),
      "direct unstake funding payment count"
    ) ?
  })
end

pub fn persist_funding_observation(
  pool :: PoolHandle,
  event :: FundingObservation,
  source_max_age_ms :: Int,
  borrow_source_max_age_ms :: Int
) -> FundingObservationPersistence ! String do
  let rows = Pool.query(
    pool,
    "WITH applied AS (SELECT record_funding_observation($1::jsonb, $2::bigint) AS result), borrow AS (SELECT record_borrow_snapshot($1::jsonb, $3::bigint) AS recorded FROM applied) SELECT result->>'inserted' AS inserted, result->>'scanComplete' AS scan_complete, recorded::text FROM applied CROSS JOIN borrow",
    [event.body, "${source_max_age_ms}", "${borrow_source_max_age_ms}"]
  ) ?
  if List.length(rows) != 1 do
    return Err("database returned invalid funding observation result")
  end
  let row = List.head(rows)
  Ok(FundingObservationPersistence {
    inserted : Map.get(row, "inserted") == "true",
    scan_complete : Map.get(row, "scan_complete") == "true"
  })
end


pub fn run_reverse_carry_paper_scan(
  pool :: PoolHandle,
  scan_id :: String,
  now_ms :: Int,
  funding_source_max_age_ms :: Int,
  borrow_source_max_age_ms :: Int,
  notional_usd_micros :: Int,
  costs_usd_micros :: Int,
  risk_usd_micros :: Int,
  hold_hours :: Int,
  maximum_break_even_hours :: Int,
  minimum_negative_funding_ppm :: Int,
  maximum_borrow_utilization_ppm :: Int
) -> String ! String do
  let rows = Pool.query(
    pool,
    "SELECT run_reverse_carry_paper_scan($1, $2::bigint, $3::bigint, $4::bigint, $5::bigint, $6::bigint, $7::bigint, $8::int, $9::int, $10::bigint, $11::bigint)::text AS body",
    [
      scan_id,
      "${now_ms}",
      "${funding_source_max_age_ms}",
      "${borrow_source_max_age_ms}",
      "${notional_usd_micros}",
      "${costs_usd_micros}",
      "${risk_usd_micros}",
      "${hold_hours}",
      "${maximum_break_even_hours}",
      "${minimum_negative_funding_ppm}",
      "${maximum_borrow_utilization_ppm}"
    ]
  ) ?
  if List.length(rows) != 1 do
    Err("database returned invalid reverse-carry paper result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

pub fn run_nav_discount_paper_cycle(
  pool :: PoolHandle,
  source_event_id :: String,
  now_ms :: Int,
  source_max_age_ms :: Int,
  minimum_margin_ratio_ppm :: Int,
  minimum_liquidation_distance_bps :: Int,
  direct_unstake_fee_ppm :: Int,
  direct_chain_fees_usd_micros :: Int,
  direct_hedge_cost_usd_micros :: Int,
  direct_capital_delay_haircut_usd_micros :: Int,
  direct_final_hedge_close_cost_usd_micros :: Int,
  hold_hours :: Int
) -> String ! String do
  let rows = Pool.query(
    pool,
    "SELECT run_nav_discount_paper_cycle($1, $2::bigint, $3::bigint, $4::bigint, $5::bigint, $6::bigint, $7::bigint, $8::bigint, $9::bigint, $10::bigint, $11::int)::text AS body",
    [
      source_event_id,
      "${now_ms}",
      "${source_max_age_ms}",
      "${minimum_margin_ratio_ppm}",
      "${minimum_liquidation_distance_bps}",
      "${direct_unstake_fee_ppm}",
      "${direct_chain_fees_usd_micros}",
      "${direct_hedge_cost_usd_micros}",
      "${direct_capital_delay_haircut_usd_micros}",
      "${direct_final_hedge_close_cost_usd_micros}",
      "${hold_hours}"
    ]
  ) ?
  if List.length(rows) != 1 do
    Err("database returned invalid NAV-discount paper result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

pub fn run_cross_asset_paper_scan(
  pool :: PoolHandle,
  scan_id :: String,
  now_ms :: Int,
  source_max_age_ms :: Int,
  notional_usd_micros :: Int,
  costs_usd_micros :: Int,
  risk_usd_micros :: Int,
  hold_hours :: Int
) -> String ! String do
  let rows = Pool.query(
    pool,
    "SELECT run_cross_asset_paper_scan($1, $2::bigint, $3::bigint, $4::bigint, $5::bigint, $6::bigint, $7::int)::text AS body",
    [
      scan_id,
      "${now_ms}",
      "${source_max_age_ms}",
      "${notional_usd_micros}",
      "${costs_usd_micros}",
      "${risk_usd_micros}",
      "${hold_hours}"
    ]
  ) ?
  if List.length(rows) != 1 do
    Err("database returned invalid cross-asset paper result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end


pub fn persist_operator_command(
  pool :: PoolHandle,
  action :: String,
  target :: String,
  idempotency_key :: String,
  reason :: String,
  request_hash :: String
) -> String ! String do
  let rows = Pool.query(pool, "SELECT apply_reconciled_operator_command($1, $2, $3, $4, $5)::text AS body", [
    action,
    target,
    idempotency_key,
    reason,
    request_hash
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid operator command result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

pub fn persist_strategy_control(
  pool :: PoolHandle,
  strategy :: String,
  enabled :: Bool,
  idempotency_key :: String,
  reason :: String,
  request_hash :: String
) -> String ! String do
  let rows = Pool.query(pool, "SELECT apply_strategy_control($1, $2::boolean, $3, $4, $5)::text AS body", [
    strategy,
    bool_string(enabled),
    idempotency_key,
    reason,
    request_hash
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid strategy control result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end


pub fn persist_paper_reset(
  pool :: PoolHandle,
  initial_usdc_micros :: Int,
  initial_collateral_usd_micros :: Int,
  approval_expires_at_ms :: Int,
  idempotency_key :: String,
  reason :: String,
  request_hash :: String
) -> String ! String do
  let rows = ("SELECT apply_paper_reset($1::bigint, $2::bigint, $3::bigint, $4, $5, $6)::text AS body"
    |2> Pool.query(pool, [
      "${initial_usdc_micros}",
      "${initial_collateral_usd_micros}",
      "${approval_expires_at_ms}",
      idempotency_key,
      reason,
      request_hash
    ])) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid paper reset result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

pub fn reconcile_paper_state(
  pool :: PoolHandle,
  reconciliation_id :: String,
  reason :: String
) -> String ! String do
  let rows = ("SELECT record_paper_reconciliation($1, $2)->>'result' AS result"
    |2> Pool.query(pool, [reconciliation_id, reason])) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid paper reconciliation result")
  else
    Ok(Map.get(List.head(rows), "result"))
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
  let rows = Pool.query(pool, "WITH items AS (SELECT d.id, d.source_event_id, 'cross_asset_funding' AS variant, n.observed_at_ms, '0' AS nav_lamports, '0' AS hedge_lamports, d.expected_funding_usd_micros::text AS expected_funding_usd_micros, '0' AS nav_reward_usd_micros, d.net_carry_usd_micros::text AS net_carry_usd_micros, d.eligible, d.reason_code FROM cross_asset_paper_decisions d JOIN normalized_events n ON n.id = d.source_event_id UNION ALL SELECT d.id, d.source_event_id, 'negative_funding_reverse', n.observed_at_ms, '0', '0', d.expected_funding_usd_micros::text, '0', d.net_carry_usd_micros::text, d.eligible, d.reason_code FROM reverse_carry_paper_decisions d JOIN normalized_events n ON n.id = d.source_event_id UNION ALL SELECT d.id, d.source_event_id, 'jitosol_nav_discount', n.observed_at_ms, d.protocol_nav_lamports::text, d.hedge_lamports::text, d.expected_funding_usd_micros::text, '0', d.net_carry_usd_micros::text, d.eligible, d.reason_code FROM nav_discount_paper_decisions d JOIN normalized_events n ON n.id = d.source_event_id), ranked AS (SELECT *, row_number() OVER (PARTITION BY variant ORDER BY observed_at_ms DESC, id) AS strategy_rank FROM items) SELECT id, source_event_id, variant, observed_at_ms::text, nav_lamports, hedge_lamports, expected_funding_usd_micros, nav_reward_usd_micros, net_carry_usd_micros, eligible::text, reason_code FROM ranked WHERE strategy_rank <= 20 ORDER BY observed_at_ms DESC, variant", []) ?
  Ok(rows |> rows_to_json(0, List.new()))
end

pub fn release_identity_matches(
  recorded_code_commit :: String,
  recorded_mesh_commit :: String,
  recorded_config_hash :: String,
  code_commit :: String,
  mesh_commit :: String,
  config_hash :: String
) -> Bool do
  recorded_code_commit == code_commit && recorded_mesh_commit == mesh_commit && recorded_config_hash == config_hash
end

pub fn bootstrap_paper_runs(pool :: PoolHandle, code_commit :: String, mesh_commit :: String, config_hash :: String, target_notional :: Int) -> Int ! String do
  let existing = Pool.query(pool, "SELECT run.config_hash, build.code_commit, build.mesh_commit FROM strategy_runs run JOIN build_manifests build ON build.id = run.build_manifest_id WHERE run.id = 'local-paper-run'", []) ?
  if List.length(existing) > 1 do
    return Err("database returned an invalid paper strategy identity")
  end
  if List.length(existing) == 1 do
    let identity = List.head(existing)
    if Map.get(identity, "config_hash") != config_hash do
      return Err("running paper strategy config does not match runtime fingerprint")
    end
    if (Map.get(identity, "code_commit")
      |> release_identity_matches(
        Map.get(identity, "mesh_commit"),
        Map.get(identity, "config_hash"),
        code_commit,
        mesh_commit,
        config_hash
      )) == false do
      return Err("running paper strategy build does not match pinned release")
    end
  end
  let applied = ("WITH build AS (INSERT INTO build_manifests (id, code_commit, mesh_commit, schema_version, config_hash) VALUES ('local-paper-build', $1, $2, 54, $3) ON CONFLICT (id) DO UPDATE SET code_commit = EXCLUDED.code_commit, mesh_commit = EXCLUDED.mesh_commit, schema_version = EXCLUDED.schema_version, config_hash = EXCLUDED.config_hash RETURNING id), run AS (INSERT INTO strategy_runs (id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version) SELECT 'local-paper-run', 'paper', $3, id, 42, 'xorshift64star-v1' FROM build ON CONFLICT (id) DO UPDATE SET config_hash = EXCLUDED.config_hash, build_manifest_id = EXCLUDED.build_manifest_id WHERE strategy_runs.config_hash = repeat('0', 64) RETURNING id), comparison AS (INSERT INTO comparison_groups (id, strategy_run_id, mode, target_notional_usd_micros, entry_policy_version, exit_policy_version) VALUES ('local-paper-run:independent', 'local-paper-run', 'independent', $4, 'paper-entry-v1', 'paper-exit-v1') ON CONFLICT (id) DO UPDATE SET mode = EXCLUDED.mode, target_notional_usd_micros = EXCLUDED.target_notional_usd_micros, entry_policy_version = EXCLUDED.entry_policy_version, exit_policy_version = EXCLUDED.exit_policy_version RETURNING id), portfolios AS (INSERT INTO portfolio_runs (id, strategy_run_id, comparison_group_id, variant, execution_mode, initial_capital_usd_micros) VALUES ('local-cross-asset-funding', 'local-paper-run', 'local-paper-run:independent', 'cross_asset_funding', 'paper', 1000000000), ('local-negative-funding-reverse', 'local-paper-run', 'local-paper-run:independent', 'negative_funding_reverse', 'paper', 1000000000), ('local-jitosol-nav-discount', 'local-paper-run', 'local-paper-run:independent', 'jitosol_nav_discount', 'paper', 1000000000) ON CONFLICT (id) DO UPDATE SET comparison_group_id = EXCLUDED.comparison_group_id RETURNING id), batches AS (INSERT INTO ledger_batches (id, portfolio_run_id, event_type, event_id, batch_hash) SELECT id || ':opening', id, 'opening_capital', id || ':opening', repeat('0', 64) FROM portfolios ON CONFLICT (id) DO NOTHING RETURNING id, portfolio_run_id) INSERT INTO ledger_entries (ledger_batch_id, account_debit, account_credit, asset, amount_atoms, usd_value_atoms) SELECT id, 'paper_cash', 'paper_equity', 'USDC', '1000000000', '1000000000' FROM batches" |2> Pool.execute(pool, [code_commit, mesh_commit, config_hash, "${target_notional}"])) ?
  ("UPDATE strategy_controls SET enabled = false, version = version + 1, updated_at = now() WHERE enabled" |2> Pool.execute(pool, [])) ?
  let capability_rows = ("SELECT record_language_capability_results($1)::text AS count" |2> Pool.query(pool, ["local-paper-build"])) ?
  if List.length(capability_rows) != 1 || Map.get(List.head(capability_rows), "count") != "23" do
    return Err("database returned an invalid language capability result")
  end
  Ok(applied)
end
