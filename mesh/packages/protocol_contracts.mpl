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
  reward_rate_ppm_per_hour :: RatePpm
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

pub struct FundingObservation do
  body :: String
  event_id :: String
  observed_at_ms :: Int
  scan_id :: String
  scan_index :: Int
  scan_size :: Int
  venue :: String
  asset :: String
  source_status :: String
  funding_rate_ppm_per_hour :: RatePpm
  depth_qualified :: Bool
  margin_status :: String
  maintenance_margin_ppm :: RatePpm
  borrow_source_status :: String
  borrow_rate_ppm_per_hour :: RatePpm
end

pub struct WalletObservation do
  body :: String
  event_id :: String
  observed_at_ms :: Int
  wallet :: String
  positions :: Int
  fills :: Int
end

pub struct ShadowResult do
  body :: String
  binding_hash :: String
  command_id :: String
  status :: String
end

fn validate_wallet_positions(
  values :: Json,
  index :: Int,
  total :: Int
) -> Unit ! String do
  if index >= total do
    return Ok(())
  end
  let position = ((values |> Json.array_get(index)) ? |> Json.encode)
  let asset = (position |> required_string("asset", "position.asset")) ?
  let side = (position |> required_string("side", "position.side")) ?
  if (Regex.is_match(~r/^[A-Z0-9:_-]{1,64}$/, asset) == false
    || (side != "long" && side != "short")) do
    return Err("invalid wallet position identity")
  end
  let fields = [
    "quantityAtoms",
    "entryPriceUsdMicros",
    "markPriceUsdMicros",
    "leveragePpm"
  ]
  (fields |> unsigned_fields(position, "position", 0)) ?
  let quantity = (position
    |> required_int_field("quantityAtoms", "position.quantityAtoms", false)) ?
  let entry = (position
    |> required_int_field(
      "entryPriceUsdMicros",
      "position.entryPriceUsdMicros",
      false
    )) ?
  let mark = (position
    |> required_int_field(
      "markPriceUsdMicros",
      "position.markPriceUsdMicros",
      false
    )) ?
  let leverage = (position
    |> required_int_field("leveragePpm", "position.leveragePpm", false)) ?
  if quantity <= 0 || entry <= 0 || mark <= 0 || leverage <= 0 do
    return Err("wallet position economics must be positive")
  end
  (position
    |> required_int_field(
      "unrealizedPnlUsdMicros",
      "position.unrealizedPnlUsdMicros",
      true
    )) ?
  values |> validate_wallet_positions(index + 1, total)
end

fn validate_wallet_fills(
  values :: Json,
  index :: Int,
  total :: Int,
  observed_at_ms :: Int
) -> Unit ! String do
  if index >= total do
    return Ok(())
  end
  let fill = ((values |> Json.array_get(index)) ? |> Json.encode)
  (fill |> required_string("fillId", "fill.fillId")) ?
  let asset = (fill |> required_string("asset", "fill.asset")) ?
  let side = (fill |> required_string("side", "fill.side")) ?
  let direction = (fill |> required_string("direction", "fill.direction")) ?
  if (Regex.is_match(~r/^[A-Z0-9:_-]{1,64}$/, asset) == false
    || (side != "buy" && side != "sell")
    || (direction != "open"
      && direction != "increase"
      && direction != "reduce"
      && direction != "close"
      && direction != "flip")) do
    return Err("invalid wallet fill identity")
  end
  let quantity = (fill
    |> required_int_field("quantityAtoms", "fill.quantityAtoms", false)) ?
  let leader_price = (fill
    |> required_int_field(
      "leaderPriceUsdMicros",
      "fill.leaderPriceUsdMicros",
      false
    )) ?
  let copy_bid = (fill
    |> required_int_field(
      "copyBidPriceUsdMicros",
      "fill.copyBidPriceUsdMicros",
      false
    )) ?
  let copy_ask = (fill
    |> required_int_field(
      "copyAskPriceUsdMicros",
      "fill.copyAskPriceUsdMicros",
      false
    )) ?
  (fill
    |> required_int_field(
      "closedPnlUsdMicros",
      "fill.closedPnlUsdMicros",
      true
    )) ?
  (fill |> required_int_field("feeUsdMicros", "fill.feeUsdMicros", false)) ?
  let filled_at_ms = (fill
    |> required_int_field("filledAtMs", "fill.filledAtMs", false)) ?
  let copy_observed_at_ms = (fill
    |> required_int_field(
      "copyObservedAtMs",
      "fill.copyObservedAtMs",
      false
    )) ?
  let copy_latency_ms = (fill
    |> required_int_field("copyLatencyMs", "fill.copyLatencyMs", false)) ?
  let bid_depth = Json.get(fill, "copyBidDepthQualified")
  let ask_depth = Json.get(fill, "copyAskDepthQualified")
  if (Json.is_string(fill, "copyBidDepthQualified")
    || Json.is_string(fill, "copyAskDepthQualified")
    || (bid_depth != "true" && bid_depth != "false")
    || (ask_depth != "true" && ask_depth != "false")) do
    return Err("copy depth qualification must be JSON booleans")
  end
  if (quantity <= 0
    || leader_price <= 0
    || filled_at_ms > observed_at_ms
    || copy_observed_at_ms != observed_at_ms
    || copy_latency_ms < observed_at_ms - filled_at_ms) do
    return Err("wallet fill timing is invalid")
  end
  if ((bid_depth == "true" && copy_bid <= 0)
    || (ask_depth == "true" && copy_ask <= 0)) do
    return Err("qualified wallet fill requires executable side prices")
  end
  values |> validate_wallet_fills(index + 1, total, observed_at_ms)
