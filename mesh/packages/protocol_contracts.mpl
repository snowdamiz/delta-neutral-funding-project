from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros

pub struct MarketSnapshot do
  event_id :: String
  source :: String
  observed_at_ms :: Int
  source_sequence :: String
  idempotency_key :: String
  raw_payload_hash :: String
  total_pool_lamports :: Lamports
  supply_atoms :: TokenAtoms
  jitosol_atoms :: TokenAtoms
  notional_usd_micros :: UsdMicros
  short_receipt_ppm :: RatePpm
  sol_price_usd_micros :: UsdMicros
  prior_nav_lamports :: Lamports
  costs_usd_micros :: UsdMicros
  risk_haircut_usd_micros :: UsdMicros
end deriving(Json)

fn required_int(raw :: String, field :: String, allow_negative :: Bool) -> Int ! String do
  let canonical = if allow_negative do
    Regex.is_match(~r/^-?(0|[1-9][0-9]*)$/, raw)
  else
    Regex.is_match(~r/^(0|[1-9][0-9]*)$/, raw)
  end
  if canonical == false do
    Err("${field} must be a canonical base-10 integer string")
  else
    case String.to_int(raw) do
      Some(value) -> Ok(value)
      None -> Err("${field} is outside the supported integer range")
    end
  end
end

fn required_string(body :: String, key :: String, field :: String) -> String ! String do
  if Json.is_string(body, key) == false do
    return Err("${field} must be a JSON string")
  end
  let value = body |> Json.get(key)
  if String.length(value) == 0 do
    Err("missing ${field}")
  else
    Ok(value)
  end
end

fn required_int_field(body :: String, key :: String, field :: String, allow_negative :: Bool) -> Int ! String do
  let value = (body |> required_string(key, field)) ?
  value |> required_int(field, allow_negative)
end

fn required_hash(body :: String) -> String ! String do
  let value = (body |> required_string("rawPayloadHash", "rawPayloadHash")) ?
  if Regex.is_match(~r/^[0-9a-f]{64}$/, value) do
    Ok(value)
  else
    Err("rawPayloadHash must be lowercase SHA-256 hex")
  end
end

pub fn parse_market_snapshot(body :: String) -> MarketSnapshot ! String do
  let _parsed = Json.parse(body) ?
  let schema_version = required_int(Json.get(body, "schemaVersion"), "schemaVersion", false) ?
  if schema_version != 1 do
    Err("unsupported schema version")
  else
    let event_type = (body |> required_string("eventType", "eventType")) ?
    if event_type != "MarketSnapshot" do
      Err("unsupported event type")
    else
      let payload = body |> Json.get("payload")
      Ok(MarketSnapshot {
        event_id : (body |> required_string("eventId", "eventId")) ?,
        source : (body |> required_string("source", "source")) ?,
        observed_at_ms : (body |> required_int_field("observedAtMs", "observedAtMs", false)) ?,
        source_sequence : (body |> required_string("sourceSequence", "sourceSequence")) ?,
        idempotency_key : (body |> required_string("idempotencyKey", "idempotencyKey")) ?,
        raw_payload_hash : required_hash(body) ?,
        total_pool_lamports : Lamports { atoms : (payload |> required_int_field("totalPoolLamports", "totalPoolLamports", false)) ? },
        supply_atoms : TokenAtoms { atoms : (payload |> required_int_field("supplyAtoms", "supplyAtoms", false)) ? },
        jitosol_atoms : TokenAtoms { atoms : (payload |> required_int_field("jitosolAtoms", "jitosolAtoms", false)) ? },
        notional_usd_micros : UsdMicros { atoms : (payload |> required_int_field("notionalUsdMicros", "notionalUsdMicros", false)) ? },
        short_receipt_ppm : RatePpm { atoms : (payload |> required_int_field("shortReceiptPpm", "shortReceiptPpm", true)) ? },
        sol_price_usd_micros : UsdMicros { atoms : (payload |> required_int_field("solPriceUsdMicros", "solPriceUsdMicros", false)) ? },
        prior_nav_lamports : Lamports { atoms : (payload |> required_int_field("priorNavLamports", "priorNavLamports", false)) ? },
        costs_usd_micros : UsdMicros { atoms : (payload |> required_int_field("costsUsdMicros", "costsUsdMicros", false)) ? },
        risk_haircut_usd_micros : UsdMicros { atoms : (payload |> required_int_field("riskHaircutUsdMicros", "riskHaircutUsdMicros", false)) ? }
      })
    end
  end
end
