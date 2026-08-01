#!/usr/bin/env bash
# Bring up the local paper stack and run the operator console against it.
#
# No process juggling: `docker compose up --wait` supervises the six services
# detached and blocks until their healthchecks pass, so the console is the only
# foreground process. One set of logs, and Ctrl-C means one obvious thing.
set -euo pipefail

project_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
cd "$project_dir"

console_port=${CONSOLE_PORT:-5173}

usage() {
  printf '%s\n' \
    'usage: dev.sh [command]' \
    '  up       start the stack, wait for health, run the console (default)' \
    '  stack    start the stack only, without the console' \
    '  build    rebuild the images, then start everything' \
    '  status   show service state and the local URLs' \
    '  down     stop the stack (paper evidence and Prometheus history are kept)' \
    '  reset-db --approve-paper-reset' \
    '           permanently clear PostgreSQL paper data and restart the stack' \
    '  logs     follow collector and adapter logs' \
    '' \
    'ADAPTER_MODE=authoritative dev.sh   captures live Phoenix/RPC/Jupiter data' \
    'CONSOLE_PORT=3001 dev.sh            moves the console off 5173'
}

urls() {
  printf '\n  %-11s %s\n' \
    console    "http://127.0.0.1:$console_port" \
    collector  'http://127.0.0.1:8080/v1/status' \
    adapter    'http://127.0.0.1:8090' \
    prometheus 'http://127.0.0.1:9090' \
    grafana    'http://127.0.0.1:3000'
  printf '\n'
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'dev.sh: %s is required but not installed\n' "$1" >&2
    exit 1
  }
}

stop_stack() {
  docker compose --profile '*' down --remove-orphans
}

start_stack() {
  require docker
  docker info >/dev/null 2>&1 || {
    printf 'dev.sh: the Docker daemon is not running\n' >&2
    exit 1
  }

  # Building is opt-in because it is genuinely expensive: the collector image
  # compiles the Mesh toolchain from ../mesh-lang — LLVM 21, Rust, `cargo build
  # -p meshc`, and twelve cargo test invocations — before it ever reaches this
  # project's sources. That is minutes, and almost never what you want when you
  # only edited the console. `dev.sh build` forces it; otherwise we build only
  # when the image is missing.
  local build=
  if [ "${REBUILD:-0}" = 1 ] || ! docker image inspect \
    delta-neutral-funding-collector:latest >/dev/null 2>&1; then
    build=--build
    printf 'building images (compiles the Mesh toolchain — expect several minutes)...\n'
  fi

  printf 'starting stack (compose waits for every healthcheck)...\n'
  # --wait blocks until postgres, collector and adapter report healthy and the
  # migration job exits 0. Without it the console would poll a collector that
  # has not applied its migrations yet.
  if ! docker compose up -d ${build:+"$build"} --wait; then
    printf '\ndev.sh: the stack did not come up healthy\n\n' >&2
    docker compose ps >&2 || true
    printf '\n--- collector ---\n' >&2
    docker compose logs --tail=40 collector >&2 || true
    if docker compose logs --no-color collector 2>/dev/null |
      grep -Fq 'running paper strategy build does not match pinned release'; then
      printf '\ndev.sh: the database belongs to another build; to discard its paper evidence, run:\n  ./dev.sh reset-db --approve-paper-reset\n' >&2
    fi
    exit 1
  fi
}

reset_database() {
  if [ "$#" -ne 1 ] || [ "$1" != '--approve-paper-reset' ]; then
    printf 'dev.sh: reset-db requires --approve-paper-reset\n' >&2
    return 2
  fi

  require docker
  docker info >/dev/null 2>&1 || {
    printf 'dev.sh: the Docker daemon is not running\n' >&2
    return 1
  }

  local volume=delta-neutral-funding_postgres_data_v49
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    local project_label volume_label
    project_label=$(docker volume inspect --format \
      '{{index .Labels "com.docker.compose.project"}}' "$volume")
    volume_label=$(docker volume inspect --format \
      '{{index .Labels "com.docker.compose.volume"}}' "$volume")
    if [ "$project_label" != 'delta-neutral-funding' ] ||
      [ "$volume_label" != 'postgres_data_v49' ]; then
      printf 'dev.sh: refusing to delete an unverified database volume\n' >&2
      return 1
    fi
  fi

  stop_stack
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    docker volume rm "$volume" >/dev/null
    printf 'deleted %s; its paper data cannot be recovered\n' "$volume"
  fi
  start_stack
}

install_console() {
  require node
  require npm
  # Reinstall when the lockfile is newer than the tree it produced, so a pulled
  # dependency change is not silently ignored.
  if [ ! -d ui/node_modules ] || [ ui/package-lock.json -nt ui/node_modules ]; then
    printf 'installing console dependencies...\n'
    npm --prefix ui install --no-audit --no-fund
    touch ui/node_modules
  fi
}

run_console() {
  install_console
  urls
  if curl -fsS --max-time 1 "http://127.0.0.1:$console_port/" 2>/dev/null |
    grep -Fq 'Delta-Neutral Funding — Console'; then
    printf 'console is already running at http://127.0.0.1:%s; reusing it\n' "$console_port"
    return
  fi
  printf 'the stack keeps running after the console exits — `dev.sh down` stops it\n\n'
  cd ui
  exec npm run dev -- --port "$console_port" --strictPort
}

case ${1:-up} in
  up)
    start_stack
    run_console
    ;;
  stack)
    start_stack
    urls
    ;;
  build)
    REBUILD=1 start_stack
    run_console
    ;;
  status)
    docker compose ps
    urls
    curl -fsS --max-time 3 http://127.0.0.1:8080/v1/status 2>/dev/null |
      { command -v jq >/dev/null 2>&1 && jq . || cat; } ||
      printf 'collector is not answering on 8080\n'
    ;;
  down)
    # Never -v: the paper ledger, soak evidence and Prometheus history live in
    # named volumes and a dev script has no business deleting them.
    stop_stack
    ;;
  reset-db)
    shift
    reset_database "$@"
    urls
    ;;
  logs)
    docker compose logs -f collector adapter
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
