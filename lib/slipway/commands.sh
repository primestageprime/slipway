# slipway commands — sourced by bin/slipway. Not intended to be executed
# directly. Uses globals defined by the caller: REGISTRY, E_*, and helpers
# die / die_code / acquire_lock / write_unlocked / emit_claim / usage.
# shellcheck shell=bash disable=SC2016

# Find the lowest free port in auto_pool that is not claimed or reserved.
# Prints the port number; dies with E_EXHAUSTED if the pool is full.
allocate_port() {
  local out
  if ! out=$(jq -r '
    ([ (.claims // {} | .[].port), ((.reserved // [])[] | .port) ]
     | map({(tostring): true}) | add // {}) as $taken
    | .auto_pool.start as $lo
    | .auto_pool.end as $hi
    | first(range($lo; $hi + 1) | select($taken[tostring] | not))
    // null
    | if . == null then "EXHAUSTED \($lo) \($hi)"
      else "OK \(.)"
      end
  ' "$REGISTRY"); then
    die "allocate_port: jq failed (registry corrupt?)"
  fi
  [[ -n "$out" ]] || die "allocate_port: jq produced no output"
  local status port
  read -r status port <<<"$out"
  case "$status" in
    EXHAUSTED) die_code "$E_EXHAUSTED" "no free port in auto_pool" ;;
    OK) ;;
    *) die "allocate_port: unexpected jq output: $out" ;;
  esac
  echo "$port"
  debug "allocate_port: → $port"
}

cmd_claim() {
  local name="" port="" desc="" dry_run=0 json=0
  while (( $# )); do
    case "$1" in
      --port)    port="${2:-}"; [[ -n "$port" ]] || die_code "$E_USAGE" "--port requires a value"; shift 2 ;;
      --desc)    desc="${2:-}"; [[ -n "$desc" ]] || die_code "$E_USAGE" "--desc requires a value"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json)    json=1; shift ;;
      --) shift; break ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$name" ]]; then name="$1"
        else die_code "$E_USAGE" "too many arguments to claim"
        fi
        shift
        ;;
    esac
  done
  [[ -n "$name" ]] || usage

  # Validate explicit port
  if [[ -n "$port" ]]; then
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
      die_code "$E_USAGE" "port must be a positive integer"
    fi
    if (( port <= 1024 )); then
      die_code "$E_USAGE" "port must be > 1024 (got $port)"
    fi
  fi

  if (( dry_run == 0 )); then
    acquire_lock
  fi

  # Reject duplicate name
  if jq -e --arg n "$name" '.claims[$n]' "$REGISTRY" >/dev/null 2>&1; then
    die_code "$E_CONFLICT" "'$name' already claimed; use 'release' first or 'get' to look it up"
  fi

  # Reject duplicate port
  if [[ -n "$port" ]]; then
    local holder
    holder=$(jq -r --argjson p "$port" '
      .claims | to_entries[] | select(.value.port == $p) | .key
    ' "$REGISTRY")
    if [[ -n "$holder" ]]; then
      die_code "$E_CONFLICT" "port $port already claimed by '$holder'"
    fi
    # Check reserved
    if jq -e --argjson p "$port" '(.reserved // []) | any(.port == $p)' "$REGISTRY" >/dev/null 2>&1; then
      die_code "$E_CONFLICT" "port $port is reserved"
    fi
  fi

  # Auto-assign if no explicit port
  if [[ -z "$port" ]]; then
    port=$(allocate_port)
  fi

  if (( dry_run )); then
    if (( json == 1 )); then
      jq -nc --arg n "$name" --argjson p "$port" '{name:$n, port:$p, dry_run:true}'
    else
      echo "would claim: $port"
    fi
    return 0
  fi

  # Build the claim object
  if [[ -n "$desc" ]]; then
    write_unlocked --arg n "$name" --argjson p "$port" --arg d "$desc" \
      '.claims[$n] = {port: $p, description: $d}'
  else
    write_unlocked --arg n "$name" --argjson p "$port" \
      '.claims[$n] = {port: $p}'
  fi
  emit_claim "$name" "$port" "$json"
}

