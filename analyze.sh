#!/usr/bin/env bash
# Main entry point: orchestrates full pipeline from code scan to incident report.
#
# Usage:
#   ./analyze.sh \
#     --entry    "createOrder"                          \
#     --src      "./src"                                \
#     --servers  "app01,app02"                          \
#     --log-path "/var/log/app/"                        \
#     --since    "2024-01-15 10:00:00"                  \
#     --until    "2024-01-15 11:00:00"                  \
#     --provider minimax                                \
#     --api-key  "$MINIMAX_API_KEY"                     \
#     --model    "MiniMax-Text-01"                      \
#     --output   "./reports/incident.md"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
ENTRY_FUNC=""
SRC_DIR=""
SERVERS=""
LOG_PATH=""
SINCE=""
UNTIL=""
SSH_USER_ARG=""
PROVIDER=""
API_KEY_ARG=""
MODEL_ARG=""
ENDPOINT_ARG=""
OUTPUT_FILE="./incident-report.md"
SCAN_DEPTH_ARG="$SCAN_DEPTH"

usage() {
  cat <<EOF
Usage: $0 --entry <func> --src <dir> --servers <list> --log-path <path>
          --since <datetime> --until <datetime>
          --provider <minimax|claude|ollama|openai>
          [--api-key <key>] [--model <model>] [--endpoint <url>]
          [--user <ssh-user>] [--depth <N>] [--output <file>]
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry)     ENTRY_FUNC="$2";      shift 2 ;;
    --src)       SRC_DIR="$2";         shift 2 ;;
    --servers)   SERVERS="$2";         shift 2 ;;
    --log-path)  LOG_PATH="$2";        shift 2 ;;
    --since)     SINCE="$2";           shift 2 ;;
    --until)     UNTIL="$2";           shift 2 ;;
    --user)      SSH_USER_ARG="$2";    shift 2 ;;
    --provider)  PROVIDER="$2";        shift 2 ;;
    --api-key)   API_KEY_ARG="$2";     shift 2 ;;
    --model)     MODEL_ARG="$2";       shift 2 ;;
    --endpoint)  ENDPOINT_ARG="$2";    shift 2 ;;
    --output)    OUTPUT_FILE="$2";     shift 2 ;;
    --depth)     SCAN_DEPTH_ARG="$2";  shift 2 ;;
    -h|--help)   usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$ENTRY_FUNC" ]] && { error "--entry is required"; usage; }
[[ -z "$SRC_DIR" ]]    && { error "--src is required";   usage; }
[[ -z "$SERVERS" ]]    && { error "--servers is required"; usage; }
[[ -z "$LOG_PATH" ]]   && { error "--log-path is required"; usage; }
[[ -z "$SINCE" ]]      && { error "--since is required"; usage; }
[[ -z "$UNTIL" ]]      && { error "--until is required"; usage; }
[[ -z "$PROVIDER" ]]   && { error "--provider is required"; usage; }

mkdir -p "$(dirname "$OUTPUT_FILE")"

# ── Build shared LLM args ─────────────────────────────────────────────────────
llm_common_args=(--provider "$PROVIDER")
[[ -n "$API_KEY_ARG"  ]] && llm_common_args+=(--api-key  "$API_KEY_ARG")
[[ -n "$MODEL_ARG"    ]] && llm_common_args+=(--model    "$MODEL_ARG")
[[ -n "$ENDPOINT_ARG" ]] && llm_common_args+=(--endpoint "$ENDPOINT_ARG")

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Code scan: trace call chain, extract log statements
# ══════════════════════════════════════════════════════════════════════════════
info "━━━ STEP 1/5: Code scan (entry: $ENTRY_FUNC) ━━━"

raw_log_stmts="$WORK_DIR/raw_log_statements.txt"

