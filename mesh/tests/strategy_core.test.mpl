from Packages.StrategyCore import expected_funding_usd_micros, hedge_lamports, is_entry_eligible, jitosol_nav_lamports, nav_reward_lamports, net_carry_usd_micros

describe("fixed-point strategy core") do
  test("prices JitoSOL carry and rejects non-positive short funding") do
    case jitosol_nav_lamports(12345678900, 10000000000) do
      Ok(nav) -> do
        assert(nav == 1234567890)
        case hedge_lamports(2000000000, nav) do
          Ok(hedge) -> assert(hedge == 2469135780)
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end

    case expected_funding_usd_micros(500000000, 250) do
      Ok(funding) -> assert(funding == 125000)
      Err(error) -> assert(false)
    end

    case nav_reward_lamports(2000000000, 1235000000, 1234000000) do
      Ok(reward) -> assert(reward == 2000000)
      Err(error) -> assert(false)
    end

    case net_carry_usd_micros(125000, 300000, 200000, 50000) do
      Ok(net) -> do
        assert(net == 175000)
        assert(is_entry_eligible(250, net))
        assert(is_entry_eligible(0, net) == false)
      end
      Err(error) -> assert(false)
    end
  end
end
