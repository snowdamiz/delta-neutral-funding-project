from Packages.Finance import Lamports, RatePpm
from Packages.ProtocolContracts import parse_funding_settlement, parse_market_snapshot, parse_shadow_result

fn valid_snapshot() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"event-1\",\"eventType\":\"MarketSnapshot\",\"source\":\"synthetic\",\"observedAtMs\":\"1785024000000\",\"sourceSlot\":\"320000001\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"synthetic:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"epoch\":\"900\",\"oracleStatus\":\"valid\",\"totalPoolLamports\":\"12345678900\",\"supplyAtoms\":\"10000000000\",\"jitosolAtoms\":\"2000000000\",\"notionalUsdMicros\":\"500000000\",\"shortReceiptPpm\":\"250\",\"solPriceUsdMicros\":\"150000000\",\"priorNavLamports\":\"1234000000\",\"costsUsdMicros\":\"200000\",\"riskHaircutUsdMicros\":\"50000\",\"collateralUsdMicros\":\"200000000\",\"maintenanceRequirementUsdMicros\":\"50000000\",\"liquidationDistanceBps\":\"5000\",\"solSpotBidPriceUsdMicros\":\"149950000\",\"solSpotAskPriceUsdMicros\":\"150050000\",\"jitosolSpotBidPriceUsdMicros\":\"185050000\",\"jitosolSpotAskPriceUsdMicros\":\"185250000\",\"perpBidPriceUsdMicros\":\"149980000\",\"perpAskPriceUsdMicros\":\"150020000\",\"solExitDepthLamports\":\"50000000000\",\"jitosolExitDepthLamports\":\"30000000000\",\"perpExitDepthLamports\":\"100000000000\",\"fillRatePpm\":\"1000000\",\"slippagePpm\":\"500\",\"spotFeePpm\":\"500\",\"perpFeePpm\":\"400\",\"rejectRatePpm\":\"0\",\"unknownRatePpm\":\"0\"}}"
end

fn valid_shadow_result() -> String do
  "{\"schemaVersion\":1,\"intent\":{\"schemaVersion\":1,\"intentId\":\"intent-1\",\"instrument\":\"SOL-PERP\"},\"action\":{\"schemaVersion\":1,\"commandId\":\"intent-1:shadow:1\",\"intentHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"market\":\"SOL-PERP\",\"simulateOnly\":true,\"submit\":false,\"messageHash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"simulatedQuantityAtoms\":\"10\",\"simulatedAveragePriceAtoms\":\"20\",\"simulatedFeeAtoms\":\"3\",\"computeUnitsConsumed\":\"4\"},\"report\":{\"schemaVersion\":1,\"intentId\":\"intent-1\",\"commandId\":\"intent-1:shadow:1\",\"mode\":\"shadow\",\"status\":\"PLANNED\",\"authoritativeReference\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"simulatedQuantityAtoms\":\"10\",\"simulatedAveragePriceAtoms\":\"20\",\"simulatedFeeAtoms\":\"3\",\"computeUnitsConsumed\":\"4\"},\"paperEstimate\":{\"quantityAtoms\":\"10\",\"averagePriceAtoms\":\"19\",\"feeAtoms\":\"2\"}}"
end

fn assert_shadow_mutations_rejected(
  bodies :: List<String>,
  index :: Int
) -> Int do
  if index >= List.length(bodies) do
    index
  else
    case parse_shadow_result(List.get(bodies, index)) do
      Ok(result) -> do
        assert(false)
        index
      end
      Err(error) -> bodies |> assert_shadow_mutations_rejected(index + 1)
    end
  end
end

