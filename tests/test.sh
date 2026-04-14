#!/usr/bin/env bash
# Minimal test suite for slipway. Each test uses an isolated registry
# via SLIPWAY_REGISTRY.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLIPWAY="$SCRIPT_DIR/../bin/slipway"

pass=0
fail=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    echo "  ok: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label"
    echo "    got:  $got"
    echo "    want: $want"
    fail=$((fail + 1))
  fi
}

assert_exit() {
  local want="$1" label="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then
    echo "  ok: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label (got rc=$rc, want $want)"
    fail=$((fail + 1))
  fi
}

fresh_registry() {
  local dir
  dir=$(mktemp -d)
  export SLIPWAY_REGISTRY="$dir/reg.json"
  "$SLIPWAY" list >/dev/null   # triggers ensure_registry
}

echo "# basic claim/get/release"
fresh_registry
assert_eq "$("$SLIPWAY" claim app1 100)" "4000 4099" "first claim starts at range_start"
assert_eq "$("$SLIPWAY" get app1)"       "4000 4099" "get returns claimed range"
"$SLIPWAY" release app1 >/dev/null
assert_exit 3 "get after release fails (E_NOTFOUND)" "$SLIPWAY" get app1

echo "# alignment"
fresh_registry
assert_eq "$("$SLIPWAY" claim big 1000)" "4000 4999" "size 1000 aligns on 1000-boundary"
assert_eq "$("$SLIPWAY" claim small 50)" "5050 5099" "size 50 aligns on 50-boundary, skips reserved"

echo "# no double-claim"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
assert_exit 6 "claim existing app fails (E_CONFLICT)" "$SLIPWAY" claim app1 100

echo "# reserved ports are avoided"
fresh_registry
# 5000 is reserved; claim size 1 should skip it.
assert_eq "$("$SLIPWAY" claim one 1)" "4000 4000" "size 1 starts at range start"
"$SLIPWAY" release one >/dev/null
# Fill 4000-4999 so claim is forced into 5xxx territory.
"$SLIPWAY" claim fill 1000 >/dev/null
got=$("$SLIPWAY" claim next 1)
# Should skip 5000 (reserved) → 5001.
assert_eq "$got" "5001 5001" "size 1 after fill skips reserved 5000"

echo "# reserved add/remove"
fresh_registry
"$SLIPWAY" claim first 100 >/dev/null        # takes 4000-4099
"$SLIPWAY" reserved add 4100 4199 "test" >/dev/null
got=$("$SLIPWAY" claim next 100)             # should skip 4100-4199
assert_eq "$got" "4200 4299" "claim skips added reserved block"
"$SLIPWAY" release next >/dev/null
"$SLIPWAY" reserved remove 4100 >/dev/null
got=$("$SLIPWAY" claim after 100)            # reservation gone, 4100 free again
assert_eq "$got" "4100 4199" "claim reuses previously-reserved range after removal"
assert_exit 2 "reserved add with missing args fails (E_USAGE)" "$SLIPWAY" reserved add 8000
assert_exit 3 "reserved remove non-existent fails (E_NOTFOUND)" "$SLIPWAY" reserved remove 9999

echo "# range exhaustion"
fresh_registry
"$SLIPWAY" claim big 1000 >/dev/null
assert_exit 4 "oversized claim fails cleanly (E_EXHAUSTED)" "$SLIPWAY" claim huge 999999

echo "# dry-run"
fresh_registry
assert_eq "$("$SLIPWAY" claim app1 100 --dry-run)" "would claim: 4000 4099" "dry-run prints would-claim"
assert_exit 3 "dry-run did not persist" "$SLIPWAY" get app1

