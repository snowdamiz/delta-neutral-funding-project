from Packages.BrokerPaper import FillStatus, OrderSide, PaperOrder, sample_failure, simulate_fill
from Packages.Finance import PriceMicros, QuantityAtoms, RatePpm

fn order(side :: OrderSide, fill_rate :: Int) -> PaperOrder do
  PaperOrder {
    side : side,
    quantity : QuantityAtoms { atoms : 1000000000 },
    quantity_scale : 1000000000,
    quoted_price : PriceMicros { atoms : 150000000 },
    fill_rate : RatePpm { atoms : fill_rate },
    slippage_rate : RatePpm { atoms : 1000 },
    fee_rate : RatePpm { atoms : 500 }
  }
end

describe("deterministic paper broker") do
  test("models a partial buy at its adverse executable price") do
    case simulate_fill(order(Buy, 750000)) do
      Ok(fill) -> do
        case fill.status do
          Partial -> assert(true)
          _ -> assert(false)
        end
        assert(fill.filled_quantity.atoms == 750000000)
        assert(fill.average_price.atoms == 150150000)
        assert(fill.gross_usd.atoms == 112612500)
        assert(fill.fee_usd.atoms == 56307)
      end
      Err(error) -> assert(false)
    end
  end

  test("models a sell at its adverse executable price") do
    case simulate_fill(order(Sell, 1000000)) do
      Ok(fill) -> assert(fill.average_price.atoms == 149850000)
      Err(error) -> assert(false)
    end
  end

  test("repeats failure draws from the same seed") do
    case sample_failure(Random.seed(42), RatePpm { atoms : 100000 }, RatePpm { atoms : 100000 }) do
      Ok(first) -> case sample_failure(Random.seed(42), RatePpm { atoms : 100000 }, RatePpm { atoms : 100000 }) do
        Ok(repeated) -> do
          assert(first.random_state == repeated.random_state)
          assert(first.draw_ppm == repeated.draw_ppm)
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end
end
