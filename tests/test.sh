#!/usr/bin/env bash
# Test suite for slipway v2 (per-port claims).
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

echo "# fresh registry has v2 schema"
fresh_registry
assert_eq "$(jq -r '.registry_version' "$SLIPWAY_REGISTRY")" "2" "registry_version is 2"
assert_eq "$(jq -r '.auto_pool.start' "$SLIPWAY_REGISTRY")" "4000" "auto_pool.start is 4000"
assert_eq "$(jq -r '.auto_pool.end' "$SLIPWAY_REGISTRY")" "9999" "auto_pool.end is 9999"
assert_eq "$(jq -r '.claims | length' "$SLIPWAY_REGISTRY")" "0" "claims is empty"
assert_eq "$(jq -r '.reserved[0].port' "$SLIPWAY_REGISTRY")" "5000" "reserved[0] has port field"
# Ensure no old v1 fields
assert_eq "$(jq -r '.port_range // "absent"' "$SLIPWAY_REGISTRY")" "absent" "no port_range field"
assert_eq "$(jq -r '.apps // "absent"' "$SLIPWAY_REGISTRY")" "absent" "no apps field"

echo "# v1 → v2 migration"
fresh_registry
# Build a v1 registry manually
cat > "$SLIPWAY_REGISTRY" <<'JSON'
{
  "registry_version": 1,
  "port_range": { "start": 4000, "end": 9999 },
  "reserved": [
    { "start": 5000, "end": 5000, "note": "macOS AirPlay" }
  ],
  "apps": {
    "dside": { "start": 5200, "end": 5299 },
    "other": { "start": 6000, "end": 6099 }
  }
}
JSON
"$SLIPWAY" list >/dev/null   # triggers migration
assert_eq "$(jq -r '.registry_version' "$SLIPWAY_REGISTRY")" "2" "migrated to v2"
assert_eq "$(jq -r '.auto_pool.start' "$SLIPWAY_REGISTRY")" "4000" "auto_pool.start preserved"
assert_eq "$(jq -r '.auto_pool.end' "$SLIPWAY_REGISTRY")" "9999" "auto_pool.end preserved"
assert_eq "$(jq -r '.claims.dside.port' "$SLIPWAY_REGISTRY")" "5200" "dside claim port = old start"
assert_eq "$(jq -r '.claims.other.port' "$SLIPWAY_REGISTRY")" "6000" "other claim port = old start"
assert_eq "$(jq -r '.reserved[0].port' "$SLIPWAY_REGISTRY")" "5000" "reserved migrated to single port"
assert_eq "$(jq -r '.reserved[0].note' "$SLIPWAY_REGISTRY")" "macOS AirPlay" "reserved note preserved"
# Old fields should be gone
assert_eq "$(jq -r '.port_range // "absent"' "$SLIPWAY_REGISTRY")" "absent" "port_range removed"
assert_eq "$(jq -r '.apps // "absent"' "$SLIPWAY_REGISTRY")" "absent" "apps removed"

echo "# v0 → v2 migration"
fresh_registry
# Build a v0 registry (no registry_version)
cat > "$SLIPWAY_REGISTRY" <<'JSON'
{
  "port_range": { "start": 4000, "end": 9999 },
  "reserved": [],
  "apps": { "old": { "start": 4000, "end": 4099 } }
}
JSON
"$SLIPWAY" list >/dev/null
assert_eq "$(jq -r '.registry_version' "$SLIPWAY_REGISTRY")" "2" "v0 migrated to v2"
assert_eq "$(jq -r '.claims.old.port' "$SLIPWAY_REGISTRY")" "4000" "v0 app migrated to claim"

echo "# basic claim/get/release"
fresh_registry
assert_eq "$("$SLIPWAY" claim app1)" "4000" "first auto-claim gets lowest port"
assert_eq "$("$SLIPWAY" get app1)" "4000" "get returns claimed port"
"$SLIPWAY" release app1 >/dev/null
assert_exit 3 "get after release fails (E_NOTFOUND)" "$SLIPWAY" get app1

echo "# claim with explicit --port"
fresh_registry
assert_eq "$("$SLIPWAY" claim myapp --port 8080)" "8080" "explicit port claim"
assert_eq "$("$SLIPWAY" get myapp)" "8080" "get returns explicit port"

echo "# claim --port outside auto_pool works"
fresh_registry
assert_eq "$("$SLIPWAY" claim outside --port 3000)" "3000" "port 3000 outside auto_pool accepted"
assert_eq "$("$SLIPWAY" get outside)" "3000" "get returns port outside auto_pool"

