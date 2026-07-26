from Packages.Finance import Lamports, UsdMicros
from Packages.RiskEngine import RiskInput, approve_entry

fn healthy() -> RiskInput do
  RiskInput {
    observed_at_ms : 1000,
    now_ms : 1200,
    max_age_ms : 500,
    paused : false,
    oracle_valid : true,
    exit_depth : Lamports { atoms : 3000000000 },
    hedge : Lamports { atoms : 2000000000 },
    net_carry : UsdMicros { atoms : 50000 }
  }
end

describe("entry risk") do
  test("approves fresh liquid carry and rejects stale or paused input") do
    let approved = approve_entry(healthy())
    assert(approved.approved)
    assert(approved.code == "approved")

    let stale = approve_entry(RiskInput {
      observed_at_ms : 1000,
      now_ms : 2000,
      max_age_ms : 500,
      paused : false,
      oracle_valid : true,
      exit_depth : Lamports { atoms : 3000000000 },
      hedge : Lamports { atoms : 2000000000 },
      net_carry : UsdMicros { atoms : 50000 }
    })
    assert(stale.approved == false)
    assert(stale.code == "source_stale")

    let paused = approve_entry(RiskInput {
      observed_at_ms : 1000,
      now_ms : 1200,
      max_age_ms : 500,
      paused : true,
      oracle_valid : true,
      exit_depth : Lamports { atoms : 3000000000 },
      hedge : Lamports { atoms : 2000000000 },
      net_carry : UsdMicros { atoms : 50000 }
    })
    assert(paused.approved == false)
    assert(paused.code == "entries_paused")
  end
end