"$SCRIPT_DIR/code-scan.sh" \
  --entry  "$ENTRY_FUNC" \
  --src    "$SRC_DIR" \
  --depth  "$SCAN_DEPTH_ARG" \
  --out    "$raw_log_stmts"

[[ ! -s "$raw_log_stmts" ]] && die "No log statements found — check --entry and --src"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — LLM Phase 1: infer ordered flow anchors from log statements
# ══════════════════════════════════════════════════════════════════════════════
info "━━━ STEP 2/5: LLM Phase 1 — inferring flow anchors ━━━"

flow_anchors="$WORK_DIR/flow_anchors.txt"
keywords_file="$WORK_DIR/keywords.txt"

phase1_system='You are an expert Java SRE. You will receive a list of log statements extracted from source code (format: file:line: log statement).
Your task:
1. Infer the business execution order of these log statements based on filename, class names, and log message semantics.
2. Output ONLY a plain list in this exact format (no explanation, no markdown):
   step1: <keyword_to_grep>
   step2: <keyword_to_grep>
   ...
Each keyword must be a short, unique substring that would match only that log line in real log output.
Focus on the happy path + key branch points. Max 15 steps.'

echo "$(cat "$raw_log_stmts")" \
  | "$SCRIPT_DIR/log-llm.sh" \
      "${llm_common_args[@]}" \
      --system "$phase1_system" \
      --prompt-type chunk \
  > "$flow_anchors"

[[ ! -s "$flow_anchors" ]] && die "LLM Phase 1 returned empty output"

# Extract raw keywords for grep
grep -oP '(?<=:\s)\S.*' "$flow_anchors" > "$keywords_file" || true

info "Flow anchors:"
cat "$flow_anchors" >&2

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Fetch matching log lines from remote servers
# ══════════════════════════════════════════════════════════════════════════════
info "━━━ STEP 3/5: Fetching logs from [$SERVERS] ━━━"

matched_logs="$WORK_DIR/matched_logs.txt"

fetch_args=(
  --servers   "$SERVERS"
  --log-path  "$LOG_PATH"
  --since     "$SINCE"
  --until     "$UNTIL"
  --keywords  "$keywords_file"
  --out       "$matched_logs"
)
[[ -n "$SSH_USER_ARG" ]] && fetch_args+=(--user "$SSH_USER_ARG")

"$SCRIPT_DIR/log-fetch.sh" "${fetch_args[@]}"

if [[ ! -s "$matched_logs" ]]; then
  warn "No matching log lines found. Possible causes:"
  warn "  1. Time window too narrow"
  warn "  2. Anchor keywords do not match actual log format"
  warn "  3. Logs not yet archived to zip in this time range"
  # Write a minimal report instead of dying
  echo "# Incident Analysis Report" > "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
  echo "**No matching log lines found for the given time window and entry function.**" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
  echo "## Flow Anchors Searched" >> "$OUTPUT_FILE"
  cat "$flow_anchors" >> "$OUTPUT_FILE"
  info "Partial report written → $OUTPUT_FILE"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Reconstruct execution sequence
# ══════════════════════════════════════════════════════════════════════════════
info "━━━ STEP 4/5: Reconstructing execution sequence ━━━"

exec_seq="$WORK_DIR/execution_seq.txt"

"$SCRIPT_DIR/log-reconstruct.sh" \
  --logs    "$matched_logs" \
  --anchors "$flow_anchors" \
  --out     "$exec_seq"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — LLM Phase 2: gap analysis → incident report
# ══════════════════════════════════════════════════════════════════════════════
info "━━━ STEP 5/5: LLM Phase 2 — gap analysis & report ━━━"

"$SCRIPT_DIR/log-report.sh" \
  --anchors  "$flow_anchors" \
  --seq      "$exec_seq" \
  --out      "$OUTPUT_FILE" \
  "${llm_common_args[@]}"

echo ""
info "✓ Analysis complete. Report: $OUTPUT_FILE"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
head -60 "$OUTPUT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
