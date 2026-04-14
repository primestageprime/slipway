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
assert_exit 1 "get after release fails" "$SLIPWAY" get app1

echo "# alignment"
fresh_registry
assert_eq "$("$SLIPWAY" claim big 1000)" "4000 4999" "size 1000 aligns on 1000-boundary"
assert_eq "$("$SLIPWAY" claim small 50)" "5050 5099" "size 50 aligns on 50-boundary, skips reserved"

echo "# no double-claim"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
assert_exit 1 "claim existing app fails" "$SLIPWAY" claim app1 100

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
assert_exit 1 "reserved add with missing args fails" "$SLIPWAY" reserved add 8000
assert_exit 1 "reserved remove non-existent fails" "$SLIPWAY" reserved remove 9999

echo "# range exhaustion"
fresh_registry
"$SLIPWAY" claim big 1000 >/dev/null
assert_exit 1 "oversized claim fails cleanly" "$SLIPWAY" claim huge 999999

echo "# dry-run"
fresh_registry
assert_eq "$("$SLIPWAY" claim app1 100 --dry-run)" "would claim: 4000 4099" "dry-run prints would-claim"
assert_exit 1 "dry-run did not persist" "$SLIPWAY" get app1

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
assert_exit 1 "reclaim of unknown app fails" "$SLIPWAY" reclaim ghost 100

echo "# conflicts"
fresh_registry
"$SLIPWAY" claim app1 100 >/dev/null
assert_exit 0 "conflicts finds app" "$SLIPWAY" conflicts 4050
assert_exit 0 "conflicts finds reserved" "$SLIPWAY" conflicts 5000
assert_exit 1 "conflicts on free port exits 1" "$SLIPWAY" conflicts 9000
assert_exit 1 "conflicts requires numeric port" "$SLIPWAY" conflicts abc

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
assert_exit 1 "invalid schema is rejected" "$SLIPWAY" list

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
assert_exit 1 "dry-run on claimed app fails" "$SLIPWAY" claim already 100 --dry-run

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
assert_exit 1 "reclaim with impossible size fails" "$SLIPWAY" reclaim app1 999999
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
SLIPWAY_LOCK_TIMEOUT_DS=3 assert_exit 1 "acquire times out on live holder" "$SLIPWAY" claim app1 100
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
assert_exit 1 "conflicts on out-of-range port reports free" "$SLIPWAY" conflicts 15000

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