echo "# reject port <= 1024"
fresh_registry
assert_exit 2 "port 80 rejected (E_USAGE)" "$SLIPWAY" claim web --port 80
assert_exit 2 "port 1024 rejected (E_USAGE)" "$SLIPWAY" claim web --port 1024
assert_exit 2 "port 0 rejected (E_USAGE)" "$SLIPWAY" claim web --port 0

echo "# no double-claim (same name)"
fresh_registry
"$SLIPWAY" claim app1 >/dev/null
assert_exit 6 "claim existing name fails (E_CONFLICT)" "$SLIPWAY" claim app1

echo "# no double-claim (same port)"
fresh_registry
"$SLIPWAY" claim app1 --port 8080 >/dev/null
assert_exit 6 "claim existing port fails (E_CONFLICT)" "$SLIPWAY" claim app2 --port 8080

echo "# auto-claim skips reserved and already-claimed ports"
fresh_registry
# Default reserved: 5000 and 7000. Claim ports to fill up to 4999.
# Instead, let's test with a small pool.
"$SLIPWAY" config auto-pool 4000 4005 >/dev/null
"$SLIPWAY" reserved add 4002 "test" >/dev/null
"$SLIPWAY" claim a1 >/dev/null   # 4000
"$SLIPWAY" claim a2 >/dev/null   # 4001
# 4002 is reserved, so next should be 4003
assert_eq "$("$SLIPWAY" claim a3)" "4003" "auto-claim skips reserved 4002"
"$SLIPWAY" claim a4 >/dev/null   # 4004
# 5000 and 7000 are also reserved but outside pool; 4005 is free
assert_eq "$("$SLIPWAY" claim a5)" "4005" "auto-claim gets 4005"

echo "# release --if-claimed"
fresh_registry
assert_exit 3 "plain release of unknown name fails" "$SLIPWAY" release ghost
out=$("$SLIPWAY" release --if-claimed ghost)
assert_eq "$out" "not claimed: ghost (noop)" "release --if-claimed is idempotent"
"$SLIPWAY" claim app1 >/dev/null
"$SLIPWAY" release --if-claimed app1 >/dev/null
assert_exit 3 "app gone after --if-claimed release" "$SLIPWAY" get app1

echo "# list output"
fresh_registry
"$SLIPWAY" claim beta --port 5200 --desc "beta frontend" >/dev/null
"$SLIPWAY" claim alpha --port 4000 --desc "alpha service" >/dev/null
# Table list should have headers
out=$("$SLIPWAY" list)
if [[ "$out" == *"NAME"* && "$out" == *"PORT"* && "$out" == *"DESCRIPTION"* ]]; then
  echo "  ok: list table has headers"
  pass=$((pass + 1))
else
  echo "  FAIL: list table headers: $out"
  fail=$((fail + 1))
fi
# Sorted by port: alpha (4000) before beta (5200)
first_data=$(echo "$out" | tail -n +2 | head -1)
if [[ "$first_data" == *"alpha"* ]]; then
  echo "  ok: list sorted by port"
  pass=$((pass + 1))
else
  echo "  FAIL: list sort: $first_data"
  fail=$((fail + 1))
fi

echo "# list --json"
fresh_registry
"$SLIPWAY" claim app1 --port 4000 --desc "test" >/dev/null
got=$("$SLIPWAY" list --json)
expect=$(jq -c '.claims' "$SLIPWAY_REGISTRY")
assert_eq "$got" "$expect" "list --json matches .claims"

echo "# claim --json"
fresh_registry
got=$("$SLIPWAY" claim app1 --port 4000 --json)
assert_eq "$got" '{"name":"app1","port":4000}' "claim --json shape"

echo "# get --json"
fresh_registry
"$SLIPWAY" claim app1 --port 4000 >/dev/null
got=$("$SLIPWAY" get app1 --json)
assert_eq "$got" '{"name":"app1","port":4000}' "get --json shape"

echo "# claim --desc stores description"
fresh_registry
"$SLIPWAY" claim myapp --port 5200 --desc "my frontend" >/dev/null
assert_eq "$(jq -r '.claims.myapp.description' "$SLIPWAY_REGISTRY")" "my frontend" "description stored"

echo "# claim --dry-run"
fresh_registry
got=$("$SLIPWAY" claim app1 --dry-run)
assert_eq "$got" "would claim: 4000" "dry-run prints would-claim with auto port"
assert_exit 3 "dry-run did not persist" "$SLIPWAY" get app1
# dry-run with explicit port
got=$("$SLIPWAY" claim app2 --port 8080 --dry-run)
assert_eq "$got" "would claim: 8080" "dry-run with explicit port"
# dry-run --json
got=$("$SLIPWAY" claim app3 --port 9000 --dry-run --json)
assert_eq "$got" '{"name":"app3","port":9000,"dry_run":true}' "dry-run --json shape"

