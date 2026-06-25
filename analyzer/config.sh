#!/usr/bin/env bash
# Provider configuration and shared constants

# ── LLM Provider Endpoints ──────────────────────────────────────────────────
declare -A LLM_ENDPOINT=(
  ["minimax"]="https://api.minimax.chat/v1/text/chatcompletion_v2"
  ["claude"]="https://api.anthropic.com/v1/messages"
  ["ollama"]="http://localhost:11434/v1/chat/completions"
  ["openai"]="https://api.openai.com/v1/chat/completions"
)

# ── Default Models ───────────────────────────────────────────────────────────
declare -A LLM_DEFAULT_MODEL=(
  ["minimax"]="MiniMax-Text-01"
  ["claude"]="claude-sonnet-4-6"
  ["ollama"]="qwen2.5:14b"
  ["openai"]="gpt-4o"
)

# ── API Keys (override via env or --api-key flag) ────────────────────────────
MINIMAX_API_KEY="${MINIMAX_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

# ── Chunking ─────────────────────────────────────────────────────────────────
CHUNK_LINES=150          # lines per log chunk fed to LLM
CONTEXT_LINES=3          # lines of context kept around each matched anchor
STACK_FOLD_THRESHOLD=3   # repeat count before folding duplicate stack frames

# ── Call-chain scan depth ────────────────────────────────────────────────────
SCAN_DEPTH=2             # hops from entry function to trace related files

# ── Service registry ─────────────────────────────────────────────────────────
# Register each microservice here; all three maps are keyed by service name.
# CLI flags (--src, --log-path, --servers) take precedence over these defaults.
declare -A SERVICE_SRC_PATH=(
  # ["order-service"]="/app/order-service/src"
  # ["user-service"]="/app/user-service/src"
)

declare -A SERVICE_LOG_PATH=(
  # ["order-service"]="/var/log/order/"
  # ["user-service"]="/var/log/user/"
)

declare -A SERVICE_NAMESPACE=(
  # ["order-service"]="production"
  # ["user-service"]="production"
)
DEFAULT_NAMESPACE="default"

# ── Bastion SSH config (used by node-ip-finder to reach K8s API) ─────────────
# These are exported so find-nodes.sh inherits them when called as a subprocess.
export BASTION_IP="${BASTION_IP:-}"
export BASTION_SSH_USER="${BASTION_SSH_USER:-}"
export BASTION_SSH_PASSWORD="${BASTION_SSH_PASSWORD:-}"
export BASTION_EXCEL_PATH="${BASTION_EXCEL_PATH:-}"

# ── SSH defaults ─────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH_USER="${SSH_USER:-}"  # set via --user or SSH_USER env

# ── Temp workspace ───────────────────────────────────────────────────────────
# Cleaned on success; preserved on failure so intermediate files can be inspected.
WORK_DIR="$(mktemp -d /tmp/log-analyzer-XXXXXX)"
_PIPELINE_SUCCESS=0
trap '
  if [[ "$_PIPELINE_SUCCESS" == "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    echo "[INFO]  Pipeline did not complete successfully." >&2
    echo "[INFO]  Work dir preserved for inspection: $WORK_DIR" >&2
  fi
' EXIT

# ── Logging helpers ──────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }
