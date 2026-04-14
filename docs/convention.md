# Addressing convention

`slipway` solves half the problem — handing out ports. The other half is
making those ports addressable by stable, human-friendly names. This doc
describes the convention we use.

## HTTP: names via Caddy + `*.localhost`

macOS resolves any `*.localhost` hostname to `127.0.0.1` natively. No
`/etc/hosts` edit, no dnsmasq, no `/etc/resolver` entry. (Linux: add
`127.0.0.1 *.localhost` via your DNS stub of choice, or use
`nss-myhostname`.)

Run Caddy as a local reverse proxy that routes by `Host` header:

```
# ~/.config/caddy/Caddyfile
{
    admin localhost:2020
}

import conf.d/*.Caddyfile
```

Each app drops a fragment into `~/.config/caddy/conf.d/`:

```
# ~/.config/caddy/conf.d/myapp.Caddyfile
dev.myapp.localhost {
    reverse_proxy localhost:5100
}

dev-api.myapp.localhost {
    reverse_proxy https://localhost:5101 {
        transport http { tls_insecure_skip_verify }
    }
}
```

### Naming scheme

- Primary UI:        `{env}.{app}.localhost`
- Secondary HTTP:    `{env}-{service}.{app}.localhost`

Where `{env}` is your environment name (`dev`, `staging-local`, a worktree
name, etc.) and `{app}` is the slipway app key.

## Raw TCP: ports only

Postgres, MQTT, Redis, and any other non-HTTP service can't go
through Caddy — clients connect by host+port. For these, use slipway
ports directly, and document your offsets.

A typical layout for an app that claims 100 ports:

| Offset | Role |
|-------:|------|
| 0      | UI (HTTP, behind Caddy) |
| 1      | API (HTTP, behind Caddy) |
| 2      | Postgres |
| 3      | MQTT |
| 4      | Redis |
| 5      | Admin dashboard |

In your startup:

```sh
read -r START _END < <(slipway get myapp)
export UI_PORT=$((START + 0))
export API_PORT=$((START + 1))
export PG_PORT=$((START + 2))
# …
```

## Rule of thumb

- If the service speaks HTTP, put it behind Caddy and address by name.
- If the service speaks raw TCP, address by port.
- Either way, the port comes from slipway, not a hardcoded constant.
