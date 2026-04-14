# slipway

A machine-wide port-range registry for local dev. Hands out port ranges to
independent dev apps so multiple stacks on one machine don't step on each
other.

```sh
$ slipway claim amygdala 1000
4000 4999

$ slipway claim dside 100
5100 5199           # skipped 5000 — reserved for macOS AirPlay

$ slipway list
APP       START  END   SIZE
amygdala  4000   4999  1000
dside     5100   5199  100
```

## Why

Dev stacks collide on ports. The usual options are:

- **Hardcode** a port per project — works until you run two things at once.
- **Let the OS pick** — works, but the address isn't stable, so your
  `.env.local`, Caddyfile, docker-compose, and teammates all lose the plot.
- **A real service registry** (Consul, etcd) — overkill for a single
  developer's machine.

`slipway` is the in-between: one JSON file, one shell script, one subcommand
to claim a stable range per app. Combine with Caddy + `*.localhost` (see
[convention](docs/convention.md)) and you get stable URLs too.

## Install

Requires `bash`, `jq`, and `column`.

```sh
git clone https://github.com/primestageprime/slipway
cd slipway
make install        # → ~/.local/bin/slipway
```

Or drop `bin/slipway` anywhere on your `PATH`.

## Usage

```
slipway claim <app> <size>   # reserve next free range of <size> ports
slipway get <app>            # print "START END" (exit 1 if unclaimed)
slipway release <app>        # free an app's range
slipway list                 # show all allocations
slipway reserved             # show system-reserved ports
```

Allocations are size-aligned: claiming size 1000 returns a range starting
on a 1000-boundary, size 100 on a 100-boundary. This keeps the port space
tidy and makes ports human-memorable (amygdala is always 4xxx, dside is
always 5xxx).

### Integration

In your app's startup script:

```sh
if ! slipway get myapp >/dev/null 2>&1; then
  slipway claim myapp 100 >/dev/null
fi
read -r START END < <(slipway get myapp)

UI_PORT=$((START + 0))
DB_PORT=$((START + 1))
# …
```

See [examples/](examples/) for real-world wiring with
[amygdala](examples/amygdala-snippet.sh) and
[dside](examples/dside-snippet.sh).

## Registry file

`~/.config/slipway/registry.json` (override with `SLIPWAY_REGISTRY`):

```json
{
  "port_range":  { "start": 4000, "end": 9999 },
  "reserved":    [{ "start": 5000, "end": 5000, "note": "macOS AirPlay" }],
  "apps": {
    "amygdala": { "start": 4000, "end": 4999 },
    "dside":    { "start": 5100, "end": 5199 }
  }
}
```

`reserved` is honored by `claim` (system ports that must be avoided).
Edit the file directly to change `port_range` or `reserved`.

## Addressing convention

`slipway` gives you *ports*. For human-friendly *names*, pair it with
Caddy and `*.localhost` — see [docs/convention.md](docs/convention.md).
macOS resolves `*.localhost` to `127.0.0.1` natively; no dnsmasq needed.

## License

MIT. See [LICENSE](LICENSE).
