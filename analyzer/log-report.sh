#!/usr/bin/env bash
# Feed flow anchors + execution sequence to LLM for gap analysis; write report.
# Usage: log-report.sh --anchors <file> --seq <file> --out <report.md> \
#                      --provider <p> --model <m> --api-key <k>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
ANCHORS_FILE=""
SEQ_FILE=""
OUT_FILE=""
PROVIDER=""
MODEL=""
API_KEY=""
ENDPOINT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --anchors)   ANCHORS_FILE="$2";  shift 2 ;;
    --seq)       SEQ_FILE="$2";      shift 2 ;;
    --out)       OUT_FILE="$2";      shift 2 ;;
    --provider)  PROVIDER="$2";      shift 2 ;;
    --model)     MODEL="$2";         shift 2 ;;
    --api-key)   API_KEY="$2";       shift 2 ;;
    --endpoint)  ENDPOINT="$2";      shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$ANCHORS_FILE" ]] && die "--anchors is required"
[[ -z "$SEQ_FILE" ]]     && die "--seq is required"
[[ -z "$OUT_FILE" ]]     && die "--out is required"
[[ -z "$PROVIDER" ]]     && die "--provider is required"

# ── Compose final prompt ──────────────────────────────────────────────────────
info "Composing gap-analysis prompt ..."

final_input="$(cat <<INPUT
=== EXPECTED BUSINESS FLOW (from code analysis) ===
$(cat "$ANCHORS_FILE")

=== ACTUAL EXECUTION SEQUENCE (from logs) ===
$(cat "$SEQ_FILE")
INPUT
)"

# ── Call LLM for final gap analysis ──────────────────────────────────────────
info "Calling LLM for root cause analysis (provider: $PROVIDER) ..."

llm_args=(
  --provider "$PROVIDER"
  --prompt-type "final"
)
[[ -n "$MODEL" ]]    && llm_args+=(--model    "$MODEL")
[[ -n "$API_KEY" ]]  && llm_args+=(--api-key  "$API_KEY")
[[ -n "$ENDPOINT" ]] && llm_args+=(--endpoint "$ENDPOINT")

llm_output="$(echo "$final_input" | "$SCRIPT_DIR/log-llm.sh" "${llm_args[@]}")"

# ── Write report ──────────────────────────────────────────────────────────────
{
  echo "# Incident Analysis Report"
  echo ""
  echo "> Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "> Provider: $PROVIDER | Model: ${MODEL:-default}"
  echo ""
  echo "---"
  echo ""
  echo "$llm_output"
  echo ""
  echo "---"
  echo ""
  echo "## Raw Execution Sequence"
  echo ""
  echo '```'
  cat "$SEQ_FILE"
  echo '```'
} > "$OUT_FILE"

info "Report written → $OUT_FILE"