end

fn required_int(raw :: String, field :: String, allow_negative :: Bool) -> Int ! String do
  let canonical = if allow_negative do
    Regex.is_match(~r/^(0|-?[1-9][0-9]*)$/, raw)
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
  ((body
    |> required_string(key, field)) ?
    |> required_int(field, allow_negative))
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

fn optional_rate_field(body :: String, key :: String, field :: String) -> RatePpm ! String do
  if Json.is_string(body, key) do
    required_rate_field(body, key, field, false)
  else
    Ok(RatePpm { atoms : 0 })
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
        reward_rate_ppm_per_hour : (payload |> optional_rate_field("rewardRatePpmPerHour", "rewardRatePpmPerHour")) ?,
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

pub fn parse_funding_observation(
  body :: String
) -> FundingObservation ! String do
  let _parsed = Json.parse(body) ?
  if required_int(
    Json.get(body, "schemaVersion"),
    "schemaVersion",
    false
  ) ? != 1 do
    return Err("unsupported schema version")
  end
  if (body |> required_string("eventType", "eventType")) ? != "FundingObservation" do
    return Err("unsupported event type")
  end

  let payload = body |> Json.get("payload")
  let observed_at_ms = (body
    |> required_int_field("observedAtMs", "observedAtMs", false)) ?
  let scan_index = (payload
    |> required_int_field("scanIndex", "scanIndex", false)) ?
  let scan_size = (payload
    |> required_int_field("scanSize", "scanSize", false)) ?
  if scan_size <= 0 || scan_index >= scan_size do
    return Err("invalid funding scan position")
  end

  let venue = (payload |> required_string("venue", "venue")) ?
  let asset = (payload |> required_string("asset", "asset")) ?
  let instrument = (payload
    |> required_string("instrument", "instrument")) ?
  if Regex.is_match(~r/^[a-z][a-z0-9_-]*$/, venue) == false do
    return Err("invalid funding instrument identity")
  end
  if Regex.is_match(~r/^[A-Z0-9]+$/, asset) == false do
    return Err("invalid funding instrument identity")
  end
  if instrument != "${asset}-PERP" do
    return Err("invalid funding instrument identity")
  end

  let source_status = (payload
    |> required_string("sourceStatus", "sourceStatus")) ?
  if source_status != "valid" && source_status != "invalid" do
    return Err("sourceStatus must be valid or invalid")
  end
  let mark_price = (payload
    |> required_int_field("markPriceUsdMicros", "markPriceUsdMicros", false)) ?
  if source_status == "valid" && mark_price <= 0 do
    return Err("valid funding mark price must be positive")
  end
  let realized_at_ms = (payload
    |> required_int_field("realizedFundingAtMs", "realizedFundingAtMs", false)) ?
  (payload
    |> required_rate_field(
      "realizedFundingRatePpm",
      "realizedFundingRatePpm",
      true
    )) ?
  if realized_at_ms > observed_at_ms do
    return Err("realized funding time cannot be in the future")
  end

  let spot_bid = (payload
    |> required_int_field("spotBidPriceUsdMicros", "spotBidPriceUsdMicros", false)) ?
  let spot_ask = (payload
    |> required_int_field("spotAskPriceUsdMicros", "spotAskPriceUsdMicros", false)) ?
  let perp_bid = (payload
    |> required_int_field("perpBidPriceUsdMicros", "perpBidPriceUsdMicros", false)) ?
  let perp_ask = (payload
    |> required_int_field("perpAskPriceUsdMicros", "perpAskPriceUsdMicros", false)) ?
  let spot_depth = (payload
    |> required_int_field("spotExitDepthAtoms", "spotExitDepthAtoms", false)) ?
  let perp_depth = (payload
    |> required_int_field("perpExitDepthAtoms", "perpExitDepthAtoms", false)) ?
  let depth_value = Json.get(payload, "depthQualified")
  if Json.is_string(payload, "depthQualified") do
    return Err("depthQualified must be a JSON boolean")
  end
  if depth_value != "true" && depth_value != "false" do
    return Err("depthQualified must be a JSON boolean")
  end
  let depth_qualified = depth_value == "true"
  if depth_qualified do
    if source_status != "valid" do
      return Err("qualified funding depth must be positive")
    end
    if spot_bid <= 0 || spot_ask <= 0 || perp_bid <= 0 || perp_ask <= 0 do
      return Err("qualified funding depth must be positive")
    end
    if spot_depth <= 0 || perp_depth <= 0 do
      return Err("qualified funding depth must be positive")
    end
  end

  let margin_status = (payload
    |> required_string("marginStatus", "marginStatus")) ?
  let maintenance_margin = (payload
    |> required_rate_field(
      "maintenanceMarginPpm",
      "maintenanceMarginPpm",
      false
    )) ?
  if ((margin_status != "valid" && margin_status != "unavailable")
    || (margin_status == "valid" && maintenance_margin.atoms == 0)
    || (margin_status == "unavailable"
      && maintenance_margin.atoms != 0)) do
    return Err("invalid funding margin contract")
  end

  let borrow_status = (payload
    |> required_string("borrowSourceStatus", "borrowSourceStatus")) ?
  if (borrow_status != "valid"
    && borrow_status != "invalid"
    && borrow_status != "unavailable") do
    return Err("borrowSourceStatus must be valid, invalid, or unavailable")
  end
  let borrow_venue = (payload
    |> required_string("borrowVenue", "borrowVenue")) ?
  let borrow_market = (payload
    |> required_string("borrowMarket", "borrowMarket")) ?
  let borrow_reserve = (payload
    |> required_string("borrowReserve", "borrowReserve")) ?
  let borrow_mint = (payload
    |> required_string("borrowMint", "borrowMint")) ?
  let borrow_observed_at_ms = (payload
    |> required_int_field(
      "borrowSourceObservedAtMs",
      "borrowSourceObservedAtMs",
      false
    )) ?
  let borrow_rate = (payload
    |> required_rate_field(
      "borrowRatePpmPerHour",
      "borrowRatePpmPerHour",
      false
    )) ?
  let borrow_available = (payload
    |> required_int_field(
      "borrowAvailableUsdMicros",
      "borrowAvailableUsdMicros",
      false
    )) ?
  let borrow_utilization = (payload
    |> required_rate_field(
      "borrowUtilizationPpm",
      "borrowUtilizationPpm",
      false
    )) ?
  if borrow_status == "valid" do
    let public_key = ~r/^[1-9A-HJ-NP-Za-km-z]{32,44}$/
    if (borrow_venue != "kamino"
      || Regex.is_match(public_key, borrow_market) == false
      || Regex.is_match(public_key, borrow_reserve) == false
      || Regex.is_match(public_key, borrow_mint) == false
      || borrow_observed_at_ms <= 0
      || borrow_observed_at_ms > observed_at_ms) do
      return Err("valid borrow snapshot has invalid identity or time")
    end
  else
    if (borrow_rate.atoms != 0
      || borrow_available != 0
      || borrow_utilization.atoms != 0) do
      return Err("unusable borrow snapshot must carry zero economics")
    end
  end

  (body |> required_string("source", "source")) ?
  (body |> required_int_field("sourceSlot", "sourceSlot", false)) ?
  (body |> required_string("sourceSequence", "sourceSequence")) ?
  (body |> required_string("idempotencyKey", "idempotencyKey")) ?
  required_hash(body) ?
  (payload |> required_string("scanId", "scanId")) ?
  (payload
    |> required_int_field("sourceObservedAtMs", "sourceObservedAtMs", false)) ?
  (payload
    |> required_int_field("openInterestUsdMicros", "openInterestUsdMicros", false)) ?

  Ok(FundingObservation {
    body : body,
    event_id : (body |> required_string("eventId", "eventId")) ?,
    observed_at_ms : observed_at_ms,
    scan_id : (payload |> required_string("scanId", "scanId")) ?,
    scan_index : scan_index,
    scan_size : scan_size,
    venue : venue,
    asset : asset,
    source_status : source_status,
    funding_rate_ppm_per_hour : (payload
      |> required_rate_field(
        "fundingRatePpmPerHour",
        "fundingRatePpmPerHour",
        true
      )) ?,
    depth_qualified : depth_qualified,
    margin_status : margin_status,
    maintenance_margin_ppm : maintenance_margin,
    borrow_source_status : borrow_status,
    borrow_rate_ppm_per_hour : borrow_rate
  })
