from Packages.Finance import Lamports, RatePpm
from Packages.ProtocolContracts import parse_market_snapshot

fn valid_snapshot() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"event-1\",\"eventType\":\"MarketSnapshot\",\"source\":\"synthetic\",\"observedAtMs\":\"1785024000000\",\"sourceSlot\":\"320000001\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"synthetic:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"oracleStatus\":\"valid\",\"totalPoolLamports\":\"12345678900\",\"supplyAtoms\":\"10000000000\",\"jitosolAtoms\":\"2000000000\",\"notionalUsdMicros\":\"500000000\",\"shortReceiptPpm\":\"250\",\"solPriceUsdMicros\":\"150000000\",\"priorNavLamports\":\"1234000000\",\"costsUsdMicros\":\"200000\",\"riskHaircutUsdMicros\":\"50000\",\"solSpotBidPriceUsdMicros\":\"149950000\",\"solSpotAskPriceUsdMicros\":\"150050000\",\"jitosolSpotBidPriceUsdMicros\":\"185050000\",\"jitosolSpotAskPriceUsdMicros\":\"185250000\",\"perpBidPriceUsdMicros\":\"149980000\",\"perpAskPriceUsdMicros\":\"150020000\",\"solExitDepthLamports\":\"50000000000\",\"jitosolExitDepthLamports\":\"30000000000\",\"perpExitDepthLamports\":\"100000000000\",\"fillRatePpm\":\"1000000\",\"slippagePpm\":\"500\",\"spotFeePpm\":\"500\",\"perpFeePpm\":\"400\",\"rejectRatePpm\":\"0\",\"unknownRatePpm\":\"0\"}}"
end

describe("protocol event v1") do
  test("accepts canonical integer strings and rejects another major version") do
    case parse_market_snapshot(valid_snapshot()) do
      Ok(snapshot) -> do
        assert(snapshot.event_id == "event-1")
        assert(snapshot.source == "synthetic")
        assert(snapshot.source_slot == 320000001)
        assert(snapshot.perp_exit_depth_lamports.atoms == 100000000000)
        assert(snapshot.fill_rate_ppm.atoms == 1000000)
        assert(snapshot.total_pool_lamports.atoms == 12345678900)
        assert(snapshot.short_receipt_ppm.atoms == 250)
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
  end
end
