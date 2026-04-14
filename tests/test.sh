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

echo "# range exhaustion"
fresh_registry
"$SLIPWAY" claim big 1000 >/dev/null
assert_exit 1 "oversized claim fails cleanly" "$SLIPWAY" claim huge 999999

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
