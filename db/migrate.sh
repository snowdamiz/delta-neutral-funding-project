#!/bin/sh
set -eu

migration_dir=${MIGRATION_DIR:-/migrations}
found=false

for migration_path in "$migration_dir"/[0-9][0-9][0-9]_*.sql; do
  [ -f "$migration_path" ] || continue
  found=true
  migration_name=${migration_path##*/}
  version=${migration_name%%_*}
  version=${version#0}
  version=${version#0}

  table_exists=$(psql --tuples-only --no-align --command="SELECT to_regclass('public.schema_meta') IS NOT NULL")
  applied=false
  if [ "$table_exists" = "t" ]; then
    applied=$(psql --tuples-only --no-align --command="SELECT EXISTS (SELECT 1 FROM schema_meta WHERE version = $version)")
  fi

  if [ "$applied" = "t" ]; then
    printf 'already applied: %s\n' "$migration_name"
    continue
  fi

  printf 'applying: %s\n' "$migration_name"
  psql --set=ON_ERROR_STOP=1 --file="$migration_path"
  test "$(psql --tuples-only --no-align --command="SELECT EXISTS (SELECT 1 FROM schema_meta WHERE version = $version)")" = "t"
done

[ "$found" = "true" ] || {
  printf 'no migrations found in %s\n' "$migration_dir" >&2
  exit 1
}
