from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros, apply_rate, lamports_ratio, token_value_lamports, usd_add, usd_sub

describe("nominal fixed-point finance") do
  test("keeps units distinct while using checked wide intermediates") do
    let pool = Lamports { atoms : 12345678900 }
    let supply = TokenAtoms { atoms : 10000000000 }
    let position = TokenAtoms { atoms : 2000000000 }
    let notional = UsdMicros { atoms : 500000000 }
    let funding_rate = RatePpm { atoms : 250 }

    case lamports_ratio(pool, supply, :floor) do
      Ok(nav) -> do
        assert(nav.atoms == 1234567890)
        case token_value_lamports(position, nav, :half_even) do
          Ok(hedge) -> assert(hedge.atoms == 2469135780)
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end

    case apply_rate(notional, funding_rate, :toward_zero) do
      Ok(funding) -> do
        assert(funding.atoms == 125000)
        case usd_add(funding, UsdMicros { atoms : 50000 }) do
          Ok(gross) -> do
            case usd_sub(gross, UsdMicros { atoms : 25000 }) do
              Ok(net) -> assert(net.atoms == 150000)
              Err(error) -> assert(false)
            end
          end
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end
  end
end
