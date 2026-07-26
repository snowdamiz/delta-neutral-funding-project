CREATE TABLE schema_meta (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO schema_meta(version) VALUES (1);

CREATE TYPE execution_mode AS ENUM ('paper', 'shadow', 'live');
CREATE TYPE strategy_variant AS ENUM ('sol_control', 'jitosol_carry');
CREATE TYPE portfolio_state AS ENUM (
  'idle', 'entering_spot', 'entering_perp', 'hedged', 'rebalancing',
  'exiting', 'paused', 'reconciling', 'error'
);

CREATE TABLE build_manifests (
  id text PRIMARY KEY,
  code_commit text NOT NULL,
  mesh_commit text NOT NULL,
  schema_version integer NOT NULL,
  config_hash char(64) NOT NULL,
  built_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE normalized_events (
  id text PRIMARY KEY,
  schema_version integer NOT NULL CHECK (schema_version = 1),
  event_type text NOT NULL,
  source text NOT NULL,
  observed_at_ms bigint NOT NULL CHECK (observed_at_ms >= 0),
  source_sequence text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  raw_payload_hash char(64) NOT NULL,
  canonical_payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX normalized_events_source_time
  ON normalized_events(source, event_type, observed_at_ms DESC);

CREATE TABLE strategy_runs (
  id text PRIMARY KEY,
  execution_mode execution_mode NOT NULL,
  config_hash char(64) NOT NULL,
  build_manifest_id text REFERENCES build_manifests(id),
  prng_seed bigint NOT NULL,
  prng_version text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  stopped_at timestamptz
);

CREATE TABLE portfolio_runs (
  id text PRIMARY KEY,
  strategy_run_id text NOT NULL REFERENCES strategy_runs(id),
  variant strategy_variant NOT NULL,
  execution_mode execution_mode NOT NULL,
  state portfolio_state NOT NULL DEFAULT 'idle',
  state_version bigint NOT NULL DEFAULT 0 CHECK (state_version >= 0),
  initial_capital_usd_micros bigint NOT NULL CHECK (initial_capital_usd_micros >= 0),
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  UNIQUE (strategy_run_id, variant)
);

CREATE TABLE opportunity_decisions (
  id text PRIMARY KEY,
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  variant strategy_variant NOT NULL,
  observed_at_ms bigint NOT NULL,
  nav_lamports text NOT NULL,
  hedge_lamports text NOT NULL,
  expected_funding_usd_micros text NOT NULL,
  nav_reward_usd_micros text NOT NULL,
  net_carry_usd_micros text NOT NULL,
  eligible boolean NOT NULL,
  reason_code text NOT NULL,
  config_hash char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_event_id, variant)
);
CREATE INDEX opportunity_decisions_latest
  ON opportunity_decisions(observed_at_ms DESC, variant);

CREATE TABLE state_transitions (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  from_state portfolio_state NOT NULL,
  to_state portfolio_state NOT NULL,
  state_version bigint NOT NULL CHECK (state_version >= 0),
  reason text NOT NULL,
  source_event_id text REFERENCES normalized_events(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (portfolio_run_id, state_version)
);

CREATE TABLE execution_intents (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  execution_mode execution_mode NOT NULL,
  variant strategy_variant NOT NULL,
  state_version bigint NOT NULL CHECK (state_version >= 0),
  operation text NOT NULL CHECK (operation IN ('OPEN', 'REBALANCE', 'CLOSE', 'EMERGENCY_FLATTEN')),
  leg text NOT NULL CHECK (leg IN ('SPOT', 'PERP')),
  intent_json jsonb NOT NULL,
  intent_hash char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id text PRIMARY KEY,
  intent_id text NOT NULL REFERENCES execution_intents(id),
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  execution_mode execution_mode NOT NULL,
  variant strategy_variant NOT NULL,
  status text NOT NULL,
  external_id text,
  chain_signature text,
  requested_quantity_atoms text NOT NULL,
  filled_quantity_atoms text NOT NULL DEFAULT '0',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (execution_mode = 'live' OR chain_signature IS NULL)
);
CREATE UNIQUE INDEX orders_external_id
  ON orders(external_id) WHERE external_id IS NOT NULL;

CREATE TABLE fills (
  id text PRIMARY KEY,
  order_id text NOT NULL REFERENCES orders(id),
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  execution_mode execution_mode NOT NULL,
  variant strategy_variant NOT NULL,
  quantity_atoms text NOT NULL,
  price_atoms text NOT NULL,
  fee_atoms text NOT NULL,
  source_snapshot_id text NOT NULL REFERENCES normalized_events(id),
  explanation jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE funding_payments (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  venue_payment_id text NOT NULL,
  effective_at_ms bigint NOT NULL,
  position_quantity_atoms text NOT NULL,
  raw_rate_atoms text NOT NULL,
  normalized_rate_atoms text NOT NULL,
  amount_atoms text NOT NULL,
  usd_value_atoms text NOT NULL,
  realization_status text NOT NULL,
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  UNIQUE (portfolio_run_id, venue_payment_id)
);

CREATE TABLE valuation_events (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  source_event_id text NOT NULL REFERENCES normalized_events(id),
  quantity_atoms text NOT NULL,
  protocol_nav_rate_atoms text NOT NULL,
  market_sell_rate_atoms text NOT NULL,
  reward_accrual_sol_atoms text NOT NULL,
  basis_change_sol_atoms text NOT NULL,
  reward_accrual_usd_atoms text NOT NULL,
  basis_change_usd_atoms text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ledger_batches (
  id text PRIMARY KEY,
  portfolio_run_id text NOT NULL REFERENCES portfolio_runs(id),
  event_type text NOT NULL,
  event_id text NOT NULL,
  batch_hash char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (portfolio_run_id, event_type, event_id)
);

CREATE TABLE ledger_entries (
  id bigserial PRIMARY KEY,
  ledger_batch_id text NOT NULL REFERENCES ledger_batches(id),
  account_debit text NOT NULL,
  account_credit text NOT NULL,
  asset text NOT NULL,
  amount_atoms text NOT NULL,
  usd_value_atoms text NOT NULL,
  price_reference_id text,
  CHECK (account_debit <> account_credit)
);

CREATE TABLE risk_events (
  id text PRIMARY KEY,
  strategy_run_id text REFERENCES strategy_runs(id),
  portfolio_run_id text REFERENCES portfolio_runs(id),
  severity text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  code text NOT NULL,
  message text NOT NULL,
  observed_value jsonb NOT NULL,
  limit_value jsonb NOT NULL,
  action_taken text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);
CREATE INDEX risk_events_unresolved
  ON risk_events(severity, created_at DESC) WHERE resolved_at IS NULL;

CREATE TABLE reconciliations (
  id text PRIMARY KEY,
  strategy_run_id text REFERENCES strategy_runs(id),
  portfolio_run_id text REFERENCES portfolio_runs(id),
  execution_mode execution_mode NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  wallet_snapshot jsonb NOT NULL,
  venue_snapshot jsonb NOT NULL,
  executor_snapshot jsonb NOT NULL,
  database_snapshot jsonb NOT NULL,
  differences jsonb NOT NULL,
  result text NOT NULL
);

CREATE TABLE outbox_commands (
  id text PRIMARY KEY,
  portfolio_run_id text REFERENCES portfolio_runs(id),
  intent_id text REFERENCES execution_intents(id),
  command_type text NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);
CREATE INDEX outbox_pending
  ON outbox_commands(available_at, id) WHERE processed_at IS NULL;

CREATE TABLE leader_leases (
  lease_name text PRIMARY KEY,
  holder_instance_id text NOT NULL,
  generation bigint NOT NULL CHECK (generation >= 0),
  acquired_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  last_renewed_at timestamptz NOT NULL
);

CREATE TABLE control_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  pause_entries boolean NOT NULL DEFAULT false,
  pause_all boolean NOT NULL DEFAULT false,
  reason text NOT NULL DEFAULT '',
  version bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control_state(singleton) VALUES (true);