echo "# dry-run rejects already-claimed name"
fresh_registry
"$SLIPWAY" claim already >/dev/null
assert_exit 6 "dry-run on claimed name fails (E_CONFLICT)" "$SLIPWAY" claim already --dry-run

echo "# auto-pool exhaustion; explicit --port still works"
fresh_registry
"$SLIPWAY" config auto-pool 4000 4001 >/dev/null
"$SLIPWAY" claim a1 >/dev/null   # 4000
"$SLIPWAY" claim a2 >/dev/null   # 4001
assert_exit 4 "auto-claim exhausted (E_EXHAUSTED)" "$SLIPWAY" claim a3
# Explicit --port outside pool still works
assert_eq "$("$SLIPWAY" claim a3 --port 9000)" "9000" "explicit port works when pool exhausted"

echo "# conflicts"
fresh_registry
"$SLIPWAY" claim app1 --port 4050 >/dev/null
assert_exit 0 "conflicts finds claim" "$SLIPWAY" conflicts 4050
assert_exit 0 "conflicts finds reserved" "$SLIPWAY" conflicts 5000
assert_exit 3 "conflicts on free port exits E_NOTFOUND" "$SLIPWAY" conflicts 9000
assert_exit 2 "conflicts requires numeric port (E_USAGE)" "$SLIPWAY" conflicts abc

echo "# conflicts --json"
fresh_registry
"$SLIPWAY" claim app1 --port 4050 >/dev/null
got=$("$SLIPWAY" conflicts 4050 --json)
expect='[{"kind":"claim","name":"app1","port":4050}]'
assert_eq "$got" "$expect" "conflicts --json for claim hit"
got=$("$SLIPWAY" conflicts 5000 --json)
if echo "$got" | jq -e '.[0].kind == "reserved"' >/dev/null 2>&1; then
  echo "  ok: conflicts --json for reserved hit"
  pass=$((pass + 1))
else
  echo "  FAIL: conflicts --json reserved: $got"
  fail=$((fail + 1))
fi
assert_exit 3 "conflicts --json for free port exits E_NOTFOUND" "$SLIPWAY" conflicts 9000 --json

echo "# reserved add/remove (single port)"
fresh_registry
"$SLIPWAY" reserved add 8080 "test service" >/dev/null
got=$(jq -r '.reserved[] | select(.port == 8080) | .note' "$SLIPWAY_REGISTRY")
assert_eq "$got" "test service" "reserved add stores note"
"$SLIPWAY" reserved remove 8080 >/dev/null
got=$(jq -r '[.reserved[] | select(.port == 8080)] | length' "$SLIPWAY_REGISTRY")
assert_eq "$got" "0" "reserved remove deletes entry"
assert_exit 3 "reserved remove non-existent fails (E_NOTFOUND)" "$SLIPWAY" reserved remove 9999
assert_exit 2 "reserved add with missing args fails (E_USAGE)" "$SLIPWAY" reserved add

echo "# reserved list"
fresh_registry
out=$("$SLIPWAY" reserved list)
if [[ "$out" == *"PORT"* && "$out" == *"NOTE"* ]]; then
  echo "  ok: reserved list has headers"
  pass=$((pass + 1))
else
  echo "  FAIL: reserved list headers: $out"
  fail=$((fail + 1))
fi
# --json
got=$("$SLIPWAY" reserved list --json)
expect=$(jq -c '.reserved // []' "$SLIPWAY_REGISTRY")
assert_eq "$got" "$expect" "reserved --json matches .reserved"

echo "# config show"
fresh_registry
out=$("$SLIPWAY" config show)
if [[ "$out" == *"auto_pool: 4000-9999"* && "$out" == *"registry_version: 2"* ]]; then
  echo "  ok: config show"
  pass=$((pass + 1))
else
  echo "  FAIL: config show: $out"
  fail=$((fail + 1))
fi

echo "# config auto-pool"
fresh_registry
"$SLIPWAY" config auto-pool 5000 8000 >/dev/null
out=$("$SLIPWAY" config show)
if [[ "$out" == *"auto_pool: 5000-8000"* ]]; then
  echo "  ok: config auto-pool updated"
  pass=$((pass + 1))
else
  echo "  FAIL: config auto-pool: $out"
  fail=$((fail + 1))
