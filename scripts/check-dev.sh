#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
output=$(mktemp)
fake_bin=$(mktemp -d)
docker_args="$fake_bin/docker-args"
trap 'rm -f "$output"; rm -rf "$fake_bin"' EXIT HUP INT TERM

printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"$DEV_TEST_DOCKER_ARGS"' \
  >"$fake_bin/docker"
chmod +x "$fake_bin/docker"

PATH="$fake_bin:$PATH" DEV_TEST_DOCKER_ARGS="$docker_args" \
  "$project_dir/dev.sh" down
grep -Fxq 'compose --profile * down --remove-orphans' "$docker_args"

"$project_dir/dev.sh" help | grep -Fq \
  'reset-db --approve-paper-reset'

if "$project_dir/dev.sh" reset-db >"$output" 2>&1; then
  printf 'reset-db accepted a request without explicit approval\n' >&2
  exit 1
fi
grep -Fq 'reset-db requires --approve-paper-reset' "$output"

if "$project_dir/dev.sh" reset-db --approve-paper-reset unexpected \
  >"$output" 2>&1; then
  printf 'reset-db accepted unexpected arguments\n' >&2
  exit 1
fi
grep -Fq 'reset-db requires --approve-paper-reset' "$output"

printf 'dev command checks passed\n'
