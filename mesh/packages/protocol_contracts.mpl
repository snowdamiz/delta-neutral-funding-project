from Packages.Finance import Lamports, PriceMicros, RatePpm, TokenAtoms, UsdMicros

pub type OracleStatus do
  OracleValid
  OracleInvalid
end deriving(Eq, Display, Json)

pub struct MarketSnapshot do
  event_id :: String
  source :: String
  observed_at_ms :: Int
  source_slot :: Int
  source_sequence :: String
  idempotency_key :: String
  raw_payload_hash :: String
  oracle_status :: OracleStatus
  total_pool_lamports :: Lamports
  supply_atoms :: TokenAtoms
  jitosol_atoms :: TokenAtoms
  notional_usd_micros :: UsdMicros
  short_receipt_ppm :: RatePpm
  sol_price_usd_micros :: UsdMicros
  prior_nav_lamports :: Lamports
  costs_usd_micros :: UsdMicros
  risk_haircut_usd_micros :: UsdMicros
  sol_spot_bid_price_usd_micros :: PriceMicros
  sol_spot_ask_price_usd_micros :: PriceMicros
  jitosol_spot_bid_price_usd_micros :: PriceMicros
  jitosol_spot_ask_price_usd_micros :: PriceMicros
  perp_bid_price_usd_micros :: PriceMicros
  perp_ask_price_usd_micros :: PriceMicros
  sol_exit_depth_lamports :: Lamports
  jitosol_exit_depth_lamports :: Lamports
  perp_exit_depth_lamports :: Lamports
  fill_rate_ppm :: RatePpm
  slippage_ppm :: RatePpm
  spot_fee_ppm :: RatePpm
  perp_fee_ppm :: RatePpm
  reject_rate_ppm :: RatePpm
  unknown_rate_ppm :: RatePpm
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

fn required_rate_field(body :: String, key :: String, field :: String, allow_negative :: Bool) -> RatePpm ! String do
  let atoms = (body |> required_int_field(key, field, allow_negative)) ?
  let minimum = if allow_negative do -1000000 else 0 end
  if atoms < minimum || atoms > 1000000 do
    Err("${field} must be between ${minimum} and one million ppm")
  else
    Ok(RatePpm { atoms : atoms })
  end
end

fn required_oracle_status(payload :: String) -> OracleStatus ! String do
  case (payload |> required_string("oracleStatus", "oracleStatus")) ? do
    "valid" -> Ok(OracleValid)
    "invalid" -> Ok(OracleInvalid)
    _ -> Err("oracleStatus must be valid or invalid")
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
      let reject_rate = (payload |> required_rate_field("rejectRatePpm", "rejectRatePpm", false)) ?
      let unknown_rate = (payload |> required_rate_field("unknownRatePpm", "unknownRatePpm", false)) ?
      let failure_total = (reject_rate.atoms |> Checked.add(unknown_rate.atoms)) ?
      if failure_total > 1000000 do
        return Err("paper failure rates exceed one million ppm")
      end
      Ok(MarketSnapshot {
        event_id : (body |> required_string("eventId", "eventId")) ?,
        source : (body |> required_string("source", "source")) ?,
        observed_at_ms : (body |> required_int_field("observedAtMs", "observedAtMs", false)) ?,
        source_slot : (body |> required_int_field("sourceSlot", "sourceSlot", false)) ?,
        source_sequence : (body |> required_string("sourceSequence", "sourceSequence")) ?,
        idempotency_key : (body |> required_string("idempotencyKey", "idempotencyKey")) ?,
        raw_payload_hash : required_hash(body) ?,
        oracle_status : required_oracle_status(payload) ?,
        total_pool_lamports : Lamports { atoms : (payload |> required_int_field("totalPoolLamports", "totalPoolLamports", false)) ? },
        supply_atoms : TokenAtoms { atoms : (payload |> required_int_field("supplyAtoms", "supplyAtoms", false)) ? },
        jitosol_atoms : TokenAtoms { atoms : (payload |> required_int_field("jitosolAtoms", "jitosolAtoms", false)) ? },
        notional_usd_micros : UsdMicros { atoms : (payload |> required_int_field("notionalUsdMicros", "notionalUsdMicros", false)) ? },
        short_receipt_ppm : (payload |> required_rate_field("shortReceiptPpm", "shortReceiptPpm", true)) ?,
        sol_price_usd_micros : UsdMicros { atoms : (payload |> required_int_field("solPriceUsdMicros", "solPriceUsdMicros", false)) ? },
        prior_nav_lamports : Lamports { atoms : (payload |> required_int_field("priorNavLamports", "priorNavLamports", false)) ? },
        costs_usd_micros : UsdMicros { atoms : (payload |> required_int_field("costsUsdMicros", "costsUsdMicros", false)) ? },
        risk_haircut_usd_micros : UsdMicros { atoms : (payload |> required_int_field("riskHaircutUsdMicros", "riskHaircutUsdMicros", false)) ? },
        sol_spot_bid_price_usd_micros : PriceMicros { atoms : (payload |> required_int_field("solSpotBidPriceUsdMicros", "solSpotBidPriceUsdMicros", false)) ? },
        sol_spot_ask_price_usd_micros : PriceMicros { atoms : (payload |> required_int_field("solSpotAskPriceUsdMicros", "solSpotAskPriceUsdMicros", false)) ? },
        jitosol_spot_bid_price_usd_micros : PriceMicros { atoms : (payload |> required_int_field("jitosolSpotBidPriceUsdMicros", "jitosolSpotBidPriceUsdMicros", false)) ? },
        jitosol_spot_ask_price_usd_micros : PriceMicros { atoms : (payload |> required_int_field("jitosolSpotAskPriceUsdMicros", "jitosolSpotAskPriceUsdMicros", false)) ? },
        perp_bid_price_usd_micros : PriceMicros { atoms : (payload |> required_int_field("perpBidPriceUsdMicros", "perpBidPriceUsdMicros", false)) ? },
        perp_ask_price_usd_micros : PriceMicros { atoms : (payload |> required_int_field("perpAskPriceUsdMicros", "perpAskPriceUsdMicros", false)) ? },
        sol_exit_depth_lamports : Lamports { atoms : (payload |> required_int_field("solExitDepthLamports", "solExitDepthLamports", false)) ? },
        jitosol_exit_depth_lamports : Lamports { atoms : (payload |> required_int_field("jitosolExitDepthLamports", "jitosolExitDepthLamports", false)) ? },
        perp_exit_depth_lamports : Lamports { atoms : (payload |> required_int_field("perpExitDepthLamports", "perpExitDepthLamports", false)) ? },
        fill_rate_ppm : (payload |> required_rate_field("fillRatePpm", "fillRatePpm", false)) ?,
        slippage_ppm : (payload |> required_rate_field("slippagePpm", "slippagePpm", false)) ?,
        spot_fee_ppm : (payload |> required_rate_field("spotFeePpm", "spotFeePpm", false)) ?,
        perp_fee_ppm : (payload |> required_rate_field("perpFeePpm", "perpFeePpm", false)) ?,
        reject_rate_ppm : reject_rate,
        unknown_rate_ppm : unknown_rate
      })
    end
  end
end