echo "# reclaim"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null            # 4000-4099
"$SLIPWAY" claim app2 100 >/dev/null            # 4100-4199
# Resize app1 from 100 → 1000. app1 is excluded from "taken"; app2 at
# 4100-4199 blocks 4000-4999. Next 1000-aligned free slot is 5000, but
# reserved 5000 lies inside → skip to 6000-6999.
got=$("$SLIPWAY" reclaim app1 1000)
assert_eq "$got" "6000 6999" "reclaim resizes and moves app1"
assert_eq "$("$SLIPWAY" get app1)" "6000 6999" "reclaim persisted"
assert_eq "$("$SLIPWAY" get app2)" "4100 4199" "reclaim did not disturb other apps"
assert_exit 3 "reclaim of unknown app fails (E_NOTFOUND)" "$SLIPWAY" reclaim ghost 100

echo "# conflicts"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
assert_exit 0 "conflicts finds app" "$SLIPWAY" conflicts 4050
assert_exit 0 "conflicts finds reserved" "$SLIPWAY" conflicts 5000
assert_exit 3 "conflicts on free port exits E_NOTFOUND" "$SLIPWAY" conflicts 9000
assert_exit 2 "conflicts requires numeric port (E_USAGE)" "$SLIPWAY" conflicts abc

echo "# concurrent claims do not overlap"
fresh_registry
# Spawn N parallel claims; verify no two ranges overlap and all succeed.
# N is large enough that without locking, two processes routinely hit the
# same read-compute-write window and either overlap or lose a write.
N=30
pids=()
outdir=$(mktemp -d)
for i in $(seq 1 $N); do
  ("$SLIPWAY" claim "concurrent$i" 10 > "$outdir/$i" 2>&1) &
  pids+=("$!")
done
all_ok=0
for p in "${pids[@]}"; do
  wait "$p" || all_ok=1
done
assert_eq "$all_ok" "0" "all concurrent claims succeeded"
# Check no overlap: sort by start, ensure each start > previous end.
overlap=0
prev_end=-1
while read -r s e; do
  if (( s <= prev_end )); then overlap=1; fi
  prev_end=$e
