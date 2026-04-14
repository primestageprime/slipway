#!/usr/bin/env bash
# Example: integrate slipway into a small single-service dev app.
# (https://github.com/primestageprime/slipway)
#
# dside is a SolidStart/Vinxi UI backed by an externally-managed
# SpacetimeDB. Only one port matters — the UI — so we claim a small slot.

load_port_range() {
  if ! slipway get dside >/dev/null 2>&1; then
    slipway claim dside 100 >/dev/null || exit 1
  fi
  local start end
  read -r start end < <(slipway get dside)
  UI_PORT=$((start + 0))
  export UI_PORT
  # Vinxi/vite honor the --port CLI flag; PORT env also works if the
  # package.json `dev` script doesn't hardcode --port.
}

write_caddy_fragment() {
  cat > "$HOME/.config/caddy/conf.d/dside.Caddyfile" <<EOF
dev.dside.localhost {
  reverse_proxy localhost:${UI_PORT}
}
EOF
}

load_port_range
write_caddy_fragment
pnpm exec vinxi dev --port "$UI_PORT"
