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

# ── Service → log path mapping ───────────────────────────────────────────────
# Add entries per microservice; --log-path flag overrides at runtime.
declare -A SERVICE_LOG_PATH=(
  # ["order-service"]="/var/log/order/"
  # ["user-service"]="/var/log/user/"
)

# ── SSH defaults ─────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH_USER="${SSH_USER:-}"  # set via --user or SSH_USER env

# ── Temp workspace (auto-cleaned on exit) ────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/log-analyzer-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Logging helpers ──────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }
