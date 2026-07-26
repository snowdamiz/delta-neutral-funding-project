from Packages.ProtocolContracts import parse_market_snapshot

fn valid_snapshot() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"event-1\",\"eventType\":\"MarketSnapshot\",\"source\":\"synthetic\",\"observedAtMs\":\"1785024000000\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"synthetic:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"totalPoolLamports\":\"12345678900\",\"supplyAtoms\":\"10000000000\",\"jitosolAtoms\":\"2000000000\",\"notionalUsdMicros\":\"500000000\",\"shortReceiptPpm\":\"250\",\"solPriceUsdMicros\":\"150000000\",\"priorNavLamports\":\"1234000000\",\"costsUsdMicros\":\"200000\",\"riskHaircutUsdMicros\":\"50000\"}}"
end

describe("protocol event v1") do
  test("accepts canonical integer strings and rejects another major version") do
    case parse_market_snapshot(valid_snapshot()) do
      Ok(snapshot) -> do
        assert(snapshot.event_id == "event-1")
        assert(snapshot.total_pool_lamports == 12345678900)
        assert(snapshot.short_receipt_ppm == 250)
      end
      Err(error) -> assert(false)
    end

    let wrong_version = String.replace(valid_snapshot(), "\"schemaVersion\":1", "\"schemaVersion\":2")
    case parse_market_snapshot(wrong_version) do
      Ok(snapshot) -> assert(false)
      Err(error) -> assert(error == "unsupported schema version")
    end
  end
end
