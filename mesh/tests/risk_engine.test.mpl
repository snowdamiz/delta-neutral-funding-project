from Packages.Finance import Lamports, UsdMicros
from Packages.RiskEngine import MarginInput, RiskInput, approve_entry

fn healthy() -> RiskInput do
  RiskInput {
    observed_at_ms : 1000,
    now_ms : 1200,
    max_age_ms : 500,
    paused : false,
    oracle_valid : true,
    exit_depth : Lamports { atoms : 3000000000 },
    hedge : Lamports { atoms : 2000000000 },
    net_carry : UsdMicros { atoms : 50000 },
    margin : MarginInput {
      collateral_usd_micros : UsdMicros { atoms : 200000000 },
      maintenance_requirement_usd_micros : UsdMicros { atoms : 50000000 },
      minimum_margin_ratio_ppm : 1500000,
      liquidation_distance_bps : 5000,
      minimum_liquidation_distance_bps : 1000
    }
  }
end

describe("entry risk") do
  test("approves fresh liquid carry and rejects stale or paused input") do
    let approved = approve_entry(healthy())
    assert(approved.approved)
    assert(approved.code == "approved")

    let stale = approve_entry(%{healthy() | now_ms : 2000})
    assert(stale.approved == false)
    assert(stale.code == "source_stale")

    let paused = approve_entry(%{healthy() | paused : true})
    assert(paused.approved == false)
    assert(paused.code == "entries_paused")

    let base = healthy()
    let margin = approve_entry(%{base |
      margin : %{base.margin |
        collateral_usd_micros : UsdMicros { atoms : 70000000 }
      }
    })
    assert(margin.approved == false)
    assert(margin.code == "margin_ratio_below_minimum")
  end
end
