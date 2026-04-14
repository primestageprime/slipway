# slipway

A machine-wide port-range registry for local dev. Hands out port ranges to
independent dev apps so multiple stacks on one machine don't step on each
other.

```sh
$ slipway claim bigapp 1000
4000 4999

$ slipway claim webapp 100
5100 5199           # skipped 5000 — reserved for macOS AirPlay

$ slipway list
APP     START  END   SIZE
bigapp  4000   4999  1000
webapp  5100   5199  100
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

**Homebrew (macOS / Linux):**

```sh
brew tap primestageprime/tap
brew install slipway
```

**One-liner:**

```sh
curl -sSL https://raw.githubusercontent.com/primestageprime/slipway/main/install.sh | sh
```

**From source:**

```sh
git clone https://github.com/primestageprime/slipway
cd slipway
make install                 # → ~/.local/bin/slipway + ~/.local/lib/slipway/commands.sh
make install-completions     # optional: bash + zsh completions
```

slipway ships as two files: `bin/slipway` (entry point) and `lib/slipway/commands.sh`
(sourced by the binary). `make install` places them as siblings; the binary
resolves the library via its own path, following symlinks. Set
`SLIPWAY_LIB` to override.

## Usage

```
slipway claim <app> <size> [--dry-run] [--json]     # reserve next free range
slipway reclaim <app> <size> [--no-move] [--json]   # release & re-claim at new size; --no-move fails if move needed
slipway ensure <app> <size> [--json]                # claim-if-missing; noop if already at <size>
slipway get <app> [--json]                          # print "START END" (exit 3 if unclaimed)
slipway port <app> [offset]                         # print a single port (start+offset, range-checked)
slipway release <app> [--if-claimed]                # free an app's range; --if-claimed = idempotent
slipway list [--json|--tsv]                         # show all allocations
slipway conflicts <port> [--json]                   # show who holds a port (exit 3 if free)
slipway doctor [--repair]                           # sanity-check; --repair clears orphaned locks
slipway caddy <app> [subdomain] [offset]            # emit a Caddyfile fragment for <app>
slipway config [show]                               # show port_range + registry_version
slipway config port-range <s> <e>                   # reconfigure port_range (refuses orphaning apps)
slipway version                                     # print version
slipway reserved [--json]                           # show system-reserved ports
slipway reserved add <s> <e> [note] [--force]       # reserve a range (refuses app overlap without --force)
slipway reserved remove <s>                         # un-reserve by start port
```

### Exit codes

Scripts can branch on these:

| Code | Meaning |
|------|---------|
| 0 | ok |
| 1 | generic error |
| 2 | usage error |
| 3 | not found (no such app / no matching reserved / free port) |
| 4 | port range exhausted |
| 5 | lock acquisition timeout |
| 6 | conflict (already-claimed, size mismatch, overlap without --force) |
| 7 | registry schema invalid |

Allocations are size-aligned: claiming size 1000 returns a range starting
on a 1000-boundary, size 100 on a 100-boundary. This keeps the port space
tidy and makes ports human-memorable (bigapp is always 4xxx, webapp is
always 5xxx).

### Integration

In your app's startup script:

```sh
read -r START END < <(slipway ensure myapp 100)

UI_PORT=$((START + 0))
DB_PORT=$((START + 1))
# …
```

`ensure` is the idempotent claim: it claims if missing, noops if already
claimed at the same size, and errors (exit 6) if claimed at a different
size. For JSON-parseable output, add `--json`:

```sh
eval "$(slipway ensure myapp 100 --json | jq -r '"START=\(.start); END=\(.end)"')"
```

See [examples/](examples/) for integration snippets:
[multi-service](examples/multi-service.sh) (one stack, many services, many
environments) and [single-service](examples/single-service.sh) (one web app
fronted by Caddy).

## Registry file

`~/.config/slipway/registry.json` (override with `SLIPWAY_REGISTRY`):

```json
{
  "port_range":  { "start": 4000, "end": 9999 },
  "reserved":    [{ "start": 5000, "end": 5000, "note": "macOS AirPlay" }],
  "apps": {
    "bigapp": { "start": 4000, "end": 4999 },
    "webapp": { "start": 5100, "end": 5199 }
  }
}
```

`reserved` is honored by `claim` (system ports that must be avoided).
Edit the file directly to change `port_range` or `reserved`. The
`registry_version` field is managed by slipway; don't set it by hand.

## Concurrency

`slipway` serializes mutating operations (`claim`, `reclaim`, `release`,
`reserved add/remove`) with a lockdir at `$SLIPWAY_REGISTRY.lock`. Parallel
invocations from multiple shells or processes are safe — they queue rather
than racing. Read-only commands (`get`, `list`, `conflicts`) skip the lock.

If a slipway process is killed uncleanly, the lock is removed on next
acquire via PID liveness check. To force-clear a wedged lock manually:
`rm -rf "$SLIPWAY_REGISTRY.lock"`. Tune the acquire timeout with
`SLIPWAY_LOCK_TIMEOUT_DS` (tenths of seconds; default 100 = 10s).

## Addressing convention

`slipway` gives you *ports*. For human-friendly *names*, pair it with
Caddy and `*.localhost` — see [docs/convention.md](docs/convention.md).
macOS resolves `*.localhost` to `127.0.0.1` natively; no dnsmasq needed.

## Docs

- [CHANGELOG.md](CHANGELOG.md) — notable changes per release.
- [docs/convention.md](docs/convention.md) — the `{env}.{app}.localhost` naming scheme and port-offset layout.
- `man slipway` — full manual page (install via `make install-man`).

## License

MIT. See [LICENSE](LICENSE).
