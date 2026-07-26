from Packages.Finance import Lamports, PriceMicros, RatePpm, TokenAtoms, UsdMicros
from Packages.Opportunity import evaluate_snapshot
from Packages.PaperEngine import EntryOutcome, LegFill, PaperPlan, PaperRuntime, PaperVariant, plan_entry
from Packages.ProtocolContracts import MarketSnapshot, OracleStatus
from Packages.StateMachine import PortfolioState

fn snapshot(oracle_status :: OracleStatus, fill_rate :: Int, reject_rate :: Int) -> MarketSnapshot do
  MarketSnapshot {
    event_id : "event-1",
    source : "test",
    observed_at_ms : 1785024000000,
    source_slot : 320000001,
    source_sequence : "1",
    idempotency_key : "test:1",
    raw_payload_hash : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    oracle_status : oracle_status,
    total_pool_lamports : Lamports { atoms : 12345678900 },
    supply_atoms : TokenAtoms { atoms : 10000000000 },
    jitosol_atoms : TokenAtoms { atoms : 2000000000 },
    notional_usd_micros : UsdMicros { atoms : 500000000 },
    short_receipt_ppm : RatePpm { atoms : 250 },
    sol_price_usd_micros : UsdMicros { atoms : 150000000 },
    prior_nav_lamports : Lamports { atoms : 1234000000 },
    costs_usd_micros : UsdMicros { atoms : 10000 },
    risk_haircut_usd_micros : UsdMicros { atoms : 5000 },
    sol_spot_bid_price_usd_micros : PriceMicros { atoms : 149950000 },
    sol_spot_ask_price_usd_micros : PriceMicros { atoms : 150050000 },
    jitosol_spot_bid_price_usd_micros : PriceMicros { atoms : 185050000 },
    jitosol_spot_ask_price_usd_micros : PriceMicros { atoms : 185250000 },
    perp_bid_price_usd_micros : PriceMicros { atoms : 149980000 },
    perp_ask_price_usd_micros : PriceMicros { atoms : 150020000 },
    sol_exit_depth_lamports : Lamports { atoms : 50000000000 },
    jitosol_exit_depth_lamports : Lamports { atoms : 30000000000 },
    perp_exit_depth_lamports : Lamports { atoms : 100000000000 },
    fill_rate_ppm : RatePpm { atoms : fill_rate },
    slippage_ppm : RatePpm { atoms : 500 },
    spot_fee_ppm : RatePpm { atoms : 500 },
    perp_fee_ppm : RatePpm { atoms : 400 },
    reject_rate_ppm : RatePpm { atoms : reject_rate },
    unknown_rate_ppm : RatePpm { atoms : 0 }
  }
end

describe("paper entry planner") do
  test("hedges both variants in spot-first order and stops partial spot entry") do
    let full = snapshot(OracleValid, 1000000, 0)
    case evaluate_snapshot(full) do
      Ok( opportunity) -> do
        case plan_entry(full,
        opportunity,
        JitoSolCarry,
        PaperRuntime {
          now_ms : 1785024001000,
          max_age_ms : 5000,
          paused : false,
          state : Idle,
          state_version : 0,
          random_state : Random.seed(42)
        }) do
          Ok( plan) -> do
            assert(plan.outcome == EntryHedged)
            assert(plan.next_state == Hedged)
            assert(plan.spot_asset == "JitoSOL")
            assert(plan.perp_fill.placed)
            assert(plan.perp_fill.filled_quantity.atoms == opportunity.hedge_lamports.atoms)
          end
          Err( error) -> assert(false)
        end
        let partial = snapshot(OracleValid, 500000, 0)
        case plan_entry(partial,
        opportunity,
        SolControl,
        PaperRuntime {
          now_ms : 1785024001000,
          max_age_ms : 5000,
          paused : false,
          state : Idle,
          state_version : 0,
          random_state : Random.seed(42)
        }) do
          Ok( plan) -> do
            assert(plan.outcome == EntryPartial)
            assert(plan.next_state == OpeningSpot)
            assert(plan.perp_fill.placed == false)
          end
          Err( error) -> assert(false)
        end
      end
      Err( error) -> assert(false)
    end
  end
  test("fails closed on an invalid oracle") do
    let invalid = snapshot(OracleInvalid, 1000000, 0)
    case evaluate_snapshot(invalid) do
      Ok( opportunity) -> case plan_entry(invalid,
      opportunity,
      SolControl,
      PaperRuntime {
        now_ms : 1785024001000,
        max_age_ms : 5000,
        paused : false,
        state : Idle,
        state_version : 0,
        random_state : Random.seed(42)
      }) do
        Ok( plan) -> do
          assert(plan.outcome == EntrySkipped)
          assert(plan.reason == "oracle_invalid")
        end
        Err( error) -> assert(false)
      end
      Err( error) -> assert(false)
    end
  end

  test("enters emergency state when the spot order is rejected") do
    let rejected = snapshot(OracleValid, 1000000, 1000000)
    case evaluate_snapshot(rejected) do
      Ok(opportunity) -> case plan_entry(rejected,
      opportunity,
      SolControl,
      PaperRuntime {
        now_ms : 1785024001000,
        max_age_ms : 5000,
        paused : false,
        state : Idle,
        state_version : 0,
        random_state : Random.seed(42)
      }) do
        Ok(plan) -> do
          assert(plan.outcome == EntryRejected)
          assert(plan.next_state == EmergencyFlatten)
          assert(plan.spot_fill.placed == false)
          assert(plan.perp_fill.placed == false)
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end

  test("does not reopen a portfolio that has left idle") do
    let full = snapshot(OracleValid, 1000000, 0)
    case evaluate_snapshot(full) do
      Ok(opportunity) -> case plan_entry(full,
      opportunity,
      SolControl,
      PaperRuntime {
        now_ms : 1785024001000,
        max_age_ms : 5000,
        paused : false,
        state : Hedged,
        state_version : 4,
        random_state : Random.seed(42)
      }) do
        Ok(plan) -> do
          assert(plan.outcome == EntrySkipped)
          assert(plan.reason == "portfolio_not_idle")
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end
end
