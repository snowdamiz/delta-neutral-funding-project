from Api.Router import build_router
from Packages.LeaderLease import acquire_startup, start_leader_lease_supervisor
from Packages.Log import error, info
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
          Env.get("MESH_COMMIT", "7cc1cfadcc7c270d0a82bb0dfa955ffb5ea12279")
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

fn main() do
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
