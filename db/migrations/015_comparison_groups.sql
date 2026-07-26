BEGIN;

CREATE TYPE comparison_mode AS ENUM ('independent', 'synchronized');

CREATE TABLE comparison_groups (
  id text PRIMARY KEY,
  strategy_run_id text NOT NULL REFERENCES strategy_runs(id),
  mode comparison_mode NOT NULL,
  target_notional_usd_micros bigint NOT NULL
    CHECK (target_notional_usd_micros > 0),
  entry_policy_version text NOT NULL,
  exit_policy_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, strategy_run_id)
);

ALTER TABLE portfolio_runs
  ADD COLUMN comparison_group_id text;

INSERT INTO comparison_groups (
  id, strategy_run_id, mode, target_notional_usd_micros,
  entry_policy_version, exit_policy_version
)
SELECT
  id || ':independent',
  id,
  'independent',
  500000000,
  'paper-entry-v1',
  'paper-exit-v1'
FROM strategy_runs;

UPDATE portfolio_runs
SET comparison_group_id = strategy_run_id || ':independent';

ALTER TABLE portfolio_runs
  DROP CONSTRAINT portfolio_runs_strategy_run_id_variant_key,
  ADD CONSTRAINT portfolio_runs_comparison_group_run_fk
    FOREIGN KEY (comparison_group_id, strategy_run_id)
    REFERENCES comparison_groups(id, strategy_run_id),
  ADD CONSTRAINT portfolio_runs_comparison_variant_unique
    UNIQUE (strategy_run_id, comparison_group_id, variant);

INSERT INTO schema_meta(version) VALUES (15);

COMMIT;
