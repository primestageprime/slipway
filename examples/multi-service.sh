#!/usr/bin/env bash
# Example: slipway wiring for a multi-service dev stack.
# https://github.com/primestageprime/slipway
#
# Scenario: a dev stack that runs several services (UI, API, Postgres,
# message broker, etc.) and supports multiple concurrent environments
# (e.g. a "full" env, a "lean" env, and any number of feature-branch
# environments). The stack claims 1000 ports up-front and carves them
# into 100-port slots, one per environment.
set -euo pipefail

APP_NAME="bigapp"
APP_SIZE=1000

# ensure = claim-if-missing, noop if same size, error if different size.
slipway ensure "$APP_NAME" "$APP_SIZE" >/dev/null

# Each env occupies a 100-port slot at an offset from the claimed range.
# `slipway port` handles the arithmetic (+ out-of-range check) for us.
ENV_OFFSET=${ENV_OFFSET:-0}        # 0 for env "a", 100 for "b", 200 for "c", …
UI_PORT=$(slipway port "$APP_NAME" $((ENV_OFFSET + 0)))
API_PORT=$(slipway port "$APP_NAME" $((ENV_OFFSET + 1)))
POSTGRES_PORT=$(slipway port "$APP_NAME" $((ENV_OFFSET + 2)))
BROKER_PORT=$(slipway port "$APP_NAME" $((ENV_OFFSET + 3)))
WORKER_PORT=$(slipway port "$APP_NAME" $((ENV_OFFSET + 4)))
DASHBOARD_PORT=$(slipway port "$APP_NAME" $((ENV_OFFSET + 5)))
export UI_PORT API_PORT POSTGRES_PORT BROKER_PORT WORKER_PORT DASHBOARD_PORT

echo "env listening on $UI_PORT (UI), $API_PORT (API), $POSTGRES_PORT (pg)…"