cmd_get() {
  local name="" json=0
  while (( $# )); do
    case "$1" in
      --json) json=1; shift ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || usage
  local port
  port=$(jq -r --arg n "$name" '.claims[$n].port // empty' "$REGISTRY")
  [[ -n "$port" ]] || die_code "$E_NOTFOUND" "no claim for '$name'"
  emit_claim "$name" "$port" "$json"
}

cmd_release() {
  local name="" if_claimed=0
  while (( $# )); do
    case "$1" in
      --if-claimed) if_claimed=1; shift ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || usage
  acquire_lock
  if ! jq -e --arg n "$name" '.claims[$n]' "$REGISTRY" >/dev/null 2>&1; then
    if (( if_claimed == 1 )); then
      echo "not claimed: $name (noop)"
      return 0
    fi
    die_code "$E_NOTFOUND" "no claim for '$name'"
  fi
  write_unlocked --arg n "$name" 'del(.claims[$n])'
  echo "released: $name"
}

cmd_list() {
  local format="table"
  case "${1:-}" in
    ""|--table) format="table" ;;
    --json)     format="json" ;;
    --tsv)      format="tsv" ;;
    *)          die_code "$E_USAGE" "unknown flag: $1" ;;
  esac
  case "$format" in
    json)
      jq -c '.claims' "$REGISTRY"
      ;;
    tsv)
      jq -r '
        .claims | to_entries | sort_by(.value.port)
        | (["NAME","PORT","DESCRIPTION"] | @tsv),
          (.[] | [.key, .value.port, (.value.description // "")] | @tsv)
      ' "$REGISTRY"
      ;;
    table)
      jq -r '
        .claims | to_entries | sort_by(.value.port)
        | (["NAME","PORT","DESCRIPTION"] | @tsv),
          (.[] | [.key, .value.port, (.value.description // "")] | @tsv)
      ' "$REGISTRY" | column -t -s $'\t'
      ;;
  esac
}

cmd_conflicts() {
  local port="" json=0
  while (( $# )); do
    case "$1" in
      --json) json=1; shift ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *) port="$1"; shift ;;
    esac
  done
  [[ -n "$port" ]] || die_code "$E_USAGE" "usage: slipway conflicts <port>"
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    die_code "$E_USAGE" "port must be an integer"
  fi
  if (( json == 1 )); then
    local hits_json
    hits_json=$(jq -c --argjson p "$port" '
      [ (.claims | to_entries[] | select(.value.port == $p)
         | {kind:"claim", name:.key, port:.value.port}),
        ((.reserved // [])[] | select(.port == $p)
         | {kind:"reserved", port}
           + (if .note then {note} else {} end))
      ]
    ' "$REGISTRY")
    echo "$hits_json"
    [[ "$hits_json" != "[]" ]] || return "$E_NOTFOUND"
    return 0
  fi
  local hits
  hits=$(jq -r --argjson p "$port" '
    [ (.claims | to_entries[] | select(.value.port == $p)
        | "claim\t" + .key + "\t" + (.value.port|tostring)),
      ((.reserved // [])[] | select(.port == $p)
        | "reserved\t(reserved)\t" + (.port|tostring)
          + (if .note then "\t" + .note else "" end))
    ] | .[]
  ' "$REGISTRY")
  if [[ -z "$hits" ]]; then
    echo "port $port is free"
    return "$E_NOTFOUND"
  fi
  printf '%s\n' "$hits" | column -t -s $'\t'
}

cmd_reserved() {
  local op="${1:-list}"
  case "$op" in
    ""|list)
      shift || true
      if [[ "${1:-}" == "--json" ]]; then
        jq -c '.reserved // []' "$REGISTRY"
        return 0
      fi
      jq -r '
        (.reserved // [])
        | (["PORT","NOTE"] | @tsv),
          (.[] | [.port, (.note // "")] | @tsv)
      ' "$REGISTRY" | column -t -s $'\t'
      ;;
    add)
      shift
      local positional=()
      while (( $# )); do
        case "$1" in
          -*) die_code "$E_USAGE" "unknown flag: $1" ;;
          *) positional+=("$1"); shift ;;
        esac
      done
      local port_arg="${positional[0]:-}" note="${positional[1]:-}"
      [[ -n "$port_arg" ]] || die_code "$E_USAGE" "usage: slipway reserved add <port> [note]"
      if ! [[ "$port_arg" =~ ^[0-9]+$ ]]; then
        die_code "$E_USAGE" "port must be an integer"
      fi
      acquire_lock
      # Check for conflicts with existing claims
      local claim_conflict
      claim_conflict=$(jq -r --argjson p "$port_arg" '
        .claims // {} | to_entries[] | select(.value.port == $p) | .key
      ' "$REGISTRY")
      if [[ -n "$claim_conflict" ]]; then
        die_code "$E_CONFLICT" "port $port_arg is claimed by '$claim_conflict'"
      fi
      # Check for duplicate reserved port
      if jq -e --argjson p "$port_arg" '(.reserved // []) | any(.port == $p)' "$REGISTRY" >/dev/null 2>&1; then
        die_code "$E_CONFLICT" "port $port_arg is already reserved"
      fi
      write_unlocked --argjson p "$port_arg" --arg n "$note" \
        '.reserved = ((.reserved // []) + [{port:$p} + (if $n == "" then {} else {note:$n} end)])
         | .reserved |= sort_by(.port)'
      echo "reserved: $port_arg${note:+ ($note)}"
      ;;
    remove|rm)
      local port_arg="${2:-}"
      [[ -n "$port_arg" ]] || die_code "$E_USAGE" "usage: slipway reserved remove <port>"
      if ! [[ "$port_arg" =~ ^[0-9]+$ ]]; then
        die_code "$E_USAGE" "port must be an integer"
      fi
      acquire_lock
      jq -e --argjson p "$port_arg" '(.reserved // []) | any(.port == $p)' "$REGISTRY" >/dev/null \
        || die_code "$E_NOTFOUND" "no reserved entry for port $port_arg"
      write_unlocked --argjson p "$port_arg" '.reserved = ((.reserved // []) | map(select(.port != $p)))'
      echo "removed reserved port $port_arg"
      ;;
    *)
      die_code "$E_USAGE" "unknown reserved subcommand: $op (expected: list, add, remove)"
      ;;
  esac
}

cmd_config() {
  local op="${1:-show}"
  case "$op" in
    show|"")
      jq -r '"auto_pool: \(.auto_pool.start)-\(.auto_pool.end)\nregistry_version: \(.registry_version)"' "$REGISTRY"
      ;;
    auto-pool)
      local s="${2:-}" e="${3:-}"
      [[ -n "$s" && -n "$e" ]] || die_code "$E_USAGE" "usage: slipway config auto-pool <start> <end>"
      if ! [[ "$s" =~ ^[0-9]+$ && "$e" =~ ^[0-9]+$ ]]; then
        die_code "$E_USAGE" "start and end must be integers"
      fi
      (( e >= s )) || die_code "$E_USAGE" "end must be >= start"
      acquire_lock
      local outside
      outside=$(jq -r --argjson s "$s" --argjson e "$e" '
        [.claims // {} | to_entries[] | select(.value.port < $s or .value.port > $e) | .key]
        | join(", ")
      ' "$REGISTRY")
      if [[ -n "$outside" ]]; then
        echo "note: claims outside new auto_pool: $outside" >&2
      fi
      write_unlocked --argjson s "$s" --argjson e "$e" '.auto_pool = {start:$s, end:$e}'
      echo "auto_pool: $s-$e"
      ;;
    *)
      die_code "$E_USAGE" "unknown config subcommand: $op (expected: show, auto-pool)"
      ;;
  esac
}

cmd_check() {
  local name="${1:-}"
  [[ -n "$name" ]] || die_code "$E_USAGE" "usage: slipway check <name>"
  local port
  port=$(jq -r --arg n "$name" '.claims[$n].port // empty' "$REGISTRY")
  [[ -n "$port" ]] || die_code "$E_NOTFOUND" "no claim for '$name'"
  command -v lsof >/dev/null || die "lsof not found in PATH (required for port checks)"

  local pid_info
  pid_info=$(lsof -ti:"$port" -sTCP:LISTEN 2>/dev/null || true)
  if [[ -z "$pid_info" ]]; then
    echo "ok: port $port ($name) is free"
    return 0
  fi

  local pid
  pid=$(echo "$pid_info" | head -1)
  local proc_name
  proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
  echo "CONFLICT: port $port ($name) in use by $proc_name (PID $pid)"
  return 1
}

cmd_doctor() {
  local repair=0
  case "${1:-}" in
    --repair) repair=1 ;;
    "") ;;
    *) die_code "$E_USAGE" "unknown flag: $1" ;;
  esac

  local issues=0

  # 1. Lock check
  local lock="${REGISTRY}.lock"
  if [[ -d "$lock" ]]; then
    local pid
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "ok: lock held by live pid $pid"
    elif (( repair == 1 )); then
      local pid2
      pid2=$(cat "$lock/pid" 2>/dev/null || true)
      if [[ "$pid" != "$pid2" ]] || { [[ -n "$pid2" ]] && kill -0 "$pid2" 2>/dev/null; }; then
        echo "ok: lock reclaimed by live process (pid=$pid2)"
      else
        local rm_err
        if ! rm_err=$(rm -rf "$lock" 2>&1); then
          die "cannot remove $lock: $rm_err"
        fi
        echo "repaired: removed orphaned lock at $lock (pid=${pid:-<empty>})"
      fi
    else
      echo "WARN: orphaned lock at $lock (pid=${pid:-<empty>}); re-run with --repair or rm -rf"
      issues=$((issues + 1))
    fi
  else
    echo "ok: no outstanding lock"
  fi

  # 2. Duplicate port check
  local dupes
  dupes=$(jq -r '
    [(.claims // {} | to_entries[] | {name: .key, port: .value.port})]
    | group_by(.port)
    | map(select(length > 1))
    | map("  port " + (.[0].port|tostring) + ": " + ([.[].name] | join(", ")))
    | .[]
  ' "$REGISTRY")
  if [[ -n "$dupes" ]]; then
    echo "WARN: duplicate ports in claims:"
    printf '%s\n' "$dupes"
    issues=$((issues + 1))
  else
    echo "ok: no duplicate ports in claims"
  fi

  # 3. Scan listening ports
  echo "--- listening ports ---"
  if ! command -v lsof >/dev/null; then
    echo "  WARN: lsof not found; skipping port scans"
    issues=$((issues + 1))
  else
    local listeners
    listeners=$(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null \
      | awk 'NR>1 { split($9, a, ":"); port=a[length(a)]; if (port+0 > 1024) print port, $1, $2 }' \
      | sort -t' ' -k1 -n -u || true)

    if [[ -z "$listeners" ]]; then
      echo "  (no TCP listeners above 1024)"
    else
      local claimed_json reserved_json
      claimed_json=$(jq -c '[.claims // {} | to_entries[] | {(.value.port|tostring): .key}] | add // {}' "$REGISTRY")
      reserved_json=$(jq -c '[(.reserved // [])[] | {(.port|tostring): (.note // "reserved")}] | add // {}' "$REGISTRY")

      local unknown_count=0
      while read -r port proc pid; do
        local owner
        owner=$(jq -r --arg p "$port" '.[$p] // empty' <<<"$claimed_json")
        if [[ -n "$owner" ]]; then
          echo "  ok: :$port — $owner ($proc, pid $pid)"
          continue
        fi
        owner=$(jq -r --arg p "$port" '.[$p] // empty' <<<"$reserved_json")
        if [[ -n "$owner" ]]; then
          echo "  ok: :$port — reserved ($owner) ($proc, pid $pid)"
          continue
        fi
        echo "  UNKNOWN: :$port — $proc (pid $pid) — not claimed or reserved"
        unknown_count=$((unknown_count + 1))
      done <<<"$listeners"

      if (( unknown_count > 0 )); then
        echo "  $unknown_count unknown listener(s) — consider: slipway claim <name> --port <N>"
        issues=$((issues + 1))
      else
        echo "  all listeners accounted for"
      fi
    fi

    # 4. Stale claims
    echo "--- stale claims ---"
    local stale_count=0
    local claim_ports
    claim_ports=$(jq -r '.claims // {} | to_entries[] | "\(.key) \(.value.port)"' "$REGISTRY")
    if [[ -z "$claim_ports" ]]; then
      echo "  (no claims)"
    else
      while read -r name port; do
        local pid_info
        pid_info=$(lsof -ti:"$port" -sTCP:LISTEN 2>/dev/null || true)
        if [[ -z "$pid_info" ]]; then
          echo "  idle: :$port — $name (nothing listening)"
          stale_count=$((stale_count + 1))
        fi
      done <<<"$claim_ports"
      if (( stale_count == 0 )); then
        echo "  all claims have active listeners"
      fi
    fi
  fi

  if (( issues == 0 )); then
    echo "registry healthy"
    return 0
  fi
  return "$E_GENERIC"
}
