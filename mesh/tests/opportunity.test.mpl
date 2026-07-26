from Packages.Finance import Lamports, UsdMicros
from Packages.Opportunity import evaluate_snapshot
from Packages.ProtocolContracts import parse_market_snapshot

fn comparison_snapshot() -> String do
  "{\"schemaVersion\":1,\"eventId\":\"event-1\",\"eventType\":\"MarketSnapshot\",\"source\":\"synthetic\",\"observedAtMs\":\"1785024000000\",\"sourceSequence\":\"1\",\"idempotencyKey\":\"synthetic:1\",\"rawPayloadHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"payload\":{\"totalPoolLamports\":\"12345678900\",\"supplyAtoms\":\"10000000000\",\"jitosolAtoms\":\"2000000000\",\"notionalUsdMicros\":\"500000000\",\"shortReceiptPpm\":\"250\",\"solPriceUsdMicros\":\"150000000\",\"priorNavLamports\":\"1234000000\",\"costsUsdMicros\":\"200000\",\"riskHaircutUsdMicros\":\"50000\"}}"
end

describe("dual opportunity evaluation") do
  test("attributes JitoSOL NAV reward without changing the shared funding input") do
    case parse_market_snapshot(comparison_snapshot()) do
      Ok(snapshot) -> do
        case evaluate_snapshot(snapshot) do
          Ok(result) -> do
            assert(result.nav_lamports.atoms == 1234567890)
            assert(result.hedge_lamports.atoms == 2469135780)
            assert(result.expected_funding_usd_micros.atoms == 125000)
            assert(result.nav_reward_usd_micros.atoms == 170367)
            assert(result.sol_net_carry_usd_micros.atoms == -125000)
            assert(result.jitosol_net_carry_usd_micros.atoms == 45367)
            assert(result.sol_eligible == false)
            assert(result.jitosol_eligible)
          end
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end
  end
end
