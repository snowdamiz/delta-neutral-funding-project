from Api.Router import build_router
from Packages.Log import error, info
from Packages.Storage import bootstrap_paper_runs
from Runtime.Registry import start_registry

fn serve(pool :: PoolHandle, port :: Int) do
  let code_commit = Env.get("CODE_COMMIT", "development")
  let mesh_commit = Env.get("MESH_COMMIT", "0dcb8989c5aa9fac539322054cd47c7db6799765")
  let config_hash = Env.get("CONFIG_HASH", "")
  case (config_hash |4> bootstrap_paper_runs(pool, code_commit, mesh_commit)) do
    Ok(rows) -> do
      start_registry(pool)
      info("collector_started", "{\"mode\":\"paper\",\"port\":\"${port}\",\"bootstrapRows\":\"${rows}\"}")
      build_router() |> HTTP.serve(port)
    end
    Err(reason) -> error("bootstrap_failed", "{\"reason\":\"${reason}\"}")
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
