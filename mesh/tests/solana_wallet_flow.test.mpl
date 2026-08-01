from Packages.SolanaWalletFlow import parse_solana_wallet_flow_event

fn acquisition() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"solana-acquisition-a\",\"eventType\":\"SolanaWalletAcquisition\",\"source\":\"solana-wallet:11111111111111111111111111111111:mint-a\",\"observedAtMs\":\"200000\",\"sourceSlot\":\"12\",\"sourceSequence\":\"swap-2\",\"idempotencyKey\":\"solana-acquisition:wallet:swap-2:mint-a\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"wallet\":\"11111111111111111111111111111111\",\"signature\":\"swap-2\",\"confirmedAtMs\":\"102000\",\"inputMint\":\"So11111111111111111111111111111111111111112\",\"inputAmountAtoms\":\"100000\",\"outputMint\":\"4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ\",\"outputAmountAtoms\":\"250000\",\"outputDecimals\":\"6\",\"routePrograms\":[\"JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4\"]}}"
end

describe("Solana wallet-flow event") do
  test("preserves the exact acquisition identity") do
    case parse_solana_wallet_flow_event(acquisition()) do
      Ok(event) -> do
        assert(event.event_type == "SolanaWalletAcquisition")
        assert(event.wallet == "11111111111111111111111111111111")
        assert(event.observed_at_ms == 200000)
        assert(event.source_slot == 12)
      end
      Err(error) -> assert(false)
    end
  end

  test("rejects an unrecognized event before persistence") do
    let invalid = acquisition()
      |> String.replace("SolanaWalletAcquisition", "SolanaWalletSale")
    case parse_solana_wallet_flow_event(invalid) do
      Ok(event) -> assert(false)
      Err(error) -> assert(error == "unsupported Solana wallet event type")
    end
  end
end
