# slipway commands — sourced by bin/slipway. Not intended to be executed
# directly. Uses globals defined by the caller: REGISTRY, E_*, and helpers
# die / die_code / acquire_lock / write_unlocked / emit_allocation / usage.
# shellcheck shell=bash disable=SC2016

cmd_get() {
  local app="" json=0
  while (( $# )); do
    case "$1" in
      --json) json=1; shift ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *) app="$1"; shift ;;
    esac
  done
  [[ -n "$app" ]] || usage
  local start end
  start=$(jq -r --arg a "$app" '.apps[$a].start // empty' "$REGISTRY")
  end=$(jq -r --arg a "$app" '.apps[$a].end // empty' "$REGISTRY")
  [[ -n "$start" ]] || die_code "$E_NOTFOUND" "no allocation for '$app'"
  emit_allocation "$app" "$start" "$end" "$json"
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
      jq -c '.apps' "$REGISTRY"
      ;;
    tsv)
      jq -r '
        .apps | to_entries | sort_by(.value.start)
        | (["APP","START","END","SIZE"] | @tsv),
          (.[] | [.key, .value.start, .value.end, (.value.end - .value.start + 1)] | @tsv)
      ' "$REGISTRY"
      ;;
    table)
      jq -r '
        .apps | to_entries | sort_by(.value.start)
        | (["APP","START","END","SIZE"] | @tsv),
          (.[] | [.key, .value.start, .value.end, (.value.end - .value.start + 1)] | @tsv)
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
      [ (.apps | to_entries[] | select(.value.start <= $p and .value.end >= $p)
         | {kind:"app", name:.key, start:.value.start, end:.value.end}),
        ((.reserved // [])[] | select(.start <= $p and .end >= $p)
         | {kind:"reserved", name:"(reserved)", start, end}
           + (if .note then {note} else {} end))
      ]
    ' "$REGISTRY")
    echo "$hits_json"
    [[ "$hits_json" != "[]" ]] || return "$E_NOTFOUND"
    return 0
  fi
  local hits
  hits=$(jq -r --argjson p "$port" '
    [ (.apps | to_entries[] | select(.value.start <= $p and .value.end >= $p)
        | "app\t" + .key + "\t" + (.value.start|tostring) + "-" + (.value.end|tostring)),
      ((.reserved // [])[] | select(.start <= $p and .end >= $p)
        | "reserved\t(reserved)\t" + (.start|tostring) + "-" + (.end|tostring)
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
        | (["START","END","NOTE"] | @tsv),
          (.[] | [.start, .end, (.note // "")] | @tsv)
      ' "$REGISTRY" | column -t -s $'\t'
      ;;
    add)
      shift
      local force=0 positional=()
      while (( $# )); do
        case "$1" in
          --force) force=1; shift ;;
          *) positional+=("$1"); shift ;;
        esac
      done
      local start="${positional[0]:-}" end="${positional[1]:-}" note="${positional[2]:-}"
      [[ -n "$start" && -n "$end" ]] || die_code "$E_USAGE" "usage: slipway reserved add <start> <end> [note] [--force]"
      if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
        die_code "$E_USAGE" "start and end must be integers"
      fi
      (( end >= start )) || die_code "$E_USAGE" "end must be >= start"
      acquire_lock
      if (( force == 0 )); then
        local overlap
        overlap=$(jq -r --argjson s "$start" --argjson e "$end" '
          [.apps | to_entries[] | select(.value.start <= $e and .value.end >= $s) | .key]
          | join(",")
        ' "$REGISTRY")
        if [[ -n "$overlap" ]]; then
          die_code "$E_CONFLICT" "reservation $start-$end overlaps claimed app(s): $overlap (use --force to override)"
        fi
      fi
      write_unlocked --argjson s "$start" --argjson e "$end" --arg n "$note" \
        '.reserved = ((.reserved // []) + [{start:$s, end:$e} + (if $n == "" then {} else {note:$n} end)])
         | .reserved |= sort_by(.start)'
      echo "reserved: $start-$end${note:+ ($note)}"
      ;;
    remove|rm)
      local start="${2:-}"
      [[ -n "$start" ]] || die_code "$E_USAGE" "usage: slipway reserved remove <start>"
      if ! [[ "$start" =~ ^[0-9]+$ ]]; then
        die_code "$E_USAGE" "start must be an integer"
      fi
      acquire_lock
      jq -e --argjson s "$start" '(.reserved // []) | any(.start == $s)' "$REGISTRY" >/dev/null \
        || die_code "$E_NOTFOUND" "no reserved entry starting at $start"
      write_unlocked --argjson s "$start" '.reserved = ((.reserved // []) | map(select(.start != $s)))'
      echo "removed reserved entry starting at $start"
      ;;
    *)
      die_code "$E_USAGE" "unknown reserved subcommand: $op (expected: list, add, remove)"
      ;;
  esac
}

cmd_release() {
  local app="" if_claimed=0
  while (( $# )); do
    case "$1" in
      --if-claimed) if_claimed=1; shift ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *) app="$1"; shift ;;
    esac
  done
  [[ -n "$app" ]] || usage
  acquire_lock
  if ! jq -e --arg a "$app" '.apps[$a]' "$REGISTRY" >/dev/null; then
    if (( if_claimed == 1 )); then
      echo "not claimed: $app (noop)"
      return 0
    fi
    die_code "$E_NOTFOUND" "no allocation for '$app'"
  fi
  write_unlocked --arg a "$app" 'del(.apps[$a])'
  echo "released: $app"
}

# Core allocator: finds the next free size-aligned range.
# Sets globals: ALLOC_START, ALLOC_END. Dies on exhaustion.
# Optional arg: app name to exclude from "taken" (for reclaim).
allocate_range() {
  local size="$1" exclude="${2:-}"
  local range_start range_end
  range_start=$(jq -r '.port_range.start' "$REGISTRY")
  range_end=$(jq -r '.port_range.end' "$REGISTRY")

  local taken
  taken=$(jq -c --arg ex "$exclude" '
    ([.apps | to_entries[] | select(.key != $ex) | .value | {start, end}]
     + ((.reserved // []) | map({start, end})))
    | sort_by(.start)
  ' "$REGISTRY")

  local candidate=$range_start
  candidate=$(( ((candidate + size - 1) / size) * size ))

  local n i s e
  n=$(jq 'length' <<<"$taken")
  for (( i = 0; i < n; i++ )); do
    s=$(jq ".[$i].start" <<<"$taken")
    e=$(jq ".[$i].end" <<<"$taken")
    if (( candidate + size - 1 < s )); then
      break
    fi
    if (( candidate <= e )); then
      candidate=$(( ((e + 1 + size - 1) / size) * size ))
    fi
  done

  local new_end=$(( candidate + size - 1 ))
  (( new_end <= range_end )) || die_code "$E_EXHAUSTED" "no free range of size $size in [$range_start,$range_end]"
  ALLOC_START=$candidate
  ALLOC_END=$new_end
}

cmd_claim() {
  local app="" size="" dry_run=0 json=0
  while (( $# )); do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --json)    json=1; shift ;;
      --) shift; break ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$app" ]]; then app="$1"
        elif [[ -z "$size" ]]; then size="$1"
        else die_code "$E_USAGE" "too many arguments to claim"
        fi
        shift
        ;;
    esac
  done
  [[ -n "$app" && -n "$size" ]] || usage
  if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size <= 0 )); then
    die_code "$E_USAGE" "size must be a positive integer"
  fi

  if (( dry_run == 0 )); then
    acquire_lock
  fi

  if jq -e --arg a "$app" '.apps[$a]' "$REGISTRY" >/dev/null; then
    die_code "$E_CONFLICT" "'$app' already claimed; use 'release'/'reclaim'/'ensure' or 'get' to look it up"
  fi

  allocate_range "$size"

  if (( dry_run )); then
    if (( json == 1 )); then
      jq -nc --arg a "$app" --argjson s "$ALLOC_START" --argjson e "$ALLOC_END" \
        '{app:$a, start:$s, end:$e, size:($e - $s + 1), dry_run:true}'
    else
      echo "would claim: $ALLOC_START $ALLOC_END"
    fi
    return 0
  fi

  write_unlocked --arg a "$app" --argjson s "$ALLOC_START" --argjson e "$ALLOC_END" \
    '.apps[$a] = {start: $s, end: $e}'
  emit_allocation "$app" "$ALLOC_START" "$ALLOC_END" "$json"
}

cmd_reclaim() {
  local app="" size="" json=0
  while (( $# )); do
    case "$1" in
      --json) json=1; shift ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$app" ]]; then app="$1"
        elif [[ -z "$size" ]]; then size="$1"
        else die_code "$E_USAGE" "too many arguments to reclaim"
        fi
        shift
        ;;
    esac
  done
  [[ -n "$app" && -n "$size" ]] || die_code "$E_USAGE" "usage: slipway reclaim <app> <size>"
  if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size <= 0 )); then
    die_code "$E_USAGE" "size must be a positive integer"
  fi

  acquire_lock
  jq -e --arg a "$app" '.apps[$a]' "$REGISTRY" >/dev/null \
    || die_code "$E_NOTFOUND" "no allocation for '$app' (use 'claim' for new apps)"

  allocate_range "$size" "$app"

  write_unlocked --arg a "$app" --argjson s "$ALLOC_START" --argjson e "$ALLOC_END" \
    '.apps[$a] = {start: $s, end: $e}'
  emit_allocation "$app" "$ALLOC_START" "$ALLOC_END" "$json"
}

cmd_ensure() {
  local app="" size="" json=0
  while (( $# )); do
    case "$1" in
      --json) json=1; shift ;;
      -*) die_code "$E_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$app" ]]; then app="$1"
        elif [[ -z "$size" ]]; then size="$1"
        else die_code "$E_USAGE" "too many arguments to ensure"
        fi
        shift
        ;;
    esac
  done
  [[ -n "$app" && -n "$size" ]] || die_code "$E_USAGE" "usage: slipway ensure <app> <size>"
  if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size <= 0 )); then
    die_code "$E_USAGE" "size must be a positive integer"
  fi

  acquire_lock

  if jq -e --arg a "$app" '.apps[$a]' "$REGISTRY" >/dev/null; then
    local cur_start cur_end cur_size
    cur_start=$(jq -r --arg a "$app" '.apps[$a].start' "$REGISTRY")
    cur_end=$(jq -r --arg a "$app" '.apps[$a].end' "$REGISTRY")
    cur_size=$(( cur_end - cur_start + 1 ))
    if (( cur_size == size )); then
      emit_allocation "$app" "$cur_start" "$cur_end" "$json"
      return 0
    fi
    die_code "$E_CONFLICT" "'$app' already claimed with size $cur_size (requested $size); use 'reclaim' to resize"
  fi

  allocate_range "$size"
  write_unlocked --arg a "$app" --argjson s "$ALLOC_START" --argjson e "$ALLOC_END" \
    '.apps[$a] = {start: $s, end: $e}'
  emit_allocation "$app" "$ALLOC_START" "$ALLOC_END" "$json"
}

cmd_caddy() {
  local app="${1:-}" subdomain="${2:-dev}" offset="${3:-0}"
  [[ -n "$app" ]] || die_code "$E_USAGE" "usage: slipway caddy <app> [subdomain] [offset]"
  if ! [[ "$offset" =~ ^[0-9]+$ ]]; then
    die_code "$E_USAGE" "offset must be a non-negative integer"
  fi
  local start end
  start=$(jq -r --arg a "$app" '.apps[$a].start // empty' "$REGISTRY")
  [[ -n "$start" ]] || die_code "$E_NOTFOUND" "no allocation for '$app'"
  end=$(jq -r --arg a "$app" '.apps[$a].end' "$REGISTRY")
  local port=$(( start + offset ))
  (( port <= end )) || die_code "$E_USAGE" "offset $offset puts port $port beyond app range ($start-$end)"
  cat <<EOF
${subdomain}.${app}.localhost {
  reverse_proxy localhost:${port}
}
EOF
}

cmd_doctor() {
  local issues=0
  local range_start range_end
  range_start=$(jq -r '.port_range.start' "$REGISTRY")
  range_end=$(jq -r '.port_range.end' "$REGISTRY")

  # 1. Outstanding lock
  local lock="${REGISTRY}.lock"
  if [[ -d "$lock" ]]; then
    local pid
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "ok: lock held by live pid $pid"
    else
      echo "WARN: orphaned lock at $lock (pid=${pid:-<empty>}); rm -rf to clear"
      issues=$((issues + 1))
    fi
  else
    echo "ok: no outstanding lock"
  fi

  # 2. Apps outside port_range
  local bad_range
  bad_range=$(jq -r --argjson lo "$range_start" --argjson hi "$range_end" '
    .apps | to_entries[] | select(.value.start < $lo or .value.end > $hi) | .key
  ' "$REGISTRY")
  if [[ -n "$bad_range" ]]; then
    echo "WARN: apps outside port_range ($range_start-$range_end):"
    printf '%s\n' "$bad_range" | sed 's/^/  /'
    issues=$((issues + 1))
  else
    echo "ok: all apps within port_range"
  fi

  # 3. Overlapping ranges (any pair in sorted order where A.end >= B.start)
  local overlaps
  overlaps=$(jq -r '
    ([.apps | to_entries[] | {kind:"app", name:.key, start:.value.start, end:.value.end}]
     + ((.reserved // []) | map({kind:"reserved", name:"(reserved)", start, end})))
    | sort_by(.start) as $all
    | [range(0; ($all | length) - 1)]
    | map(. as $i
          | select($all[$i].end >= $all[$i+1].start)
          | "  " + $all[$i].name + " [" + ($all[$i].start|tostring) + "-" + ($all[$i].end|tostring) + "] ↔ "
            + $all[$i+1].name + " [" + ($all[$i+1].start|tostring) + "-" + ($all[$i+1].end|tostring) + "]")
    | .[]
  ' "$REGISTRY")
  if [[ -n "$overlaps" ]]; then
    echo "WARN: overlapping ranges:"
    printf '%s\n' "$overlaps"
    issues=$((issues + 1))
  else
    echo "ok: no overlapping ranges"
  fi

  if (( issues == 0 )); then
    echo "registry healthy"
    return 0
  fi
  return "$E_GENERIC"
}
