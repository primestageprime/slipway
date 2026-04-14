#!/usr/bin/env bash
# Example: slipway wiring for a multi-service dev stack.
# https://github.com/primestageprime/slipway
#
# Scenario: a dev stack that runs several services (UI, API, Postgres,
# message broker, etc.) and supports multiple concurrent environments
# (e.g. a "full" env, a "lean" env, and any number of feature-branch
# environments). The stack claims 1000 ports up-front and carves them
# into 100-port slots, one per environment.

APP_NAME="bigapp"
APP_SIZE=1000

load_port_range() {
  if ! slipway get "$APP_NAME" >/dev/null 2>&1; then
    slipway claim "$APP_NAME" "$APP_SIZE" >/dev/null \
      || { echo "could not claim port range from slipway" >&2; exit 1; }
  fi
  read -r PORT_RANGE_START PORT_RANGE_END < <(slipway get "$APP_NAME")
  export PORT_RANGE_START PORT_RANGE_END
}

# Each env occupies a 100-port slot starting at some multiple of 100 within
# the claimed range: env "a" at PORT_RANGE_START+0, env "b" at +100, …
export_env_ports() {
  local base="$1"          # e.g. PORT_RANGE_START + 100
  export UI_PORT=$((base + 0))
  export API_PORT=$((base + 1))
  export POSTGRES_PORT=$((base + 2))
  export BROKER_PORT=$((base + 3))
  export WORKER_PORT=$((base + 4))
  export DASHBOARD_PORT=$((base + 5))
}

load_port_range
export_env_ports $((PORT_RANGE_START + 100))
echo "env listening on $UI_PORT (UI), $API_PORT (API), $POSTGRES_PORT (pg)…"
