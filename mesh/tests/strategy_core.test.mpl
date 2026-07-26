from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros
from Packages.StrategyCore import expected_funding_usd_micros, hedge_lamports, is_entry_eligible, jitosol_nav_lamports, nav_reward_lamports, net_carry_usd_micros

describe("fixed-point strategy core") do
  test("prices JitoSOL carry and rejects non-positive short funding") do
    case jitosol_nav_lamports(Lamports { atoms : 12345678900 }, TokenAtoms { atoms : 10000000000 }) do
      Ok(nav) -> do
        assert(nav.atoms == 1234567890)
        case hedge_lamports(TokenAtoms { atoms : 2000000000 }, nav) do
          Ok(hedge) -> assert(hedge.atoms == 2469135780)
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end

    case expected_funding_usd_micros(UsdMicros { atoms : 500000000 }, RatePpm { atoms : 250 }) do
      Ok(funding) -> assert(funding.atoms == 125000)
      Err(error) -> assert(false)
    end

    case nav_reward_lamports(TokenAtoms { atoms : 2000000000 }, Lamports { atoms : 1235000000 }, Lamports { atoms : 1234000000 }) do
      Ok(reward) -> assert(reward.atoms == 2000000)
      Err(error) -> assert(false)
    end

    case net_carry_usd_micros(UsdMicros { atoms : 125000 }, UsdMicros { atoms : 300000 }, UsdMicros { atoms : 200000 }, UsdMicros { atoms : 50000 }) do
      Ok(net) -> do
        assert(net.atoms == 175000)
        assert(is_entry_eligible(RatePpm { atoms : 250 }, net))
        assert(is_entry_eligible(RatePpm { atoms : 0 }, net) == false)
      end
      Err(error) -> assert(false)
    end
  end
end
