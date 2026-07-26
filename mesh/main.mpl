from Api.Router import build_router
from Packages.LeaderLease import acquire_startup, start_leader_lease_supervisor
from Packages.Log import error, info
from Packages.ReplayCli import run_replay_command
from Packages.Storage import bootstrap_paper_runs
from Runtime.Registry import start_registry

fn serve(pool :: PoolHandle, port :: Int) do
  case acquire_startup(pool) do
    Ok(0) -> error("leader_lease_unavailable", "{\"reason\":\"held_by_another_instance\"}")
    Ok(generation) -> do
      case (
        Env.get("CONFIG_HASH", "")
        |4> bootstrap_paper_runs(
          pool,
          Env.get("CODE_COMMIT", "development"),
          Env.get("MESH_COMMIT", "105b55e1029ceba615161901c84d08a9a64885ea")
        )
      ) do
        Ok(rows) -> do
          start_registry(pool)
          start_leader_lease_supervisor()
          info("collector_started", "{\"mode\":\"paper\",\"port\":\"${port}\",\"bootstrapRows\":\"${rows}\",\"leaderGeneration\":\"${generation}\"}")
          build_router() |> HTTP.serve(port)
        end
        Err(reason) -> error("bootstrap_failed", "{\"reason\":\"${reason}\"}")
      end
    end
    Err(reason) -> error("leader_lease_unavailable", "{\"reason\":\"${reason}\"}")
  end
end

fn serve_collector() do
  Process.install_shutdown_signals()
  let database_url = Env.get("DATABASE_URL", "")
  let port = Env.get_int("PORT", 8080)
  if String.length(database_url) == 0 do
    error("config_invalid", "{\"field\":\"DATABASE_URL\"}")
  else
    case (database_url |> Pool.open(1, 4, 5000)) do
      Ok(pool) -> serve(pool, port)
      Err(reason) -> error("database_connect_failed", "{\"reason\":\"${reason}\"}")
    end
  end
end

fn replay(args :: List<String>) do
  case run_replay_command(
    args,
    Env.get("MESH_COMMIT", "105b55e1029ceba615161901c84d08a9a64885ea")
  ) do
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
    serve_collector()
  end
end
