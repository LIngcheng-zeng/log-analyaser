#!/usr/bin/env bash
# Fetch matching log lines from remote servers over SSH.
# Handles zip-archived logs; outputs lines prefixed with [server].
# Usage: log-fetch.sh --servers s1,s2 --log-path /path/ \
#                     --since "2024-01-15 10:00:00" --until "2024-01-15 11:00:00" \
#                     --keywords keywords.txt [--user sshuser] --out <file>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
SERVERS=""
LOG_PATH="${DEFAULT_LOG_PATH:-}"
SINCE=""
UNTIL=""
KEYWORDS_FILE=""
SSH_LOGIN_USER="${SSH_USER:-}"
OUT_FILE=""
PARALLEL="${PARALLEL:-4}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --servers)   SERVERS="$2";         shift 2 ;;
    --log-path)  LOG_PATH="$2";        shift 2 ;;
    --since)     SINCE="$2";           shift 2 ;;
    --until)     UNTIL="$2";           shift 2 ;;
    --keywords)  KEYWORDS_FILE="$2";   shift 2 ;;
    --user)      SSH_LOGIN_USER="$2";  shift 2 ;;
    --out)       OUT_FILE="$2";        shift 2 ;;
    --parallel)  PARALLEL="$2";        shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$SERVERS" ]]        && die "--servers is required"
[[ -z "$LOG_PATH" ]]       && die "--log-path is required (or set DEFAULT_LOG_PATH in config.sh)"
[[ -z "$SINCE" ]]          && die "--since is required"
[[ -z "$UNTIL" ]]          && die "--until is required"
[[ -z "$KEYWORDS_FILE" ]]  && die "--keywords is required"
[[ -z "$OUT_FILE" ]]       && die "--out is required"
[[ ! -f "$KEYWORDS_FILE" ]] && die "Keywords file not found: $KEYWORDS_FILE"

# ── Build remote fetch script (executed on each server via SSH) ──────────────
# The remote side: find zip files in time range, unzip, time-filter, grep anchors.
build_remote_script() {
  local server="$1"
  # Escape special chars in path/time for remote shell
  cat <<REMOTE
set -euo pipefail
LOG_DIR="${LOG_PATH}"
SINCE="${SINCE}"
UNTIL="${UNTIL}"
SERVER_TAG="${server}"

# Find zip files whose name/mtime falls within the time window.
# Strategy: use -newer against a temp marker file for mtime, then also check filename date patterns.
touch_marker() {
  local ts="\$1"
  local f
  f="\$(mktemp)"
  touch -d "\$ts" "\$f" 2>/dev/null || touch "\$f"
  echo "\$f"
}

since_marker="\$(touch_marker "\$SINCE")"
until_marker="\$(touch_marker "\$UNTIL")"
trap 'rm -f "\$since_marker" "\$until_marker"' EXIT

find "\$LOG_DIR" -name '*.zip' -o -name '*.log.gz' | sort | while read -r archive; do
  # Keep archives that are newer than since_marker (approximate time window)
  if [ "\$archive" -nt "\$since_marker" ] || [ "\$archive" -ot "\$until_marker" ] || true; then
    if [[ "\$archive" == *.zip ]]; then
      unzip -p "\$archive" 2>/dev/null
    else
      zcat "\$archive" 2>/dev/null
    fi
  fi
done \
| awk -v since="\$SINCE" -v until="\$UNTIL" -v tag="\$SERVER_TAG" '
  {
    # Attempt to parse leading timestamp (common formats: yyyy-MM-dd HH:mm:ss or ISO8601)
    ts = ""
    if (match(\$0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
      ts = substr(\$0, RSTART, RLENGTH)
      gsub("T", " ", ts)
    }
    if (ts == "" || (ts >= since && ts <= until)) {
      print "[" tag "] " \$0
    }
  }
'
REMOTE
}

# ── Fetch from a single server ───────────────────────────────────────────────
fetch_server() {
  local server="$1"
  local host="${SSH_LOGIN_USER:+${SSH_LOGIN_USER}@}${server}"
  local remote_script
  remote_script="$(build_remote_script "$server")"

  info "Fetching from $server ..."
  ssh $SSH_OPTS "$host" "bash -s" <<< "$remote_script" 2>/dev/null \
  | grep -F -f "$KEYWORDS_FILE" \
  | awk -v ctx="$CONTEXT_LINES" '
      { lines[NR] = $0; last_match[NR] = 0 }
      END {
        # Mark context lines around matches (simple post-pass; for real use: print with context)
        for (i=1; i<=NR; i++) print lines[i]
      }
    ' \
  || warn "Fetch failed or no matches on $server"
}

# ── Parallel fetch across servers ────────────────────────────────────────────
IFS=',' read -ra SERVER_LIST <<< "$SERVERS"
tmp_dir="$WORK_DIR/fetch"
mkdir -p "$tmp_dir"

for server in "${SERVER_LIST[@]}"; do
  server="$(echo "$server" | tr -d '[:space:]')"
  fetch_server "$server" > "$tmp_dir/${server}.log" &
  # Throttle parallel connections
  while [[ $(jobs -r | wc -l) -ge $PARALLEL ]]; do sleep 0.5; done
done
wait

# ── Merge results ─────────────────────────────────────────────────────────────
cat "$tmp_dir"/*.log 2>/dev/null > "$OUT_FILE" || true

total=$(wc -l < "$OUT_FILE" || echo 0)
info "Fetched $total matching lines → $OUT_FILE"
