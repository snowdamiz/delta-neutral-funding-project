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
  epoch :: Int
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
  collateral_usd_micros :: UsdMicros
  maintenance_requirement_usd_micros :: UsdMicros
  liquidation_distance_bps :: Int
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

pub struct FundingSettlement do
  event_id :: String
  source :: String
  observed_at_ms :: Int
  source_slot :: Int
  source_sequence :: String
  idempotency_key :: String
  raw_payload_hash :: String
  venue_payment_id :: String
  effective_at_ms :: Int
  realized_short_rate_ppm :: RatePpm
  sol_price_usd_micros :: UsdMicros
end deriving(Json)

pub struct ShadowResult do
  body :: String
  binding_hash :: String
  command_id :: String
  status :: String
end

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

fn required_sha256(
  body :: String,
  key :: String,
  field :: String
) -> String ! String do
  let value = (body |> required_string(key, field)) ?
  if Regex.is_match(~r/^[0-9a-f]{64}$/, value) do
    Ok(value)
  else
    Err("${field} must be lowercase SHA-256 hex")
  end
end

fn required_hash(body :: String) -> String ! String do
  body |> required_sha256("rawPayloadHash", "rawPayloadHash")
end

fn matching_unsigned_fields(
  fields :: List<String>,
  left :: String,
  right :: String,
  index :: Int
) -> Unit ! String do
  if index >= List.length(fields) do
    return Ok(())
  end
  let field = List.get(fields, index)
  (left |> required_int_field(field, "action.${field}", false)) ?
  (right |> required_int_field(field, "report.${field}", false)) ?
  if Json.get(left, field) != Json.get(right, field) do
    return Err("shadow simulation report mismatch")
  end
  fields |> matching_unsigned_fields(left, right, index + 1)
end

