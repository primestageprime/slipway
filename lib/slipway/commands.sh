# slipway commands — sourced by bin/slipway. Not intended to be executed
# directly. Uses globals defined by the caller: REGISTRY, E_*, and helpers
# die / die_code / acquire_lock / write_unlocked / emit_claim / usage.
# shellcheck shell=bash disable=SC2016

# Find the lowest free port in auto_pool that is not claimed or reserved.
# Prints the port number; dies with E_EXHAUSTED if the pool is full.
allocate_port() {
  local out
  if ! out=$(jq -r '
    .auto_pool.start as $lo
    | .auto_pool.end as $hi
    | ([.claims | to_entries[].value.port] + [(.reserved // [])[].port]) as $taken
    | (reduce range($lo; $hi + 1) as $p (null;
        if . != null then .
        elif ($taken | index($p)) then null
        else $p
        end))
    | if . == null then "EXHAUSTED"
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
          *) positional+=("$1"); shift ;;
        esac
      done
      local port_arg="${positional[0]:-}" note="${positional[1]:-}"
      [[ -n "$port_arg" ]] || die_code "$E_USAGE" "usage: slipway reserved add <port> [note]"
      if ! [[ "$port_arg" =~ ^[0-9]+$ ]]; then
        die_code "$E_USAGE" "port must be an integer"
      fi
      acquire_lock
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
      write_unlocked --argjson s "$s" --argjson e "$e" '.auto_pool = {start:$s, end:$e}'
      echo "auto_pool: $s-$e"
      ;;
    *)
      die_code "$E_USAGE" "unknown config subcommand: $op (expected: show, auto-pool)"
      ;;
  esac
}

cmd_check() {
  die "check not yet implemented"
}

cmd_doctor() {
  die "doctor not yet implemented"
}
