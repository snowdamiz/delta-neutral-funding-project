from Api.Router import build_router
from Packages.Log import error, info
from Packages.Storage import bootstrap_paper_runs
from Runtime.Registry import start_registry

fn serve(pool :: PoolHandle, port :: Int) do
  let code_commit = Env.get("CODE_COMMIT", "development")
  let mesh_commit = Env.get("MESH_COMMIT", "aeddc93c493475be0ee843e93c67612dd12346b6")
  let config_hash = Env.get("CONFIG_HASH", "")
  case bootstrap_paper_runs(pool, code_commit, mesh_commit, config_hash) do
    Ok(rows) -> do
      start_registry(pool)
      info("collector_started", "{\"mode\":\"paper\",\"port\":\"${port}\",\"bootstrapRows\":\"${rows}\"}")
      HTTP.serve(build_router(), port)
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
    case Pool.open(database_url, 1, 4, 5000) do
      Ok(pool) -> serve(pool, port)
      Err(reason) -> error("database_connect_failed", "{\"reason\":\"${reason}\"}")
    end
  end
end