end

pub fn parse_wallet_observation(
  body :: String
) -> WalletObservation ! String do
  let root = Json.parse(body) ?
  if required_int(
    Json.get(body, "schemaVersion"),
    "schemaVersion",
    false
  ) ? != 1 do
    return Err("unsupported schema version")
  end
  let event_type = (body |> required_string("eventType", "eventType")) ?
  if event_type != "WalletObservation" do
    return Err("unsupported event type")
  end
  let payload = body |> Json.get("payload")
  let observed_at_ms = (body
    |> required_int_field("observedAtMs", "observedAtMs", false)) ?
  let source_observed_at_ms = (payload
    |> required_int_field(
      "sourceObservedAtMs",
      "sourceObservedAtMs",
      false
    )) ?
  if source_observed_at_ms > observed_at_ms do
    return Err("wallet source time cannot be in the future")
  end
  let wallet = (payload |> required_string("wallet", "wallet")) ?
  if Regex.is_match(~r/^0x[0-9a-f]{40}$/, wallet) == false do
    return Err("invalid Hyperliquid wallet address")
  end
  (body |> required_string("eventId", "eventId")) ?
  (body |> required_string("source", "source")) ?
  (body |> required_int_field("sourceSlot", "sourceSlot", false)) ?
  (body |> required_string("sourceSequence", "sourceSequence")) ?
  (body |> required_string("idempotencyKey", "idempotencyKey")) ?
  required_hash(body) ?
  (payload
    |> required_int_field(
      "accountValueUsdMicros",
      "accountValueUsdMicros",
      false
    )) ?
  (payload
    |> required_int_field(
      "totalNotionalUsdMicros",
      "totalNotionalUsdMicros",
      false
    )) ?
  (payload |> required_int_field("apiLatencyMs", "apiLatencyMs", false)) ?

  let payload_json = (root |> Json.object_get("payload")) ?
  let positions_json = (payload_json |> Json.object_get("positions")) ?
  let fills_json = (payload_json |> Json.object_get("fills")) ?
  let positions = (positions_json |> Json.array_length()) ?
  let fills = (fills_json |> Json.array_length()) ?
  (positions_json |> validate_wallet_positions(0, positions)) ?
  (fills_json |> validate_wallet_fills(0, fills, observed_at_ms)) ?
  Ok(WalletObservation {
    body : body,
    event_id : (body |> required_string("eventId", "eventId")) ?,
    observed_at_ms : observed_at_ms,
    wallet : wallet,
    positions : positions,
    fills : fills
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