done < <(cat "$outdir"/* | sort -n)
assert_eq "$overlap" "0" "no overlapping ranges across concurrent claims"
claimed=$("$SLIPWAY" list | tail -n +2 | wc -l | tr -d ' ')
assert_eq "$claimed" "$N" "registry has all $N concurrent claims"
rm -rf "$outdir"

echo "# schema validation"
fresh_registry
echo '{"bogus": true}' > "$SLIPWAY_REGISTRY"
assert_exit 7 "invalid schema is rejected (E_SCHEMA)" "$SLIPWAY" list

echo "# registry_version migration"
fresh_registry
# Strip version to simulate pre-versioned registry, then run any command.
tmpreg=$(mktemp)
jq 'del(.registry_version)' "$SLIPWAY_REGISTRY" > "$tmpreg" && mv "$tmpreg" "$SLIPWAY_REGISTRY"
"$SLIPWAY" list >/dev/null
v=$(jq -r '.registry_version' "$SLIPWAY_REGISTRY")
assert_eq "$v" "1" "migration added registry_version"

echo "# newer registry_version is rejected"
fresh_registry
tmpreg=$(mktemp)
jq '.registry_version = 99' "$SLIPWAY_REGISTRY" > "$tmpreg" && mv "$tmpreg" "$SLIPWAY_REGISTRY"
assert_exit 1 "future registry_version rejected" "$SLIPWAY" list

echo "# populated v0 migration preserves data"
fresh_registry
"$SLIPWAY" claim keep1 100 >/dev/null
"$SLIPWAY" claim keep2 200 >/dev/null
"$SLIPWAY" reserved add 8000 8010 testnote >/dev/null
before=$(jq -S '.apps, .reserved, .port_range' "$SLIPWAY_REGISTRY")
tmpreg=$(mktemp)
jq 'del(.registry_version)' "$SLIPWAY_REGISTRY" > "$tmpreg" && mv "$tmpreg" "$SLIPWAY_REGISTRY"
"$SLIPWAY" list >/dev/null
assert_eq "$(jq -r '.registry_version' "$SLIPWAY_REGISTRY")" "1" "populated migration bumps version"
after=$(jq -S '.apps, .reserved, .port_range' "$SLIPWAY_REGISTRY")
assert_eq "$before" "$after" "populated migration preserves apps/reserved/port_range"

echo "# dry-run rejects already-claimed app"
fresh_registry
"$SLIPWAY" claim already 100 >/dev/null
assert_exit 6 "dry-run on claimed app fails (E_CONFLICT)" "$SLIPWAY" claim already 100 --dry-run

echo "# reclaim same size is idempotent"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
before=$(jq -S '.apps' "$SLIPWAY_REGISTRY")
got=$("$SLIPWAY" reclaim app1 100)
assert_eq "$got" "4000 4099" "reclaim same size returns same range"
after=$(jq -S '.apps' "$SLIPWAY_REGISTRY")
assert_eq "$before" "$after" "same-size reclaim leaves registry unchanged"

echo "# reclaim preserves original when no room"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
assert_exit 4 "reclaim with impossible size fails (E_EXHAUSTED)" "$SLIPWAY" reclaim app1 999999
assert_eq "$("$SLIPWAY" get app1)" "4000 4099" "app1 range preserved after failed reclaim"

echo "# stale lock recovery"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "9999999" > "$SLIPWAY_REGISTRY.lock/pid"  # PID that cannot exist
assert_eq "$("$SLIPWAY" claim app1 100)" "4000 4099" "claim reclaims stale lock"
if [[ ! -d "$SLIPWAY_REGISTRY.lock" ]]; then
  echo "  ok: stale lock cleared after use"
  pass=$((pass + 1))
else
  echo "  FAIL: stale lock not cleared"
  fail=$((fail + 1))
fi

echo "# lock timeout on live holder"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "$$" > "$SLIPWAY_REGISTRY.lock/pid"  # our own PID (alive)
SLIPWAY_LOCK_TIMEOUT_DS=3 assert_exit 5 "acquire times out on live holder (E_LOCK)" "$SLIPWAY" claim app1 100
rm -rf "$SLIPWAY_REGISTRY.lock"

echo "# conflicts edge cases"
fresh_registry
"$SLIPWAY" reserved add 8000 8010 "big reservation" >/dev/null
out=$("$SLIPWAY" conflicts 8005 2>&1)
if [[ "$out" == *"big reservation"* ]]; then
  echo "  ok: conflicts shows reserved note"
  pass=$((pass + 1))
else
  echo "  FAIL: note missing from conflicts output: $out"
  fail=$((fail + 1))
fi
# A port above port_range.end (9999) with no claim/reservation → free.
assert_exit 3 "conflicts on out-of-range port reports free (E_NOTFOUND)" "$SLIPWAY" conflicts 15000

echo "# ensure: claim-if-missing + noop-if-same-size + conflict-on-size-mismatch"
fresh_registry
assert_eq "$("$SLIPWAY" ensure app1 100)" "4000 4099" "ensure claims when missing"
assert_eq "$("$SLIPWAY" ensure app1 100)" "4000 4099" "ensure noop when claimed at same size"
assert_exit 6 "ensure errors on size mismatch (E_CONFLICT)" "$SLIPWAY" ensure app1 200
# Registry is unchanged after the mismatch error.
assert_eq "$("$SLIPWAY" get app1)" "4000 4099" "ensure did not modify on mismatch"

echo "# --json output"
fresh_registry
got=$("$SLIPWAY" claim app1 100 --json)
assert_eq "$got" '{"app":"app1","start":4000,"end":4099,"size":100}' "claim --json shape"
got=$("$SLIPWAY" get app1 --json)
assert_eq "$got" '{"app":"app1","start":4000,"end":4099,"size":100}' "get --json shape"
got=$("$SLIPWAY" reclaim app1 200 --json)
# app1 is excluded from "taken"; lowest 200-aligned range in [4000,9999] is 4000.
assert_eq "$got" '{"app":"app1","start":4000,"end":4199,"size":200}' "reclaim --json shape"
got=$("$SLIPWAY" list --json)
# list --json returns the apps object.
expect=$(jq -c '.apps' "$SLIPWAY_REGISTRY")
assert_eq "$got" "$expect" "list --json matches .apps"
got=$("$SLIPWAY" list --tsv)
# tsv has a header + one data row; no column-padding spaces.
first_line=$(echo "$got" | head -1)
assert_eq "$first_line" "$(printf 'APP\tSTART\tEND\tSIZE')" "list --tsv header"

echo "# conflicts --json"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
got=$("$SLIPWAY" conflicts 4050 --json)
# Array with one element: {kind:"app", name:"app1", start:4000, end:4099}
expect='[{"kind":"app","name":"app1","start":4000,"end":4099}]'
assert_eq "$got" "$expect" "conflicts --json for app hit"
assert_exit 3 "conflicts --json for free port exits E_NOTFOUND" "$SLIPWAY" conflicts 9000 --json

echo "# reserved add overlap rejected without --force"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null                     # 4000-4099
assert_exit 6 "reserved add overlapping app (E_CONFLICT)" "$SLIPWAY" reserved add 4050 4200 overlap
# --force permits overlap.
"$SLIPWAY" reserved add 4050 4200 overlap --force >/dev/null
got=$("$SLIPWAY" conflicts 4075)
# Both app and reserved should hit.
if [[ "$got" == *"app1"* && "$got" == *"reserved"* ]]; then
  echo "  ok: --force allows overlap, both entries visible"
  pass=$((pass + 1))
else
  echo "  FAIL: overlap with --force: $got"
  fail=$((fail + 1))
fi

echo "# release --if-claimed"
fresh_registry
assert_exit 3 "plain release of unknown app fails" "$SLIPWAY" release ghost
# --if-claimed should not fail on unknown app.
out=$("$SLIPWAY" release --if-claimed ghost)
assert_eq "$out" "not claimed: ghost (noop)" "release --if-claimed is idempotent"
"$SLIPWAY" claim app1 100 >/dev/null
"$SLIPWAY" release --if-claimed app1 >/dev/null
assert_exit 3 "app gone after --if-claimed release" "$SLIPWAY" get app1

echo "# caddy fragment"
fresh_registry
"$SLIPWAY" claim webapp 100 >/dev/null
got=$("$SLIPWAY" caddy webapp)
if [[ "$got" == *"dev.webapp.localhost"* && "$got" == *"reverse_proxy localhost:4000"* ]]; then
  echo "  ok: caddy default subdomain + offset 0"
  pass=$((pass + 1))
else
  echo "  FAIL: caddy output: $got"
  fail=$((fail + 1))
fi
got=$("$SLIPWAY" caddy webapp prod 5)
if [[ "$got" == *"prod.webapp.localhost"* && "$got" == *"reverse_proxy localhost:4005"* ]]; then
  echo "  ok: caddy custom subdomain + offset"
  pass=$((pass + 1))
else
  echo "  FAIL: caddy custom: $got"
  fail=$((fail + 1))
fi
assert_exit 2 "caddy offset out of range (E_USAGE)" "$SLIPWAY" caddy webapp dev 200
assert_exit 3 "caddy on unknown app (E_NOTFOUND)" "$SLIPWAY" caddy ghost

echo "# doctor: healthy registry"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
out=$("$SLIPWAY" doctor)
if [[ "$out" == *"registry healthy"* ]]; then
  echo "  ok: healthy registry passes doctor"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor healthy: $out"
  fail=$((fail + 1))
fi

echo "# doctor: detects orphaned lock"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "9999999" > "$SLIPWAY_REGISTRY.lock/pid"   # dead pid
out=$("$SLIPWAY" doctor || true)
if [[ "$out" == *"orphaned lock"* ]]; then
  echo "  ok: doctor flags orphaned lock"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor orphan: $out"
  fail=$((fail + 1))
fi
rm -rf "$SLIPWAY_REGISTRY.lock"

echo "# doctor: detects overlapping app/reserved"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null                      # 4000-4099
"$SLIPWAY" reserved add 4050 4200 overlap --force >/dev/null
out=$("$SLIPWAY" doctor || true)
if [[ "$out" == *"overlapping"* ]]; then
  echo "  ok: doctor flags overlap"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor overlap: $out"
  fail=$((fail + 1))
fi

echo "# doctor --repair removes orphaned lock"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "9999999" > "$SLIPWAY_REGISTRY.lock/pid"
out=$("$SLIPWAY" doctor --repair)
if [[ "$out" == *"repaired"* ]] && [[ ! -d "$SLIPWAY_REGISTRY.lock" ]]; then
  echo "  ok: --repair cleared orphan lock"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor --repair output: $out"
  fail=$((fail + 1))
fi

echo "# version"
out=$("$SLIPWAY" version)
if [[ "$out" =~ ^slipway\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "  ok: version prints 'slipway X.Y.Z'"
  pass=$((pass + 1))
else
  echo "  FAIL: version: $out"
  fail=$((fail + 1))
fi
# `version` must work even when the registry is missing/broken.
SLIPWAY_REGISTRY=/nonexistent/nope.json "$SLIPWAY" version >/dev/null
pass=$((pass + 1))
echo "  ok: version works without a readable registry"

echo "# port subcommand"
fresh_registry
"$SLIPWAY" claim app1 10 >/dev/null                        # 4000-4009
assert_eq "$("$SLIPWAY" port app1)"    "4000" "port default offset = start"
assert_eq "$("$SLIPWAY" port app1 3)"  "4003" "port with offset"
assert_eq "$("$SLIPWAY" port app1 9)"  "4009" "port at max offset"
assert_exit 2 "port offset past end (E_USAGE)" "$SLIPWAY" port app1 10
assert_exit 3 "port on unknown app (E_NOTFOUND)" "$SLIPWAY" port ghost

echo "# config show + port-range"
fresh_registry
out=$("$SLIPWAY" config show)
if [[ "$out" == *"port_range: 4000-9999"* && "$out" == *"registry_version: 1"* ]]; then
  echo "  ok: config show"
  pass=$((pass + 1))
else
  echo "  FAIL: config show: $out"
  fail=$((fail + 1))
fi
"$SLIPWAY" claim app1 100 >/dev/null                        # 4000-4099
# Shrinking port_range to exclude app1 must fail.
assert_exit 6 "config port-range refuses orphan (E_CONFLICT)" "$SLIPWAY" config port-range 5000 6000
# Widening port_range should succeed (no orphans).
"$SLIPWAY" config port-range 4000 10000 >/dev/null
out=$("$SLIPWAY" config show)
if [[ "$out" == *"port_range: 4000-10000"* ]]; then
  echo "  ok: config port-range widened"
  pass=$((pass + 1))
else
  echo "  FAIL: config port-range: $out"
  fail=$((fail + 1))
fi

echo "# reclaim --no-move"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null                        # 4000-4099 (100-aligned)
# Grow in place: 4000 is 200-aligned, 4100-4199 is free → OK.
got=$("$SLIPWAY" reclaim app1 200 --no-move)
assert_eq "$got" "4000 4199" "reclaim --no-move grows in place"
# Shrink in place: 4000 is 50-aligned, no collisions → OK.
got=$("$SLIPWAY" reclaim app1 50 --no-move)
assert_eq "$got" "4000 4049" "reclaim --no-move shrinks in place"

echo "# reclaim --no-move refuses when alignment/collision forces a move"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null                        # 4000-4099
"$SLIPWAY" claim app2 100 >/dev/null                        # 4100-4199
# app1 growth to 200 would need 4000-4199, but app2 blocks.
assert_exit 6 "reclaim --no-move refuses on collision (E_CONFLICT)" "$SLIPWAY" reclaim app1 200 --no-move
# app1 is unchanged after the failed reclaim.
assert_eq "$("$SLIPWAY" get app1)" "4000 4099" "app1 unchanged after failed --no-move reclaim"
# Non-aligned starts can't reclaim in place at a larger alignment.
fresh_registry
"$SLIPWAY" claim app1 50 >/dev/null                         # 4000-4049
"$SLIPWAY" claim padding 50 >/dev/null                      # 4050-4099
"$SLIPWAY" reclaim padding 100 >/dev/null                   # padding moves to 4100-4199
# Now claim into a non-aligned-to-200 start via reserved forcing:
# Actually 4000 IS 200-aligned. Simpler test: use size 75 (not a power of 2).
fresh_registry
"$SLIPWAY" reserved add 4000 4049 pad --force >/dev/null
"$SLIPWAY" claim app1 50 >/dev/null                         # 4050-4099 (50-aligned, not 100-aligned)
assert_exit 6 "reclaim --no-move refuses on misalignment" "$SLIPWAY" reclaim app1 100 --no-move

echo "# SLIPWAY_LIB override"
fresh_registry
altlib=$(mktemp -d)
cp "$SCRIPT_DIR/../lib/slipway/commands.sh" "$altlib/my-cmds.sh"
SLIPWAY_LIB="$altlib/my-cmds.sh" "$SLIPWAY" claim alt 100 >/dev/null
assert_eq "$("$SLIPWAY" get alt)" "4000 4099" "SLIPWAY_LIB override resolves to custom path"
assert_exit 1 "missing SLIPWAY_LIB dies clearly" env SLIPWAY_LIB=/no/such/file.sh "$SLIPWAY" list
rm -rf "$altlib"

echo "# SLIPWAY_DEBUG emits traces"
fresh_registry
dbg=$(SLIPWAY_DEBUG=1 "$SLIPWAY" claim app1 100 2>&1 >/dev/null)
if [[ "$dbg" == *"slipway[debug]"* ]]; then
  echo "  ok: SLIPWAY_DEBUG emits traces to stderr"
  pass=$((pass + 1))
else
  echo "  FAIL: SLIPWAY_DEBUG no traces: $dbg"
  fail=$((fail + 1))
fi

echo "# allocator: exact fit at port_range.end vs one-past"
fresh_registry
# Shrink port_range + clear reserved to build a clean boundary scenario:
# [4000, 4099] = exactly two size-50 slots (4000-4049, 4050-4099).
"$SLIPWAY" reserved remove 5000 >/dev/null
"$SLIPWAY" reserved remove 7000 >/dev/null
"$SLIPWAY" config port-range 4000 4099 >/dev/null
assert_eq "$("$SLIPWAY" claim edge1 50)" "4000 4049" "first 50-slot fits at range start"
assert_eq "$("$SLIPWAY" claim edge2 50)" "4050 4099" "second 50-slot fits exactly at port_range.end"
assert_exit 4 "one more 50-slot exhausts (E_EXHAUSTED)" "$SLIPWAY" claim edge3 50

echo "# reclaim --no-move refuses when growth would exceed port_range.end"
fresh_registry
"$SLIPWAY" reserved remove 5000 >/dev/null
"$SLIPWAY" reserved remove 7000 >/dev/null
"$SLIPWAY" config port-range 4000 4199 >/dev/null
"$SLIPWAY" claim app1 100 >/dev/null                # 4000-4099
# Grow in place to 200 would want 4000-4199 — still fits exactly.
"$SLIPWAY" reclaim app1 200 --no-move >/dev/null
# Growing to 400 (4000 is 400-aligned) would want 4000-4399 — exceeds
# port_range.end=4199 → E_EXHAUSTED (distinct from size-mismatch E_CONFLICT).
assert_exit 4 "reclaim --no-move past port_range.end (E_EXHAUSTED)" "$SLIPWAY" reclaim app1 400 --no-move

echo "# help and version work with a broken registry"
# Corrupt-registry path should not block `help` or `version`.
broken=$(mktemp)
echo "this is not json" > "$broken"
SLIPWAY_REGISTRY="$broken" "$SLIPWAY" version >/dev/null
pass=$((pass + 1)); echo "  ok: version works with broken registry"
SLIPWAY_REGISTRY="$broken" "$SLIPWAY" --help >/dev/null
pass=$((pass + 1)); echo "  ok: --help works with broken registry"
SLIPWAY_REGISTRY="$broken" "$SLIPWAY" help >/dev/null
pass=$((pass + 1)); echo "  ok: help works with broken registry"
rm -f "$broken"

echo "# doctor --repair is a noop on healthy registry"
fresh_registry
out=$("$SLIPWAY" doctor --repair)
if [[ "$out" == *"registry healthy"* ]] && [[ "$out" != *"repaired"* ]]; then
  echo "  ok: --repair on healthy registry is a noop"
  pass=$((pass + 1))
else
  echo "  FAIL: --repair healthy: $out"
  fail=$((fail + 1))
fi

echo "# doctor --repair refuses to clear a live lock"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "$$" > "$SLIPWAY_REGISTRY.lock/pid"   # our own PID = live
out=$("$SLIPWAY" doctor --repair)
if [[ "$out" == *"live pid"* ]] && [[ -d "$SLIPWAY_REGISTRY.lock" ]]; then
  echo "  ok: --repair leaves live lock alone"
  pass=$((pass + 1))
else
  echo "  FAIL: --repair live: $out (dir exists=$([[ -d "$SLIPWAY_REGISTRY.lock" ]] && echo yes || echo no))"
  fail=$((fail + 1))
fi
rm -rf "$SLIPWAY_REGISTRY.lock"

echo "# config port-range rejects invalid input"
fresh_registry
assert_exit 2 "config port-range rejects non-numeric" "$SLIPWAY" config port-range foo 9999
assert_exit 2 "config port-range rejects reversed"    "$SLIPWAY" config port-range 9000 4000
# Narrowing that still contains all claims and reserveds succeeds.
"$SLIPWAY" reserved remove 5000 >/dev/null
"$SLIPWAY" reserved remove 7000 >/dev/null
"$SLIPWAY" claim narrow 100 >/dev/null              # 4000-4099
"$SLIPWAY" config port-range 4000 5000 >/dev/null
out=$("$SLIPWAY" config show)
if [[ "$out" == *"port_range: 4000-5000"* ]]; then
  echo "  ok: narrowing port_range that still contains apps"
  pass=$((pass + 1))
else
  echo "  FAIL: config narrow: $out"
  fail=$((fail + 1))
fi

echo "# config port-range refuses to orphan reserved entries"
fresh_registry
# Reserved 5000 and 7000 are in the default registry.
assert_exit 6 "config port-range orphaning reserved (E_CONFLICT)" "$SLIPWAY" config port-range 4000 4999

echo "# port rejects non-integer offset"
fresh_registry
"$SLIPWAY" claim app1 10 >/dev/null
assert_exit 2 "port with non-integer offset (E_USAGE)" "$SLIPWAY" port app1 abc

echo "# ensure --json emits same shape on same-size noop"
fresh_registry
fresh=$("$SLIPWAY" ensure app1 100 --json)
noop=$("$SLIPWAY"  ensure app1 100 --json)
assert_eq "$fresh" "$noop" "ensure --json shape is stable between fresh claim and noop"

echo "# allocator correctness under dense occupancy (regression for single-jq rewrite)"
fresh_registry
# Claim 20 apps back-to-back and verify they tile the range correctly,
# skipping the 5000 and 7000 reserved ports.
for i in $(seq 1 20); do "$SLIPWAY" claim "dense$i" 100 >/dev/null; done
# Spot checks:
assert_eq "$("$SLIPWAY" get dense1)"  "4000 4099" "first claim at range start"
# After 10 claims of 100 at 4000-4999 we'd hit the 5000 reserved port.
# dense11 should skip to 5100 (size 100 aligned; reserved 5000 lies in 5000-5099).
assert_eq "$("$SLIPWAY" get dense11)" "5100 5199" "allocator skips reserved 5000"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
