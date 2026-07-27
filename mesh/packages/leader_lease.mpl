from Packages.Log import error
from Runtime.Registry import get_pool

fn holder_id() -> String do
  Env.get("INSTANCE_ID", "")
end

fn lease_ttl_ms() -> Int do
  Env.get_int("LEADER_LEASE_MS", 10000)
end

fn renew_interval_ms() -> Int do
  Env.get_int("LEADER_RENEW_MS", 3000)
end

fn required_generation(rows) -> Int ! String do
  if List.length(rows) != 1 do
    return Err("database returned an invalid leader lease result")
  end
  case String.to_int(Map.get(List.head(rows), "generation")) do
    Some(generation) -> Ok(generation)
    None -> Err("database returned an invalid leader lease generation")
  end
end

fn acquire(pool :: PoolHandle) -> Int ! String do
  Pool.query(pool, "SELECT acquire_collector_lease($1, $2::int)::text AS generation", [
    holder_id(),
    "${lease_ttl_ms()}"
  ]) ?
    |> required_generation
end

fn held_generation(pool :: PoolHandle) -> Int ! String do
  Pool.query(pool, "SELECT generation::text FROM leader_leases WHERE lease_name = 'collector' AND holder_instance_id = $1 AND expires_at > clock_timestamp()", [
    holder_id()
  ]) ?
    |> required_generation
end

fn renew(pool :: PoolHandle, generation :: Int) -> Bool ! String do
  let rows = Pool.query(pool, "SELECT renew_collector_lease($1, $2::bigint, $3::int)::text AS renewed", [
    holder_id(),
    "${generation}",
    "${lease_ttl_ms()}"
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid leader lease renewal result")
  else
    Ok(Map.get(List.head(rows), "renewed") == "true")
  end
end

pub fn acquire_startup(pool :: PoolHandle) -> Int ! String do
  if String.length(holder_id()) == 0 do
    return Err("INSTANCE_ID is required")
  end
  if renew_interval_ms() <= 0 || renew_interval_ms() >= lease_ttl_ms() do
    return Err("LEADER_RENEW_MS must be positive and less than LEADER_LEASE_MS")
  end
  acquire(pool)
end

pub fn lease_held(pool :: PoolHandle) -> Bool ! String do
  let rows = Pool.query(pool, "SELECT collector_lease_held($1)::text AS held", [
    holder_id()
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid leader lease status")
  else
    Ok(Map.get(List.head(rows), "held") == "true")
  end
end

pub fn release(pool :: PoolHandle, generation :: Int) -> Bool ! String do
  let rows = ("SELECT release_collector_lease($1, $2::bigint)::text AS released"
    |2> Pool.query(pool, [holder_id(), "${generation}"])) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid leader lease release result")
  else
    Ok(Map.get(List.head(rows), "released") == "true")
  end
end

fn fail_closed(pool :: PoolHandle, generation :: Int, reason :: String) do
  case Pool.query(pool, "SELECT fail_closed_for_lease_loss($1, $2::bigint)::text AS version", [
    holder_id(),
    "${generation}"
  ]) do
    Ok(_rows) -> error("leader_lease_lost", json { reason : reason })
    Err(database_error) -> error(
      "leader_lease_fail_close_failed",
      json { reason : database_error }
    )
  end
end

fn renewal_loop(previous_generation :: Int) -> Int do
  Timer.sleep(renew_interval_ms())
  if Process.shutdown_requested() do
    0
  else
    let pool = get_pool()
    case renew(pool, previous_generation) do
      Ok(true) -> renewal_loop(previous_generation)
      Ok(false) -> do
        fail_closed(
          pool,
          previous_generation,
          "lease_expired_or_fenced"
        )
        0
      end
      Err(reason) -> do
        fail_closed(pool, previous_generation, reason)
        0
      end
    end
  end
end

actor leader_lease_worker() do
  let pool = get_pool()
  case held_generation(pool) do
    Ok(generation) -> renewal_loop(generation)
    Err(reason) -> do
      fail_closed(pool, 0, reason)
      0
    end
  end
end

supervisor LeaderLeaseSupervisor do
  strategy: one_for_one
  max_restarts: 3
  max_seconds: 30

  child renewal do
    start: fn -> spawn(leader_lease_worker) end
    restart: transient
    shutdown: 5000
  end
end

pub fn start_leader_lease_supervisor() do
  spawn(LeaderLeaseSupervisor)
end
