from Packages.Replay import run_replay

fn snapshot() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"event-1\",\"eventType\":\"MarketSnapshot\",\"source\":\"replay\",\"observedAtMs\":\"1785024000000\",\"sourceSlot\":\"320000001\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"replay:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"epoch\":\"900\",\"oracleStatus\":\"valid\",\"totalPoolLamports\":\"12345678900\",\"supplyAtoms\":\"10000000000\",\"jitosolAtoms\":\"2000000000\",\"notionalUsdMicros\":\"500000000\",\"shortReceiptPpm\":\"250\",\"solPriceUsdMicros\":\"150000000\",\"priorNavLamports\":\"1234000000\",\"costsUsdMicros\":\"10000\",\"riskHaircutUsdMicros\":\"5000\",\"collateralUsdMicros\":\"200000000\",\"maintenanceRequirementUsdMicros\":\"50000000\",\"liquidationDistanceBps\":\"5000\",\"solSpotBidPriceUsdMicros\":\"149950000\",\"solSpotAskPriceUsdMicros\":\"150050000\",\"jitosolSpotBidPriceUsdMicros\":\"185050000\",\"jitosolSpotAskPriceUsdMicros\":\"185250000\",\"perpBidPriceUsdMicros\":\"149980000\",\"perpAskPriceUsdMicros\":\"150020000\",\"solExitDepthLamports\":\"50000000000\",\"jitosolExitDepthLamports\":\"30000000000\",\"perpExitDepthLamports\":\"100000000000\",\"fillRatePpm\":\"1000000\",\"slippagePpm\":\"500\",\"spotFeePpm\":\"500\",\"perpFeePpm\":\"400\",\"rejectRatePpm\":\"0\",\"unknownRatePpm\":\"0\"}}"
end

fn next_snapshot() -> String do
  snapshot()
    |> String.replace("\"eventId\":\"event-1\"", "\"eventId\":\"event-2\"")
    |> String.replace("\"observedAtMs\":\"1785024000000\"", "\"observedAtMs\":\"1785024001000\"")
    |> String.replace("\"sourceSlot\":\"320000001\"", "\"sourceSlot\":\"320000002\"")
    |> String.replace("\"sourceSequence\":\"1\"", "\"sourceSequence\":\"2\"")
    |> String.replace("\"idempotencyKey\":\"replay:1\"", "\"idempotencyKey\":\"replay:2\"")
end

fn invalid_snapshot() -> String do
  next_snapshot()
    |> String.replace("\"eventId\":\"event-2\"", "\"eventId\":\"event-3\"")
    |> String.replace("\"observedAtMs\":\"1785024001000\"", "\"observedAtMs\":\"1785024002000\"")
    |> String.replace("\"sourceSlot\":\"320000002\"", "\"sourceSlot\":\"320000003\"")
    |> String.replace("\"sourceSequence\":\"2\"", "\"sourceSequence\":\"3\"")
    |> String.replace("\"idempotencyKey\":\"replay:2\"", "\"idempotencyKey\":\"replay:3\"")
    |> String.replace("\"oracleStatus\":\"valid\"", "\"oracleStatus\":\"invalid\"")
end

fn funding() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"funding-2\",\"eventType\":\"FundingSettlement\",\"source\":\"replay\",\"observedAtMs\":\"1785024001000\",\"sourceSlot\":\"320000002\",\"sourceSequence\":\"2\",\"idempotencyKey\":\"replay:funding:2\",\"rawPayloadHash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"payload\":{\"venuePaymentId\":\"payment-2\",\"effectiveAtMs\":\"1785024001000\",\"realizedShortRatePpm\":\"250\",\"solPriceUsdMicros\":\"150000000\"}}"
end

fn bundle(config :: String, events :: List<String>) -> String do
  let manifest = "{\"replaySchemaVersion\":1,\"bundleId\":\"calm-v1\",\"configHash\":\"${Crypto.sha256(config)}\",\"meshCommit\":\"5f7e71e71c4058825a16a9dca63049f2dae351ea\"}"
  String.join(List.concat([manifest], events), "\n")
end

describe("deterministic replay") do
  test("uses virtual event time and rejects look-ahead ordering") do
    let config = "{\"replaySchemaVersion\":1,\"seed\":\"42\",\"maxSourceAgeMs\":\"5000\",\"minimumMarginRatioPpm\":\"1500000\",\"minimumLiquidationDistanceBps\":\"1000\",\"rebalanceDeltaBps\":\"50\"}"
    let events = [snapshot(), next_snapshot(), funding(), invalid_snapshot()]
    case run_replay(config, bundle(config, events), "5f7e71e71c4058825a16a9dca63049f2dae351ea") do
      Ok(first) -> do
        case run_replay(config, bundle(config, events), "5f7e71e71c4058825a16a9dca63049f2dae351ea") do
          Ok(second) -> do
            assert(first.event_count == 4)
            assert(first.decision_count == 6)
            assert(first.sol_entries == 1)
            assert(first.jitosol_entries == 1)
            assert(first.sol_exits == 1)
            assert(first.jitosol_exits == 1)
            assert(first.sol_rebalances == 0)
            assert(first.jitosol_rebalances == 0)
            assert(first.sol_emergencies == 0)
            assert(first.jitosol_emergencies == 0)
            assert(first.sol_reward_lamports == 0)
            assert(first.jitosol_reward_lamports == 0)
            assert(first.sol_basis_lamports == 0)
            assert(first.jitosol_basis_lamports == 0)
            assert(first.sol_funding_usd_micros == 92525)
            assert(first.jitosol_funding_usd_micros == 92525)
            assert(first.trace_hash == second.trace_hash)
          end
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end
    case run_replay(
      config,
      bundle(config, [next_snapshot(), snapshot()]),
      "5f7e71e71c4058825a16a9dca63049f2dae351ea"
    ) do
      Ok(report) -> assert(false)
      Err(error) -> assert(error == "replay events are out of canonical order")
    end
  end
end