fi
assert_exit 2 "config auto-pool rejects non-numeric" "$SLIPWAY" config auto-pool foo 9999
assert_exit 2 "config auto-pool rejects reversed" "$SLIPWAY" config auto-pool 9000 4000

echo "# schema validation"
fresh_registry
echo '{"bogus": true}' > "$SLIPWAY_REGISTRY"
assert_exit 7 "invalid schema is rejected (E_SCHEMA)" "$SLIPWAY" list

echo "# newer registry_version is rejected"
fresh_registry
tmpreg=$(mktemp)
jq '.registry_version = 99' "$SLIPWAY_REGISTRY" > "$tmpreg" && mv "$tmpreg" "$SLIPWAY_REGISTRY"
assert_exit 1 "future registry_version rejected" "$SLIPWAY" list

echo "# stale lock recovery"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "9999999" > "$SLIPWAY_REGISTRY.lock/pid"  # PID that cannot exist
assert_eq "$("$SLIPWAY" claim app1)" "4000" "claim reclaims stale lock"
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
SLIPWAY_LOCK_TIMEOUT_DS=3 assert_exit 5 "acquire times out on live holder (E_LOCK)" "$SLIPWAY" claim app1
rm -rf "$SLIPWAY_REGISTRY.lock"

echo "# concurrent claims do not overlap"
fresh_registry
N=30
pids=()
outdir=$(mktemp -d)
for i in $(seq 1 $N); do
  ("$SLIPWAY" claim "concurrent$i" > "$outdir/$i" 2>&1) &
  pids+=("$!")
done
all_ok=0
for p in "${pids[@]}"; do
  wait "$p" || all_ok=1
