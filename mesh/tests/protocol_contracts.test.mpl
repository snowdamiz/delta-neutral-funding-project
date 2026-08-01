from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros
from Packages.ProtocolContracts import parse_funding_observation, parse_funding_settlement, parse_market_snapshot

fn valid_snapshot() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"event-1\",\"eventType\":\"MarketSnapshot\",\"source\":\"synthetic\",\"observedAtMs\":\"1785024000000\",\"sourceSlot\":\"320000001\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"synthetic:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"epoch\":\"900\",\"oracleStatus\":\"valid\",\"totalPoolLamports\":\"12345678900\",\"supplyAtoms\":\"10000000000\",\"jitosolAtoms\":\"2000000000\",\"notionalUsdMicros\":\"500000000\",\"shortReceiptPpm\":\"250\",\"solPriceUsdMicros\":\"150000000\",\"priorNavLamports\":\"1234000000\",\"costsUsdMicros\":\"200000\",\"riskHaircutUsdMicros\":\"50000\",\"collateralUsdMicros\":\"200000000\",\"maintenanceRequirementUsdMicros\":\"50000000\",\"liquidationDistanceBps\":\"5000\",\"solSpotBidPriceUsdMicros\":\"149950000\",\"solSpotAskPriceUsdMicros\":\"150050000\",\"jitosolSpotBidPriceUsdMicros\":\"185050000\",\"jitosolSpotAskPriceUsdMicros\":\"185250000\",\"perpBidPriceUsdMicros\":\"149980000\",\"perpAskPriceUsdMicros\":\"150020000\",\"solExitDepthLamports\":\"50000000000\",\"jitosolExitDepthLamports\":\"30000000000\",\"perpExitDepthLamports\":\"100000000000\",\"fillRatePpm\":\"1000000\",\"slippagePpm\":\"500\",\"spotFeePpm\":\"500\",\"perpFeePpm\":\"400\",\"rejectRatePpm\":\"0\",\"unknownRatePpm\":\"0\"}}"
end

fn valid_funding_observation() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"funding-btc-1\",\"eventType\":\"FundingObservation\",\"source\":\"hyperliquid-funding:BTC\",\"observedAtMs\":\"1785024000000\",\"sourceSlot\":\"1785023999000\",\"sourceSequence\":\"scan-1\",\"idempotencyKey\":\"funding-btc-1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"scanId\":\"funding-scan-1\",\"scanIndex\":\"0\",\"scanSize\":\"2\",\"venue\":\"hyperliquid\",\"asset\":\"BTC\",\"instrument\":\"BTC-PERP\",\"sourceObservedAtMs\":\"1785023999000\",\"sourceStatus\":\"valid\",\"fundingRatePpmPerHour\":\"-20\",\"realizedFundingRatePpm\":\"-18\",\"realizedFundingAtMs\":\"1785020400000\",\"markPriceUsdMicros\":\"50000000000\",\"openInterestUsdMicros\":\"1000000000000\",\"spotBidPriceUsdMicros\":\"49990000000\",\"spotAskPriceUsdMicros\":\"50010000000\",\"perpBidPriceUsdMicros\":\"49995000000\",\"perpAskPriceUsdMicros\":\"50005000000\",\"spotExitDepthAtoms\":\"100000000\",\"perpExitDepthAtoms\":\"100000000\",\"depthQualified\":true,\"borrowVenue\":\"kamino\",\"borrowMarket\":\"7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF\",\"borrowReserve\":\"d4A2prbA2whesmvHaL88BH6Ewn5N4bTSU2Ze8P6Bc4Q\",\"borrowMint\":\"So11111111111111111111111111111111111111112\",\"borrowSourceObservedAtMs\":\"1785023999000\",\"borrowSourceStatus\":\"valid\",\"borrowRatePpmPerHour\":\"5\",\"borrowAvailableUsdMicros\":\"2000000000\",\"borrowUtilizationPpm\":\"500000\"}}"
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

describe("funding observation event v1") do
  test("preserves per-asset ranking inputs and rejects unsafe depth") do
    case parse_funding_observation(valid_funding_observation()) do
      Ok(observation) -> do
        assert(observation.asset == "BTC")
        assert(observation.funding_rate_ppm_per_hour.atoms == -20)
        assert(observation.depth_qualified)
        assert(observation.borrow_source_status == "valid")
        assert(observation.borrow_rate_ppm_per_hour.atoms == 5)
      end
      Err(error) -> assert(false)
    end

    let unsafe = valid_funding_observation()
      |> String.replace(
        "\"spotExitDepthAtoms\":\"100000000\"",
        "\"spotExitDepthAtoms\":\"0\""
      )
    case parse_funding_observation(unsafe) do
      Ok(observation) -> assert(false)
      Err(error) -> assert(error == "qualified funding depth must be positive")
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
