from Packages.ReplayCli import run_replay_command

describe("replay CLI") do
  test("loads a pinned bundle and rejects malformed arguments") do
    let args = [
      "funding-collector",
      "replay",
      "--bundle",
      "replay/bundles/calm-v1.jsonl",
      "--config",
      "replay/configs/baseline-v1.json"
    ]
    case run_replay_command(
      args,
      "728f534e0500f90a11cbe8184befb711664280de"
    ) do
      Ok(output) -> do
        assert(Json.get(output, "bundle_id") == "calm-v1")
        assert(Json.get(output, "event_count") == "4")
        assert(Json.get(output, "sol_rebalances") == "0")
        assert(Json.get(output, "jitosol_emergencies") == "0")
        assert(Json.get(output, "sol_funding_usd_micros") == "92525")
      end
      Err(error) -> assert(false)
    end
    case run_replay_command(
      ["funding-collector", "replay"],
      "728f534e0500f90a11cbe8184befb711664280de"
    ) do
      Ok(report) -> assert(false)
      Err(error) -> assert(error == "usage: funding-collector replay --bundle <path> --config <path>")
    end
  end
end
