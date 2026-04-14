#!/usr/bin/env bash
# Example: slipway wiring for a single-service dev app.
# https://github.com/primestageprime/slipway
#
# Scenario: one web app that needs a stable UI port and a stable URL.
# Claim a small slot, bind the dev server to the UI port, and write a
# Caddy fragment so the app is reachable at dev.webapp.localhost
# regardless of which port it actually landed on.

APP_NAME="webapp"
APP_SIZE=100

load_port_range() {
  if ! slipway get "$APP_NAME" >/dev/null 2>&1; then
    slipway claim "$APP_NAME" "$APP_SIZE" >/dev/null || exit 1
  fi
  local start end
  read -r start end < <(slipway get "$APP_NAME")
  UI_PORT=$((start + 0))
  export UI_PORT
}

write_caddy_fragment() {
  cat > "$HOME/.config/caddy/conf.d/${APP_NAME}.Caddyfile" <<EOF
dev.${APP_NAME}.localhost {
  reverse_proxy localhost:${UI_PORT}
}
EOF
}

load_port_range
write_caddy_fragment

# Many dev-server CLIs hardcode a port in package.json's "dev" script
# (e.g. "vite dev --port 5173"). Pass --port explicitly rather than relying
# on PORT env so the CLI flag always reflects what slipway gave us.
exec pnpm exec vite dev --port "$UI_PORT"
