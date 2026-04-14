# Changelog

All notable changes to slipway. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); dates are YYYY-MM-DD.

## [0.2.0] — 2026-04-14

### Added
- `slipway ensure <app> <size>` — atomic claim-if-missing; noop if claimed
  at the same size; exit 6 on size mismatch. Replaces the 3-line
  `get || claim` idiom and closes its TOCTOU.
- `slipway reclaim --no-move` — grow/shrink in place; errors if current
  start is not aligned to the new size or if the target range collides.
- `slipway port <app> [offset]` — single-port lookup; handles
  `start + offset` arithmetic and range-checking.
- `slipway doctor [--repair]` — sanity-check for orphaned locks, apps
  outside `port_range`, and overlapping app/reserved ranges. `--repair`
  clears orphaned locks.
- `slipway caddy <app> [subdomain] [offset]` — emit a Caddyfile fragment
  for the app (`{subdomain}.{app}.localhost` → `localhost:start+offset`).
- `slipway config [show|port-range]` — inspect registry config and
  reconfigure `port_range` with an orphan-app guard.
- `slipway version` — print the version string (works even with a
  broken registry).
- `--json` on `claim`/`reclaim`/`ensure`/`get`/`conflicts`; `list --json`
  and `list --tsv` for machine-readable output.
- `release --if-claimed` — idempotent release for teardown scripts.
- `reserved add --force` flag; without it, overlap with a claimed app is
  refused (exit 6). Previously the overlap was silently accepted.
- Distinct exit codes (1 generic, 2 usage, 3 not-found, 4 exhausted,
  5 lock-timeout, 6 conflict, 7 schema). Scripts can now branch reliably.
- bash + zsh completions under `completions/`.
- `curl | sh` installer at `install.sh`.
- `SLIPWAY_DEBUG` env var for tracing lock acquisition and allocation.
- Registry schema versioning (`registry_version: 1`) with a forward-guard
  and an auto-migration for pre-versioned files.
- Concurrency-safe locking via a lockdir with PID-liveness + double-read
  TOCTOU-safe stale recovery. `flock` unavailable on macOS by default.

### Changed
- `slipway` now ships as two files: `bin/slipway` (entry) and
  `lib/slipway/commands.sh` (sourced). `make install` places them as
  siblings; the binary resolves its lib via symlink-aware `$BASH_SOURCE`.
  Set `SLIPWAY_LIB` to override.
- Allocator collapsed to a single `jq` invocation per `claim`/`reclaim`
  (was O(N) jq processes per claim).
- Examples rewritten to use `ensure` + `slipway port` + `slipway caddy`
  instead of the manual idioms.

### Fixed
- Race window in `write` where two concurrent claims could allocate
  overlapping ranges.
- `write` previously hid `jq` failures inside an `&&` chain.
- `acquire_lock` previously had a TOCTOU between "pid is dead" and
  `rm -rf`; now double-reads the pidfile before removing.
- `validate_registry` previously conflated schema errors with missing-jq
  / unreadable-file errors.

## [0.1.0] — 2026-04-14

Initial public release. `claim`/`get`/`release`/`list`/`reserved` via a
single-file bash script + a JSON registry at
`~/.config/slipway/registry.json`.
