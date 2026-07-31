from Packages.Replay import ReplayReport, run_replay

fn replay(name :: String) -> ReplayReport ! String do
  ((File.read("replay/bundles/${name}-v1.jsonl")) ? |2> run_replay(
    (File.read("replay/configs/baseline-v1.json")) ?,
    "c5379f8d00990df18248e4bf2d53bbb1d04868fb"
  ))
end

describe("golden replay bundles") do
  test("preserves calm and exposes each stress outcome") do
    case replay("calm") do
      Ok(report) -> do
        assert(report.sol_exits == 1)
        assert(report.jitosol_exits == 1)
        assert(report.trace_hash == "776326623977543dd62d3f845b78fbbdfa9c1e27b81676899153611de0805aee")
      end
      Err(error) -> assert(false)
    end
    case replay("volatile") do
      Ok(report) -> do
        assert(report.jitosol_rebalances == 1)
        assert(report.jitosol_basis_lamports == -334000000)
        assert(report.trace_hash == "0d7702e8459a9f1ea15e960e1b02a1381401734f6ff0f54f531bc1b8ebde4bef")
      end
      Err(error) -> assert(false)
    end
    case replay("liquidity-loss") do
      Ok(report) -> do
        assert(report.sol_emergencies == 0)
        assert(report.jitosol_emergencies == 1)
        assert(report.jitosol_exits == 0)
        assert(report.trace_hash == "3f4dea289929a339ed544d2a145acffa65e768b21c0cab910bd375946c1d6a0b")
      end
      Err(error) -> assert(false)
    end
    case replay("doubled-costs") do
      Ok(report) -> do
        assert(report.sol_execution_fees_usd_micros == 1332362)
        assert(report.jitosol_execution_fees_usd_micros == 1332762)
        assert(report.trace_hash == "1c98a9c25c0d981e88e8fd05558641f9d5eaf2e2596847757b506f4ffe9f73d9")
      end
      Err(error) -> assert(false)
    end
    case replay("epoch-boundary") do
      Ok(report) -> do
        assert(report.jitosol_reward_lamports == 2000000)
        assert(report.jitosol_basis_lamports == -2000000)
        assert(report.trace_hash == "5638bfeafb8c50517fc1f2fc0b09576ef139e1ad9fdfa389ae80c7f2b6e2336e")
      end
      Err(error) -> assert(false)
    end
    case replay("failure") do
      Ok(report) -> do
        assert(report.sol_exits == 1)
        assert(report.jitosol_rebalances == 0)
        assert(report.jitosol_emergencies == 1)
        assert(report.trace_hash == "b2d2eceade8ef89aa0389ad3c8eaca62797551fe26156905ef4f84180748a8dd")
      end
      Err(error) -> assert(false)
    end
  end
end
