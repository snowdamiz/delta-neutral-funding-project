pub struct MarketSnapshot do
  event_id :: String
  observed_at_ms :: Int
  source_sequence :: String
  idempotency_key :: String
  raw_payload_hash :: String
  total_pool_lamports :: Int
  supply_atoms :: Int
  jitosol_atoms :: Int
  notional_usd_micros :: Int
  short_receipt_ppm :: Int
  sol_price_usd_micros :: Int
  prior_nav_lamports :: Int
  costs_usd_micros :: Int
  risk_haircut_usd_micros :: Int
end deriving(Json)

fn required_int(raw :: String, field :: String, allow_negative :: Bool) -> Int ! String do
  case String.to_int(raw) do
    Some(value) -> do
      if value < 0 do
        if allow_negative do
          Ok(value)
        else
          Err("${field} must be unsigned")
        end
      else
        Ok(value)
      end
    end
    None -> Err("${field} must be a base-10 integer string")
  end
end

fn required_string(value :: String, field :: String) -> String ! String do
  if String.length(value) == 0 do
    Err("missing ${field}")
  else
    Ok(value)
  end
end

pub fn parse_market_snapshot(body :: String) -> MarketSnapshot ! String do
  let _parsed = Json.parse(body) ?
  let schema_version = required_int(Json.get(body, "schemaVersion"), "schemaVersion", false) ?
  if schema_version != 1 do
    Err("unsupported schema version")
  else
    let event_type = required_string(Json.get(body, "eventType"), "eventType") ?
    if event_type != "MarketSnapshot" do
      Err("unsupported event type")
    else
      Ok(MarketSnapshot {
        event_id : required_string(Json.get(body, "eventId"), "eventId") ?,
        observed_at_ms : required_int(Json.get(body, "observedAtMs"), "observedAtMs", false) ?,
        source_sequence : required_string(Json.get(body, "sourceSequence"), "sourceSequence") ?,
        idempotency_key : required_string(Json.get(body, "idempotencyKey"), "idempotencyKey") ?,
        raw_payload_hash : required_string(Json.get(body, "rawPayloadHash"), "rawPayloadHash") ?,
        total_pool_lamports : required_int(Json.get_nested(body, "payload", "totalPoolLamports"), "totalPoolLamports", false) ?,
        supply_atoms : required_int(Json.get_nested(body, "payload", "supplyAtoms"), "supplyAtoms", false) ?,
        jitosol_atoms : required_int(Json.get_nested(body, "payload", "jitosolAtoms"), "jitosolAtoms", false) ?,
        notional_usd_micros : required_int(Json.get_nested(body, "payload", "notionalUsdMicros"), "notionalUsdMicros", false) ?,
        short_receipt_ppm : required_int(Json.get_nested(body, "payload", "shortReceiptPpm"), "shortReceiptPpm", true) ?,
        sol_price_usd_micros : required_int(Json.get_nested(body, "payload", "solPriceUsdMicros"), "solPriceUsdMicros", false) ?,
        prior_nav_lamports : required_int(Json.get_nested(body, "payload", "priorNavLamports"), "priorNavLamports", false) ?,
        costs_usd_micros : required_int(Json.get_nested(body, "payload", "costsUsdMicros"), "costsUsdMicros", false) ?,
        risk_haircut_usd_micros : required_int(Json.get_nested(body, "payload", "riskHaircutUsdMicros"), "riskHaircutUsdMicros", false) ?
      })
    end
  end
end
