from Packages.Replay import ReplayReport, run_replay

fn replay(name :: String) -> ReplayReport ! String do
  ((File.read("replay/bundles/${name}-v1.jsonl")) ? |2> run_replay(
    (File.read("replay/configs/baseline-v1.json")) ?,
    "c5c75c405e4141eb2dc5a25e8ed638b75ccbd8c9"
  ))
end

describe("golden replay bundles") do
  test("preserves calm and exposes each stress outcome") do
    case replay("calm") do
      Ok(report) -> do
        assert(report.sol_exits == 1)
        assert(report.jitosol_exits == 1)
        assert(report.trace_hash == "958bc37dcf2056845805e07965411bc82f3d07551c84387708fa1b1cfa3c6d2b")
      end
      Err(error) -> assert(false)
    end
    case replay("volatile") do
      Ok(report) -> do
        assert(report.jitosol_rebalances == 1)
        assert(report.jitosol_basis_lamports == -334000000)
        assert(report.trace_hash == "0da7b7d82558228ddf246bd46755febd74ba15babb26a7222b6112a4cfc9cc8d")
      end
      Err(error) -> assert(false)
    end
    case replay("liquidity-loss") do
      Ok(report) -> do
        assert(report.sol_emergencies == 0)
        assert(report.jitosol_emergencies == 1)
        assert(report.jitosol_exits == 0)
        assert(report.trace_hash == "8d1d3a027f0bbd2f1751e79c8fe420fed6a981d216dc74bd0ac37becc728c10b")
      end
      Err(error) -> assert(false)
    end
    case replay("doubled-costs") do
      Ok(report) -> do
        assert(report.sol_execution_fees_usd_micros == 1332362)
        assert(report.jitosol_execution_fees_usd_micros == 1332762)
        assert(report.trace_hash == "683a8f2306d27d778bb87860e452c4bc284ab36655f9625b3a9fbd9a25b10f3a")
      end
      Err(error) -> assert(false)
    end
    case replay("epoch-boundary") do
      Ok(report) -> do
        assert(report.jitosol_reward_lamports == 2000000)
        assert(report.jitosol_basis_lamports == -2000000)
        assert(report.trace_hash == "8c0383435ce507a86ddb296a853c20585661c84ff0a2c0139f379c8ba21266b0")
      end
      Err(error) -> assert(false)
    end
    case replay("failure") do
      Ok(report) -> do
        assert(report.sol_exits == 1)
        assert(report.jitosol_rebalances == 0)
        assert(report.jitosol_emergencies == 1)
        assert(report.trace_hash == "0d756f74ae845ce17d17b90d49f9a965d80c94c73bd8a0d8e2f73f2873cc252f")
      end
      Err(error) -> assert(false)
    end
  end
end
