#!/usr/bin/env bash
# Sort matched log lines by timestamp, annotate with anchor step labels,
# mark time gaps, and fold repeated stack frames.
# Usage: log-reconstruct.sh --logs <matched.log> --anchors <anchors.txt> --out <seq.txt>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
LOGS_FILE=""
ANCHORS_FILE=""
OUT_FILE=""
GAP_THRESHOLD=10    # seconds; gaps larger than this are highlighted

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs)      LOGS_FILE="$2";    shift 2 ;;
    --anchors)   ANCHORS_FILE="$2"; shift 2 ;;
    --out)       OUT_FILE="$2";     shift 2 ;;
    --gap-sec)   GAP_THRESHOLD="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$LOGS_FILE" ]]    && die "--logs is required"
[[ -z "$ANCHORS_FILE" ]] && die "--anchors is required"
[[ -z "$OUT_FILE" ]]     && die "--out is required"
[[ ! -f "$LOGS_FILE" ]]    && die "Logs file not found: $LOGS_FILE"
[[ ! -f "$ANCHORS_FILE" ]] && die "Anchors file not found: $ANCHORS_FILE"

# ── Step 1: Sort log lines by embedded timestamp ──────────────────────────────
info "Sorting log lines by timestamp ..."

# Extract timestamp prefix for sort key; lines without timestamps go last.
sort -s -t']' -k2,2 "$LOGS_FILE" > "$WORK_DIR/sorted.log"

# ── Step 2: Fold duplicate stack trace lines ──────────────────────────────────
info "Folding repeated stack frames ..."

awk -v threshold="$STACK_FOLD_THRESHOLD" '
  /^\s+(at |Caused by:)/ {
    if ($0 == prev_stack) {
      stack_count++
      next
    }
    if (stack_count >= threshold) {
      print "    ... (repeated " stack_count " times)"
    }
    prev_stack = $0
    stack_count = 1
    print
    next
  }
  {
    if (stack_count >= threshold) {
      print "    ... (repeated " stack_count " times)"
    }
    prev_stack = ""
    stack_count = 0
    print
  }
' "$WORK_DIR/sorted.log" > "$WORK_DIR/folded.log"

# ── Step 3: Annotate each line with matching anchor step ─────────────────────
info "Annotating anchor steps ..."

# Build awk pattern array from anchors file.
# anchors.txt format (produced by LLM Phase 1):
#   step1: keyword_pattern
#   step2: keyword_pattern
#   ...
awk -v anchors_file="$ANCHORS_FILE" -v gap_sec="$GAP_THRESHOLD" '
BEGIN {
  step_count = 0
  while ((getline line < anchors_file) > 0) {
    if (line ~ /^step[0-9]+:/) {
      split(line, parts, /:\s*/)
      step_labels[step_count] = parts[1]
      step_patterns[step_count] = parts[2]
      step_count++
    }
  }
  close(anchors_file)
  prev_ts_epoch = -1
  OFS = ""
}

function ts_to_epoch(ts,    cmd, ep) {
  cmd = "date -d \"" ts "\" +%s 2>/dev/null"
  cmd | getline ep
  close(cmd)
  return (ep+0)
}

{
  line = $0
  # Extract timestamp
  ts = ""
  if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
    ts = substr(line, RSTART, RLENGTH)
    gsub("T", " ", ts)
  }

  # Compute gap
  if (ts != "") {
    curr_epoch = ts_to_epoch(ts)
    if (prev_ts_epoch > 0 && curr_epoch > 0) {
      gap = curr_epoch - prev_ts_epoch
      if (gap > gap_sec) {
        printf "\n  ⚠ GAP %ds between %s and %s\n\n", gap, prev_ts_label, ts
      }
    }
    prev_ts_epoch = curr_epoch
    prev_ts_label = ts
  }

  # Match against anchor patterns
  matched_step = ""
  for (i = 0; i < step_count; i++) {
    if (index(tolower(line), tolower(step_patterns[i])) > 0) {
      matched_step = "  [✓ " step_labels[i] "]"
      break
    }
  }

  print line matched_step
}
' "$WORK_DIR/folded.log" > "$OUT_FILE"

# ── Step 4: Append missing-step summary ──────────────────────────────────────
{
  echo ""
  echo "═══════════════════════════════════════"
  echo "ANCHOR COVERAGE SUMMARY"
  echo "═══════════════════════════════════════"

  while IFS= read -r anchor_line; do
    [[ "$anchor_line" =~ ^step[0-9]+: ]] || continue
    step_label="${anchor_line%%:*}"
    keyword="${anchor_line#*: }"
    if grep -qi "$keyword" "$WORK_DIR/folded.log" 2>/dev/null; then
      echo "  ✓ $step_label : $keyword"
    else
      echo "  ✗ $step_label : $keyword  ← MISSING"
    fi
  done < "$ANCHORS_FILE"
} >> "$OUT_FILE"

info "Reconstructed execution sequence → $OUT_FILE"
