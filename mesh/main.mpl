from Api.Router import build_router
from Packages.BuildIdentity import code_commit, mesh_commit
from Packages.LeaderLease import acquire_startup, release, start_leader_lease_supervisor
from Packages.Log import error, info
from Packages.ReplayCli import run_replay_command
from Packages.RuntimeConfig import RuntimeConfig, load_runtime_config, runtime_config_hash
from Packages.SolanaReadCli import run_native_solana_read
from Packages.Storage import bootstrap_paper_runs, reconcile_paper_state
from Runtime.Registry import start_registry

fn fail_startup(event :: String, fields :: String) do
  error(event, fields)
  Process.exit(1)
end

fn finish_shutdown(pool :: PoolHandle, generation :: Int) do
  case release(pool, generation) do
    Ok(true) -> info(
      "collector_stopped",
      json { leaderGeneration : generation, leaseReleased : true }
    )
    Ok(false) -> do
      Pool.close(pool)
      fail_startup(
        "collector_shutdown_failed",
        json { reason : "writer_lease_not_held" }
      )
    end
    Err(reason) -> do
      Pool.close(pool)
      fail_startup("collector_shutdown_failed", json { reason : reason })
    end
  end
  Pool.close(pool)
end

fn valid_secret(name :: String, local_default :: String, local :: Bool) -> Bool do
  let value = Env.get(name, "")
  String.length(value) > 0 && (
    local || (String.length(value) >= 32 && value != local_default)
  )
end

fn serve(pool :: PoolHandle, port :: Int, config :: RuntimeConfig) do
  case acquire_startup(pool) do
    Ok(0) -> fail_startup(
      "leader_lease_unavailable",
      json { reason : "held_by_another_instance" }
    )
    Ok(generation) -> do
      case (
        config
        |> runtime_config_hash
        |4> bootstrap_paper_runs(
          pool,
          code_commit(),
          mesh_commit(),
          config.target_notional_usd_micros
        )
      ) do
        Ok(rows) -> do
          let reconciliation_id = "reconciliation:startup:" <> Env.get("INSTANCE_ID", "") <> ":${generation}:" <> "${DateTime.utc_now() |> DateTime.to_unix_ms}"
          case (reconciliation_id |2> reconcile_paper_state(
            pool,
            "collector_startup"
          )) do
            Ok("matched") -> do
              start_registry(pool)
              start_leader_lease_supervisor()
              info("collector_started", json {
                mode : "paper",
                port : port,
                bootstrapRows : rows,
                leaderGeneration : generation,
                reconciliation : "matched"
              })
              build_router() |> HTTP.serve(port)
              finish_shutdown(pool, generation)
            end
            Ok("recovery_required") -> do
              start_registry(pool)
              start_leader_lease_supervisor()
              info("collector_started", json {
                mode : "paper",
                port : port,
                bootstrapRows : rows,
                leaderGeneration : generation,
                reconciliation : "recovery_required"
              })
              build_router() |> HTTP.serve(port)
              finish_shutdown(pool, generation)
            end
            Ok(result) -> do
              fail_startup(
                "startup_reconciliation_failed",
                json { result : result }
              )
            end
            Err(reason) -> do
              fail_startup(
                "startup_reconciliation_failed",
                json { reason : reason }
              )
            end
          end
        end
        Err(reason) -> fail_startup(
          "bootstrap_failed",
          json { reason : reason }
        )
      end
    end
    Err(reason) -> fail_startup(
      "leader_lease_unavailable",
      json { reason : reason }
    )
  end
end

fn serve_collector() do
  Process.install_shutdown_signals()
  case load_runtime_config() do
    Err(reason) -> fail_startup(
      "config_invalid",
      json { field : "RUNTIME_CONFIG", reason : reason }
    )
    Ok(config) -> do
      let local = Env.get("DEPLOYMENT_ENVIRONMENT", "local") == "local"
      if valid_secret(
        "ADAPTER_HMAC_SECRET",
        "local-paper-only-change-me",
        local
      ) == false || valid_secret(
        "OPERATOR_HMAC_SECRET",
        "local-operator-only-change-me",
        local
      ) == false do
        return fail_startup(
          "config_invalid",
          json {
            field : "HMAC_SECRET",
            reason : "non-local secrets must contain at least 32 characters and differ from local defaults"
          }
        )
      end
      let database_url = Env.get("DATABASE_URL", "")
      let port = Env.get_int("PORT", 8080)
      if String.length(database_url) == 0 do
        fail_startup("config_invalid", json { field : "DATABASE_URL" })
      else
        case (database_url |> Pool.open(1, 4, 5000)) do
          Ok(pool) -> serve(pool, port, config)
          Err(reason) -> fail_startup(
            "database_connect_failed",
            json { reason : reason }
          )
        end
      end
    end
  end
end

fn replay(args :: List<String>) do
  case run_replay_command(
    args,
    mesh_commit()
  ) do
    Ok(output) -> println(output)
    Err(reason) -> do
      IO.eprintln(reason)
      Process.exit(1)
    end
  end
end

fn solana_read() do
  case Env.get("SOLANA_RPC_URL", "")
    |> run_native_solana_read() do
    Ok(output) -> println(output)
    Err(reason) -> do
      IO.eprintln(reason)
      Process.exit(1)
    end
  end
end

fn main() do
  let args = Env.args()
  if List.length(args) > 1 && List.get(args, 1) == "replay" do
    replay(args)
  else
    if List.length(args) == 2 && List.get(args, 1) == "solana-read" do
      solana_read()
    else
      serve_collector()
    end
  end
end
