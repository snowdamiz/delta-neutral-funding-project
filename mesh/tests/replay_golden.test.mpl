from Packages.Replay import ReplayReport, run_replay

fn replay(name :: String) -> ReplayReport ! String do
  ((File.read("replay/bundles/${name}-v1.jsonl")) ? |2> run_replay(
    (File.read("replay/configs/baseline-v1.json")) ?,
    "6fdb83afe68703f9459a4e7035b1b84d96316e6b"
  ))
end

describe("golden replay bundles") do
  test("preserves calm and exposes each stress outcome") do
    case replay("calm") do
      Ok(report) -> do
        assert(report.sol_exits == 1)
        assert(report.jitosol_exits == 1)
        assert(report.trace_hash == "4284bb84e784e9ad28c1a2baae1e7762181606b27a044a2a1e5bc32ff0b5002a")
      end
      Err(error) -> assert(false)
    end
    case replay("volatile") do
      Ok(report) -> do
        assert(report.jitosol_rebalances == 1)
        assert(report.jitosol_basis_lamports == -334000000)
        assert(report.trace_hash == "4a2cde515e35d92a02bb722de638258853529c4a7b8732a1c48843e98e44b530")
      end
      Err(error) -> assert(false)
    end
    case replay("liquidity-loss") do
      Ok(report) -> do
        assert(report.sol_emergencies == 0)
        assert(report.jitosol_emergencies == 1)
        assert(report.jitosol_exits == 0)
        assert(report.trace_hash == "83ddc654b3199c724c65a67149261422965751c69e25df9f218f0f51c8cc53e0")
      end
      Err(error) -> assert(false)
    end
    case replay("epoch-boundary") do
      Ok(report) -> do
        assert(report.jitosol_reward_lamports == 2000000)
        assert(report.jitosol_basis_lamports == -2000000)
        assert(report.trace_hash == "11f222a7349bacd1b05cab33b324705f23aa5456144bc99ace2ec3d139c94c22")
      end
      Err(error) -> assert(false)
    end
    case replay("failure") do
      Ok(report) -> do
        assert(report.sol_exits == 1)
        assert(report.jitosol_rebalances == 0)
        assert(report.jitosol_emergencies == 1)
        assert(report.trace_hash == "5ca1c040728222c855fbaf9f5be9b439eca541320c180331aab987ac27361013")
      end
      Err(error) -> assert(false)
    end
  end
end