describe("shadow result v1") do
  test("binds an isolated action and excludes its outcome from idempotency") do
    case parse_shadow_result(valid_shadow_result()) do
      Ok(result) -> do
        assert(result.command_id == "intent-1:shadow:1")
        assert(result.status == "PLANNED")
        assert(Regex.is_match(~r/^[0-9a-f]{64}$/, result.binding_hash))
      end
      Err(error) -> assert(false)
    end

    let unsafe = String.replace(
      valid_shadow_result(),
      "\"submit\":false",
      "\"submit\":true"
    )
    case parse_shadow_result(unsafe) do
      Ok(result) -> assert(false)
      Err(error) -> assert(error == "shadow action is not simulation-only")
    end
  end

  test("rejects deterministic trust-boundary mutations") do
    let valid = valid_shadow_result()
    let mutations = [
      "{",
      valid |> String.replace("\"submit\":false", "\"submit\":true"),
      valid |> String.replace("\"simulatedQuantityAtoms\":\"10\"", "\"simulatedQuantityAtoms\":10"),
      valid |> String.replace("\"simulatedFeeAtoms\":\"3\"", "\"simulatedFeeAtoms\":\"-0\""),
      valid |> String.replace("\"commandId\":\"intent-1:shadow:1\"", "\"commandId\":\"intent-2:shadow:1\""),
      valid |> String.replace("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "not-a-hash")
    ]
    assert((mutations |> assert_shadow_mutations_rejected(0)) == List.length(mutations))
  end
end

describe("funding settlement event v1") do
  test("preserves the signed realized rate and venue identity") do
    let body = "{\"schemaVersion\":1,\"eventId\":\"funding-1\",\"eventType\":\"FundingSettlement\",\"source\":\"venue-test\",\"observedAtMs\":\"1785024000000\",\"sourceSlot\":\"320000001\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"venue-test:funding:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"venuePaymentId\":\"payment-1\",\"effectiveAtMs\":\"1785023999000\",\"realizedShortRatePpm\":\"-100\",\"solPriceUsdMicros\":\"150000000\"}}"
    case parse_funding_settlement(body) do
      Ok(settlement) -> do
        assert(settlement.venue_payment_id == "payment-1")
        assert(settlement.realized_short_rate_ppm.atoms == -100)
        assert(settlement.sol_price_usd_micros.atoms == 150000000)
      end
      Err(error) -> assert(false)
    end
  end
end

describe("protocol event v1") do
  test("accepts canonical integer strings and rejects another major version") do
    case parse_market_snapshot(valid_snapshot()) do
      Ok(snapshot) -> do
        assert(snapshot.event_id == "event-1")
        assert(snapshot.source == "synthetic")
        assert(snapshot.source_slot == 320000001)
        assert(snapshot.epoch == 900)
        assert(snapshot.perp_exit_depth_lamports.atoms == 100000000000)
        assert(snapshot.fill_rate_ppm.atoms == 1000000)
        assert(snapshot.total_pool_lamports.atoms == 12345678900)
        assert(snapshot.short_receipt_ppm.atoms == 250)
        assert(snapshot.collateral_usd_micros.atoms == 200000000)
        assert(snapshot.liquidation_distance_bps == 5000)
      end
      Err(error) -> assert(false)
    end

    let wrong_version = String.replace(valid_snapshot(), "\"schemaVersion\":1", "\"schemaVersion\":2")
    case parse_market_snapshot(wrong_version) do
      Ok(snapshot) -> assert(false)
      Err(error) -> assert(error == "unsupported schema version")
    end
  end

  test("rejects non-string, non-canonical, and malformed trust-boundary values") do
    let numeric_time = String.replace(valid_snapshot(), "\"observedAtMs\":\"1785024000000\"", "\"observedAtMs\":1785024000000")
    case parse_market_snapshot(numeric_time) do
      Ok(snapshot) -> assert(false)
      Err(error) -> assert(error == "observedAtMs must be a JSON string")
    end

    let leading_zero = String.replace(valid_snapshot(), "\"supplyAtoms\":\"10000000000\"", "\"supplyAtoms\":\"010000000000\"")
    case parse_market_snapshot(leading_zero) do
      Ok(snapshot) -> assert(false)
      Err(error) -> assert(error == "supplyAtoms must be a canonical base-10 integer string")
    end

    let bad_hash = String.replace(valid_snapshot(), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "not-a-sha256")
    case parse_market_snapshot(bad_hash) do
      Ok(snapshot) -> assert(false)
      Err(error) -> assert(error == "rawPayloadHash must be lowercase SHA-256 hex")
    end

    let invalid_failures = String.replace(valid_snapshot(), "\"rejectRatePpm\":\"0\",\"unknownRatePpm\":\"0\"", "\"rejectRatePpm\":\"600000\",\"unknownRatePpm\":\"500000\"")
    case parse_market_snapshot(invalid_failures) do
      Ok(snapshot) -> assert(false)
      Err(error) -> assert(error == "paper failure rates exceed one million ppm")
    end

    let negative_zero = String.replace(valid_snapshot(), "\"shortReceiptPpm\":\"250\"", "\"shortReceiptPpm\":\"-0\"")
    case parse_market_snapshot(negative_zero) do
      Ok(snapshot) -> assert(false)
      Err(error) -> assert(error == "shortReceiptPpm must be a canonical base-10 integer string")
    end
  end
end