done
assert_eq "$all_ok" "0" "all concurrent claims succeeded"
# Check no duplicates: all ports unique
overlap=0
sort -n "$outdir"/* | uniq -d | read -r dup && overlap=1 || true
assert_eq "$overlap" "0" "no duplicate ports across concurrent claims"
claimed=$("$SLIPWAY" list | tail -n +2 | wc -l | tr -d ' ')
assert_eq "$claimed" "$N" "registry has all $N concurrent claims"
rm -rf "$outdir"

echo "# version"
out=$("$SLIPWAY" version)
assert_eq "$out" "slipway 1.0.0" "version prints slipway 1.0.0"
# version must work even when the registry is missing/broken.
SLIPWAY_REGISTRY=/nonexistent/nope.json "$SLIPWAY" version >/dev/null
pass=$((pass + 1))
echo "  ok: version works without a readable registry"

echo "# help and version work with a broken registry"
broken=$(mktemp)
echo "this is not json" > "$broken"
SLIPWAY_REGISTRY="$broken" "$SLIPWAY" version >/dev/null
pass=$((pass + 1)); echo "  ok: version works with broken registry"
SLIPWAY_REGISTRY="$broken" "$SLIPWAY" --help >/dev/null
pass=$((pass + 1)); echo "  ok: --help works with broken registry"
SLIPWAY_REGISTRY="$broken" "$SLIPWAY" help >/dev/null
pass=$((pass + 1)); echo "  ok: help works with broken registry"
rm -f "$broken"

echo "# SLIPWAY_LIB override"
fresh_registry
altlib=$(mktemp -d)
cp "$SCRIPT_DIR/../lib/slipway/commands.sh" "$altlib/my-cmds.sh"
SLIPWAY_LIB="$altlib/my-cmds.sh" "$SLIPWAY" claim alt >/dev/null
assert_eq "$("$SLIPWAY" get alt)" "4000" "SLIPWAY_LIB override resolves to custom path"
assert_exit 1 "missing SLIPWAY_LIB dies clearly" env SLIPWAY_LIB=/no/such/file.sh "$SLIPWAY" list
rm -rf "$altlib"

echo "# SLIPWAY_DEBUG emits traces"
fresh_registry
dbg=$(SLIPWAY_DEBUG=1 "$SLIPWAY" claim app1 2>&1 >/dev/null)
if [[ "$dbg" == *"slipway[debug]"* ]]; then
  echo "  ok: SLIPWAY_DEBUG emits traces to stderr"
  pass=$((pass + 1))
else
  echo "  FAIL: SLIPWAY_DEBUG no traces: $dbg"
  fail=$((fail + 1))
fi

echo "# check: port free"
fresh_registry
"$SLIPWAY" claim highport --port 19876 >/dev/null
out=$("$SLIPWAY" check highport)
assert_eq "$out" "ok: port 19876 (highport) is free" "check free port"

echo "# check: unclaimed name → E_NOTFOUND"
fresh_registry
assert_exit 3 "check unclaimed name exits E_NOTFOUND" "$SLIPWAY" check nonexistent

echo "# check: missing name → E_USAGE"
fresh_registry
assert_exit 2 "check with no args exits E_USAGE" "$SLIPWAY" check

echo "# doctor: runs and includes expected sections"
fresh_registry
out=$("$SLIPWAY" doctor 2>&1 || true)
if [[ "$out" == *"no outstanding lock"* ]]; then
  echo "  ok: doctor reports lock status"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor lock status: $out"
  fail=$((fail + 1))
fi
if [[ "$out" == *"no duplicate ports in claims"* ]]; then
  echo "  ok: doctor reports no duplicate ports"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor duplicate ports: $out"
  fail=$((fail + 1))
fi
if [[ "$out" == *"--- listening ports ---"* ]]; then
  echo "  ok: doctor output includes listening ports section"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor listening ports section missing: $out"
  fail=$((fail + 1))
fi
if [[ "$out" == *"--- stale claims ---"* ]]; then
  echo "  ok: doctor output includes stale claims section"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor stale claims section missing: $out"
  fail=$((fail + 1))
fi

echo "# doctor: orphaned lock detection"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "9999999" > "$SLIPWAY_REGISTRY.lock/pid"
out=$("$SLIPWAY" doctor 2>&1 || true)
if [[ "$out" == *"WARN: orphaned lock"* ]]; then
  echo "  ok: doctor detects orphaned lock"
  pass=$((pass + 1))
else
  echo "  FAIL: doctor orphaned lock: $out"
  fail=$((fail + 1))
fi
rm -rf "$SLIPWAY_REGISTRY.lock"

echo "# doctor --repair removes orphaned lock"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "9999999" > "$SLIPWAY_REGISTRY.lock/pid"
out=$("$SLIPWAY" doctor --repair 2>&1 || true)
if [[ "$out" == *"repaired: removed orphaned lock"* ]]; then
  echo "  ok: --repair removes orphaned lock"
  pass=$((pass + 1))
else
  echo "  FAIL: --repair orphaned lock: $out"
  fail=$((fail + 1))
fi
if [[ ! -d "$SLIPWAY_REGISTRY.lock" ]]; then
  echo "  ok: lock directory removed after repair"
  pass=$((pass + 1))
else
  echo "  FAIL: lock directory still exists after repair"
  fail=$((fail + 1))
fi

echo "# doctor --repair is noop on healthy registry"
fresh_registry
out=$("$SLIPWAY" doctor --repair 2>&1 || true)
if [[ "$out" == *"no outstanding lock"* && "$out" == *"no duplicate ports"* ]]; then
  echo "  ok: --repair noop on healthy registry"
  pass=$((pass + 1))
else
  echo "  FAIL: --repair noop: $out"
  fail=$((fail + 1))
fi

echo "# doctor --repair refuses to clear live lock"
fresh_registry
mkdir "$SLIPWAY_REGISTRY.lock"
echo "$$" > "$SLIPWAY_REGISTRY.lock/pid"
out=$("$SLIPWAY" doctor --repair 2>&1 || true)
if [[ "$out" == *"ok: lock held by live pid"* || "$out" == *"ok: lock reclaimed by live process"* ]]; then
  echo "  ok: --repair does not remove live lock"
  pass=$((pass + 1))
else
  echo "  FAIL: --repair live lock: $out"
  fail=$((fail + 1))
fi
rm -rf "$SLIPWAY_REGISTRY.lock"

echo "# list --tsv"
fresh_registry
"$SLIPWAY" claim app1 --port 4000 --desc "test service" >/dev/null
got=$("$SLIPWAY" list --tsv)
first_line=$(echo "$got" | head -1)
assert_eq "$first_line" "$(printf 'NAME\tPORT\tDESCRIPTION')" "list --tsv header"
second_line=$(echo "$got" | tail -1)
assert_eq "$second_line" "$(printf 'app1\t4000\ttest service')" "list --tsv data row"

echo "# claim with reserved port rejected"
fresh_registry
assert_exit 6 "claim on reserved port rejected (E_CONFLICT)" "$SLIPWAY" claim blocked --port 5000

echo "# reserved add conflicting with existing claim"
fresh_registry
"$SLIPWAY" claim app1 --port 8080 >/dev/null
assert_exit 6 "reserved add on claimed port rejected (E_CONFLICT)" "$SLIPWAY" reserved add 8080 "conflict"
# Verify the reservation was not added
got=$(jq -r '[.reserved[] | select(.port == 8080)] | length' "$SLIPWAY_REGISTRY")
assert_eq "$got" "0" "conflicting reservation not persisted"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