fn unsigned_fields(
  fields :: List<String>,
  body :: String,
  prefix :: String,
  index :: Int
) -> Unit ! String do
  if index >= List.length(fields) do
    return Ok(())
  end
  let field = List.get(fields, index)
  (body |> required_int_field(field, "${prefix}.${field}", false)) ?
  fields |> unsigned_fields(body, prefix, index + 1)
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
      let maintenance = (payload |> required_int_field("maintenanceRequirementUsdMicros", "maintenanceRequirementUsdMicros", false)) ?
      if maintenance == 0 do
        return Err("maintenanceRequirementUsdMicros must be positive")
      end
      Ok(MarketSnapshot {
        event_id : (body |> required_string("eventId", "eventId")) ?,
        source : (body |> required_string("source", "source")) ?,
        observed_at_ms : (body |> required_int_field("observedAtMs", "observedAtMs", false)) ?,
        source_slot : (body |> required_int_field("sourceSlot", "sourceSlot", false)) ?,
        source_sequence : (body |> required_string("sourceSequence", "sourceSequence")) ?,
        idempotency_key : (body |> required_string("idempotencyKey", "idempotencyKey")) ?,
        raw_payload_hash : required_hash(body) ?,
        epoch : (payload |> required_int_field("epoch", "epoch", false)) ?,
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
        collateral_usd_micros : UsdMicros { atoms : (payload |> required_int_field("collateralUsdMicros", "collateralUsdMicros", false)) ? },
        maintenance_requirement_usd_micros : UsdMicros { atoms : maintenance },
        liquidation_distance_bps : (payload |> required_int_field("liquidationDistanceBps", "liquidationDistanceBps", false)) ?,
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

pub fn parse_funding_settlement(body :: String) -> FundingSettlement ! String do
  let _parsed = Json.parse(body) ?
  let schema_version = required_int(Json.get(body, "schemaVersion"), "schemaVersion", false) ?
  if schema_version != 1 do
    return Err("unsupported schema version")
  end
  let event_type = (body |> required_string("eventType", "eventType")) ?
  if event_type != "FundingSettlement" do
    return Err("unsupported event type")
  end
  let payload = body |> Json.get("payload")
  let observed_at_ms = (body |> required_int_field("observedAtMs", "observedAtMs", false)) ?
  let effective_at_ms = (payload |> required_int_field("effectiveAtMs", "effectiveAtMs", false)) ?
  if effective_at_ms > observed_at_ms do
    return Err("funding effective time cannot be in the future")
  end
  let sol_price = (payload |> required_int_field("solPriceUsdMicros", "solPriceUsdMicros", false)) ?
  if sol_price <= 0 do
    return Err("solPriceUsdMicros must be positive")
  end
  Ok(FundingSettlement {
    event_id : (body |> required_string("eventId", "eventId")) ?,
    source : (body |> required_string("source", "source")) ?,
    observed_at_ms : observed_at_ms,
    source_slot : (body |> required_int_field("sourceSlot", "sourceSlot", false)) ?,
    source_sequence : (body |> required_string("sourceSequence", "sourceSequence")) ?,
    idempotency_key : (body |> required_string("idempotencyKey", "idempotencyKey")) ?,
    raw_payload_hash : required_hash(body) ?,
    venue_payment_id : (payload |> required_string("venuePaymentId", "venuePaymentId")) ?,
    effective_at_ms : effective_at_ms,
    realized_short_rate_ppm : (payload |> required_rate_field("realizedShortRatePpm", "realizedShortRatePpm", true)) ?,
    sol_price_usd_micros : UsdMicros { atoms : sol_price }
  })
end

pub fn parse_shadow_result(body :: String) -> ShadowResult ! String do
  let _parsed = Json.parse(body) ?
  if (Json.get(body, "schemaVersion")
    |> required_int("schemaVersion", false)) ? != 1 do
    return Err("unsupported schema version")
  end
  let intent = body |> Json.get("intent")
  let action = body |> Json.get("action")
  let report = body |> Json.get("report")
  let paper = body |> Json.get("paperEstimate")
  (intent |> Json.parse) ?
  (action |> Json.parse) ?
  (report |> Json.parse) ?
  (paper |> Json.parse) ?

  if Json.get(action, "schemaVersion") != "1" do
    return Err("unsupported shadow schema version")
  end
  if Json.get(report, "schemaVersion") != "1" do
    return Err("unsupported shadow schema version")
  end
  if Json.get(action, "simulateOnly") != "true" || Json.get(action, "submit") != "false" do
    return Err("shadow action is not simulation-only")
  end

  let intent_id = (intent |> required_string("intentId", "intentId")) ?
  let command_id = (action |> required_string("commandId", "commandId")) ?
  let report_command = (report
    |> required_string("commandId", "report.commandId")) ?
  let message_hash = (action
    |> required_sha256("messageHash", "messageHash")) ?
  (action |> required_sha256("intentHash", "intentHash")) ?
  let status = (report |> required_string("status", "report.status")) ?
  if status != "PLANNED" && status != "UNKNOWN" && status != "REJECTED" do
    return Err("invalid shadow report status")
  end
  if command_id != "${intent_id}:shadow:1" || report_command != command_id do
    return Err("shadow result binding mismatch")
  end
  if Json.get(report, "intentId") != intent_id || Json.get(report, "mode") != "shadow" do
    return Err("shadow result binding mismatch")
  end
  if Json.get(report, "authoritativeReference") != message_hash do
    return Err("shadow result binding mismatch")
  end

  ([
    "simulatedQuantityAtoms",
    "simulatedAveragePriceAtoms",
    "simulatedFeeAtoms",
    "computeUnitsConsumed"
  ] |> matching_unsigned_fields(action, report, 0)) ?
  (["quantityAtoms", "averagePriceAtoms", "feeAtoms"]
    |> unsigned_fields(paper, "paperEstimate", 0)) ?

  Ok(ShadowResult {
    body : body,
    binding_hash : (intent <> "\n" <> action <> "\n" <> paper)
      |> Crypto.sha256,
    command_id : command_id,
    status : status
  })
end
