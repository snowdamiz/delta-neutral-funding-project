from Packages.Finance import Lamports, PriceMicros, RatePpm, TokenAtoms, UsdMicros
from Packages.Opportunity import evaluate_snapshot
from Packages.PaperEngine import EntryOutcome, LegFill, PaperAction, PaperPlan, PaperPosition, PaperRuntime, PaperVariant, plan_entry, plan_forced_exit, plan_position
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
    collateral_usd_micros : UsdMicros { atoms : 200000000 },
    maintenance_requirement_usd_micros : UsdMicros { atoms : 50000000 },
    liquidation_distance_bps : 5000,
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

fn runtime(state :: PortfolioState, now_ms :: Int) -> PaperRuntime do
  PaperRuntime {
    now_ms : now_ms,
    max_age_ms : 5000,
    paused : false,
    pause_all : false,
    minimum_margin_ratio_ppm : 1500000,
    minimum_liquidation_distance_bps : 1000,
    rebalance_delta_bps : 50,
    state : state,
    state_version : if state == Idle do 0 else 4 end,
    random_state : Random.seed(42)
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
        runtime(Idle, 1785024001000)) do
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
        runtime(Idle, 1785024001000)) do
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
      runtime(Idle, 1785024001000)) do
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
      runtime(Idle, 1785024001000)) do
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
      runtime(Hedged, 1785024001000)) do
        Ok(plan) -> do
          assert(plan.outcome == EntrySkipped)
          assert(plan.reason == "portfolio_not_idle")
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end

  test("attributes JitoSOL value, rehedges drift, and exits perp first") do
    let current = snapshot(OracleValid, 1000000, 0)
    case evaluate_snapshot(current) do
      Ok(opportunity) -> do
        case plan_position(current,
        opportunity,
        PaperPosition {
          variant : JitoSolCarry,
          spot_quantity : TokenAtoms { atoms : 2000000000 },
          perp_short_quantity : Lamports { atoms : 2400000000 },
          prior_nav_lamports : Lamports { atoms : 1234000000 },
          prior_market_rate_lamports : Lamports { atoms : 1233000000 },
          state_version : 4,
          random_state : Random.seed(42)
        },
        runtime(Hedged, 1785024001000)) do
          Ok(plan) -> do
            assert(plan.action == RebalancePerp)
            assert(plan.next_state == Hedged)
            assert(plan.perp_fill.placed)
            assert(plan.valuation.reward_sol_lamports.atoms == 1135780)
            assert(plan.valuation.reward_sol_lamports.atoms + plan.valuation.basis_sol_lamports.atoms == 1333332)
          end
          Err(error) -> assert(false)
        end

        let unsafe = snapshot(OracleInvalid, 1000000, 0)
        case plan_position(unsafe,
        opportunity,
        PaperPosition {
          variant : SolControl,
          spot_quantity : TokenAtoms { atoms : 1000000000 },
          perp_short_quantity : Lamports { atoms : 1000000000 },
          prior_nav_lamports : Lamports { atoms : 1000000000 },
          prior_market_rate_lamports : Lamports { atoms : 1000000000 },
          state_version : 4,
          random_state : Random.seed(42)
        },
        runtime(Hedged, 1785024001000)) do
          Ok(plan) -> do
            assert(plan.action == ExitPosition)
            assert(plan.next_state == Idle)
            assert(plan.perp_fill.placed)
            assert(plan.spot_fill.placed)
          end
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end
  end

  test("flattens the short and stops when JitoSOL exit depth disappears") do
    let shallow = %{snapshot(OracleValid, 1000000, 0) |
      jitosol_exit_depth_lamports : Lamports { atoms : 0 }
    }
    case evaluate_snapshot(shallow) do
      Ok(opportunity) -> case plan_position(
        shallow,
        opportunity,
        PaperPosition {
          variant : JitoSolCarry,
          spot_quantity : TokenAtoms { atoms : 2000000000 },
          perp_short_quantity : Lamports { atoms : 2467333332 },
          prior_nav_lamports : Lamports { atoms : 1234567890 },
          prior_market_rate_lamports : Lamports { atoms : 1233666666 },
          state_version : 4,
          random_state : Random.seed(42)
        },
        runtime(Hedged, 1785024001000)
      ) do
        Ok(plan) -> do
          assert(plan.action == EmergencyPosition)
          assert(plan.reason == "paper_spot_close_partial")
          assert(plan.next_perp_short_quantity.atoms == 0)
          assert(plan.next_spot_quantity.atoms == 2000000000)
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end

  test("does not act on a stale position snapshot") do
    let stale = %{snapshot(OracleValid, 1000000, 0) |
      observed_at_ms : 1785024000000
    }
    case evaluate_snapshot(stale) do
      Ok(opportunity) -> case plan_position(
        stale,
        opportunity,
        PaperPosition {
          variant : SolControl,
          spot_quantity : TokenAtoms { atoms : 1000000000 },
          perp_short_quantity : Lamports { atoms : 900000000 },
          prior_nav_lamports : Lamports { atoms : 1000000000 },
          prior_market_rate_lamports : Lamports { atoms : 1000000000 },
          state_version : 4,
          random_state : Random.seed(42)
        },
        runtime(Hedged, 1785024010000)
      ) do
        Ok(plan) -> do
          assert(plan.action == HoldPosition)
          assert(plan.reason == "source_stale")
          assert(plan.perp_fill.placed == false)
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end

  test("exits a position inside the liquidation distance limit") do
    let unsafe = %{snapshot(OracleValid, 1000000, 0) |
      liquidation_distance_bps : 999
    }
    case evaluate_snapshot(unsafe) do
      Ok(opportunity) -> case plan_position(
        unsafe,
        opportunity,
        PaperPosition {
          variant : SolControl,
          spot_quantity : TokenAtoms { atoms : 1000000000 },
          perp_short_quantity : Lamports { atoms : 1000000000 },
          prior_nav_lamports : Lamports { atoms : 1000000000 },
          prior_market_rate_lamports : Lamports { atoms : 1000000000 },
          state_version : 4,
          random_state : Random.seed(42)
        },
        runtime(Hedged, 1785024001000)
      ) do
        Ok(plan) -> do
          assert(plan.action == ExitPosition)
          assert(plan.reason == "liquidation_distance_below_minimum")
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end

  test("preserves an authenticated operator reason on a forced exit") do
    let current = snapshot(OracleValid, 1000000, 0)
    case evaluate_snapshot(current) do
      Ok(opportunity) -> case plan_forced_exit(
        current,
        opportunity,
        PaperPosition {
          variant : SolControl,
          spot_quantity : TokenAtoms { atoms : 1000000000 },
          perp_short_quantity : Lamports { atoms : 1000000000 },
          prior_nav_lamports : Lamports { atoms : 1000000000 },
          prior_market_rate_lamports : Lamports { atoms : 1000000000 },
          state_version : 4,
          random_state : Random.seed(42)
        },
        "operator_exit:test"
      ) do
        Ok(plan) -> do
          assert(plan.action == ExitPosition)
          assert(plan.next_state == Idle)
          assert(plan.reason == "operator_exit:test")
        end
        Err(error) -> assert(false)
      end
      Err(error) -> assert(false)
    end
  end
end
