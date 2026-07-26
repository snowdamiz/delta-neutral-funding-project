struct RegistryState do
  pool :: PoolHandle
  accepted_events :: Int
  rejected_events :: Int
end

service CollectorRegistry do
  fn init(pool :: PoolHandle) -> RegistryState do
    RegistryState { pool : pool, accepted_events : 0, rejected_events : 0 }
  end

  call GetPool() :: PoolHandle do|state|
    (state, state.pool)
  end

  call AcceptedEvents() :: Int do|state|
    (state, state.accepted_events)
  end

  call RejectedEvents() :: Int do|state|
    (state, state.rejected_events)
  end

  cast RecordAccepted() do|state|
    RegistryState {
      pool : state.pool,
      accepted_events : state.accepted_events + 1,
      rejected_events : state.rejected_events
    }
  end

  cast RecordRejected() do|state|
    RegistryState {
      pool : state.pool,
      accepted_events : state.accepted_events,
      rejected_events : state.rejected_events + 1
    }
  end
end

pub fn start_registry(pool :: PoolHandle) do
  let pid = CollectorRegistry.start(pool)
  Process.register("funding_collector_registry", pid)
  pid
end

fn registry_pid() do
  Process.whereis("funding_collector_registry")
end

pub fn get_pool() do
  CollectorRegistry.get_pool(registry_pid())
end

pub fn record_accepted() do
  CollectorRegistry.record_accepted(registry_pid())
end

pub fn record_rejected() do
  CollectorRegistry.record_rejected(registry_pid())
end

pub fn accepted_events() -> Int do
  CollectorRegistry.accepted_events(registry_pid())
end

pub fn rejected_events() -> Int do
  CollectorRegistry.rejected_events(registry_pid())
end

