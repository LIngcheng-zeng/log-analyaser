#!/usr/bin/env bash
# Trace call chain from entry function, extract log statements from related files.
# Usage: code-scan.sh --entry <func> --src <dir> [--depth N] --out <file>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
ENTRY_FUNC=""
SRC_DIR=""
DEPTH="${SCAN_DEPTH}"
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry)  ENTRY_FUNC="$2"; shift 2 ;;
    --src)    SRC_DIR="$2";    shift 2 ;;
    --depth)  DEPTH="$2";      shift 2 ;;
    --out)    OUT_FILE="$2";   shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$ENTRY_FUNC" ]] && die "--entry is required"
[[ -z "$SRC_DIR" ]]    && die "--src is required"
[[ -z "$OUT_FILE" ]]   && die "--out is required"
[[ ! -d "$SRC_DIR" ]]  && die "Source directory not found: $SRC_DIR"

# ── Step 1: Find files containing the entry function ─────────────────────────
info "Scanning entry function: $ENTRY_FUNC"

mapfile -t entry_files < <(
  grep -rl "$ENTRY_FUNC" "$SRC_DIR" 2>/dev/null || true
)

if [[ ${#entry_files[@]} -eq 0 ]]; then
  die "Entry function '$ENTRY_FUNC' not found under $SRC_DIR"
fi
info "Found ${#entry_files[@]} file(s) containing '$ENTRY_FUNC'"

# ── Step 2: Expand call chain N hops ─────────────────────────────────────────
# Extract class/service/component names referenced in found files,
# then find files implementing those names.

declare -A related_files
for f in "${entry_files[@]}"; do
  related_files["$f"]=1
done

current_files=("${entry_files[@]}")

for (( hop=1; hop<=DEPTH; hop++ )); do
  info "Call-chain hop $hop / $DEPTH ..."

  # Extract identifiers that look like injected beans / called services
  # Heuristic: UpperCamelCase words before '.' or used as type declarations
  mapfile -t new_symbols < <(
    grep -hP '\b[A-Z][a-zA-Z]*(Service|Repository|Client|Mapper|Dao|Manager|Handler|Util|Helper)\b' \
      "${current_files[@]}" 2>/dev/null \
    | grep -oP '\b[A-Z][a-zA-Z]*(Service|Repository|Client|Mapper|Dao|Manager|Handler|Util|Helper)\b' \
    | sort -u
  )

  [[ ${#new_symbols[@]} -eq 0 ]] && break

  next_files=()
  for sym in "${new_symbols[@]}"; do
    while IFS= read -r f; do
      if [[ -z "${related_files[$f]+_}" ]]; then
        related_files["$f"]=1
        next_files+=("$f")
      fi
    done < <(grep -rl "$sym" "$SRC_DIR" 2>/dev/null || true)
  done

  [[ ${#next_files[@]} -eq 0 ]] && break
  current_files=("${next_files[@]}")
done

info "Total related files: ${#related_files[@]}"

# ── Step 3: Extract log statements from all related files ─────────────────────
info "Extracting log statements ..."

{
  echo "# Entry function: $ENTRY_FUNC"
  echo "# Source directory: $SRC_DIR"
  echo "# Related files: ${#related_files[@]}"
  echo "# Generated: $(date -Iseconds)"
  echo ""

  for f in "${!related_files[@]}"; do
    # Match common logging patterns: log.info/warn/error/debug, logger.xxx, LOG.xxx
    grep -nP '(log|logger|LOG)\.(info|warn|warning|error|debug|trace)\s*\(' "$f" 2>/dev/null \
    | while IFS=: read -r lineno content; do
        # Strip leading whitespace, normalize
        content="$(echo "$content" | sed 's/^\s*//')"
        echo "${f##"$SRC_DIR/"}:${lineno}: ${content}"
      done
  done
} | sort -t: -k1,1 -k2,2n > "$OUT_FILE"

total=$(grep -c '\.java\|\.go\|\.py\|\.ts\|\.js' "$OUT_FILE" 2>/dev/null || echo 0)
info "Extracted log statements written to: $OUT_FILE ($total lines)"
