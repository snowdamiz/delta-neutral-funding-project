from Packages.Finance import Lamports, RatePpm
from Packages.ProtocolContracts import parse_market_snapshot

fn valid_snapshot() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"event-1\",\"eventType\":\"MarketSnapshot\",\"source\":\"synthetic\",\"observedAtMs\":\"1785024000000\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"synthetic:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"totalPoolLamports\":\"12345678900\",\"supplyAtoms\":\"10000000000\",\"jitosolAtoms\":\"2000000000\",\"notionalUsdMicros\":\"500000000\",\"shortReceiptPpm\":\"250\",\"solPriceUsdMicros\":\"150000000\",\"priorNavLamports\":\"1234000000\",\"costsUsdMicros\":\"200000\",\"riskHaircutUsdMicros\":\"50000\"}}"
end

describe("protocol event v1") do
  test("accepts canonical integer strings and rejects another major version") do
    case parse_market_snapshot(valid_snapshot()) do
      Ok(snapshot) -> do
        assert(snapshot.event_id == "event-1")
        assert(snapshot.source == "synthetic")
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
  end
end
