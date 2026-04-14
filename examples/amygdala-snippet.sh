#!/usr/bin/env bash
# Example: integrate slipway into amygdala's CLI
# (https://github.com/primestageprime/slipway)
#
# Amygdala is a multi-service dev stack (UI, Rust API, Postgres, MQTT,
# SpacetimeDB, etc.) that allocates 1000 ports split into 100-port slots
# per environment (e.g. full=4000, lean=4100, worktree=4200, …).

load_port_range() {
  if ! slipway get amygdala >/dev/null 2>&1; then
    slipway claim amygdala 1000 >/dev/null \
      || { echo "could not claim port range from slipway" >&2; exit 1; }
  fi
  read -r PORT_RANGE_START PORT_RANGE_END < <(slipway get amygdala)
  export PORT_RANGE_START PORT_RANGE_END
}

# Within the claimed range, amygdala maintains its own sub-registry of
# environments, each occupying a 100-port slot. The first env goes at
# PORT_RANGE_START+0, the next at +100, and so on.
export_env_ports() {
  local base="$1"          # e.g. 4100
  export UI_PORT=$((base + 0))
  export API_PORT=$((base + 1))
  export POSTGRES_PORT=$((base + 2))
  export MQTT_PORT=$((base + 3))
  export SPACETIMEDB_PORT=$((base + 4))
  export DASHBOARD_PORT=$((base + 5))
}

load_port_range
export_env_ports 4100
echo "lean env listening on $UI_PORT (UI), $API_PORT (API), $POSTGRES_PORT (pg)…"
