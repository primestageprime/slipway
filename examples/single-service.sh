#!/usr/bin/env bash
# Example: slipway wiring for a single-service dev app.
# https://github.com/primestageprime/slipway
#
# Scenario: one web app that needs a stable UI port and a stable URL.
# Claim a small slot, bind the dev server to the UI port, and write a
# Caddy fragment so the app is reachable at dev.webapp.localhost
# regardless of which port it actually landed on.
set -euo pipefail

APP_NAME="webapp"
APP_SIZE=100

# `ensure` is the idempotent claim: no-op if already at APP_SIZE, claim if
# missing, exit 6 if claimed at a different size.
read -r START _END < <(slipway ensure "$APP_NAME" "$APP_SIZE")
UI_PORT=$((START + 0))
export UI_PORT

# Emit the Caddy fragment via slipway — the binary knows the addressing
# convention (dev.$APP_NAME.localhost) and the UI is always at offset 0.
caddy_dir="$HOME/.config/caddy/conf.d"
mkdir -p "$caddy_dir"
slipway caddy "$APP_NAME" > "$caddy_dir/${APP_NAME}.Caddyfile"

# Many dev-server CLIs hardcode a port in package.json's "dev" script
# (e.g. "vite dev --port 5173"). Pass --port explicitly rather than relying
# on PORT env so the CLI flag always reflects what slipway gave us.
exec pnpm exec vite dev --port "$UI_PORT"
