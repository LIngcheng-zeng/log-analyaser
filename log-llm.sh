#!/usr/bin/env bash
# Call local/remote LLM with provider-specific curl format.
# Usage: echo "$log_text" | log-llm.sh --provider <p> --model <m> \
#                            --api-key <k> --endpoint <url> \
#                            --system <system_prompt> --prompt-type <chunk|final>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
PROVIDER=""
MODEL=""
API_KEY=""
ENDPOINT=""
SYSTEM_PROMPT=""
PROMPT_TYPE="chunk"   # chunk | final

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)   PROVIDER="$2";       shift 2 ;;
    --model)      MODEL="$2";          shift 2 ;;
    --api-key)    API_KEY="$2";        shift 2 ;;
    --endpoint)   ENDPOINT="$2";       shift 2 ;;
    --system)     SYSTEM_PROMPT="$2";  shift 2 ;;
    --prompt-type) PROMPT_TYPE="$2";   shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$PROVIDER" ]] && die "--provider is required"

# ── Resolve defaults ─────────────────────────────────────────────────────────
ENDPOINT="${ENDPOINT:-${LLM_ENDPOINT[$PROVIDER]:-}}"
MODEL="${MODEL:-${LLM_DEFAULT_MODEL[$PROVIDER]:-}}"
[[ -z "$ENDPOINT" ]] && die "No endpoint for provider '$PROVIDER'"
[[ -z "$MODEL" ]]    && die "No model for provider '$PROVIDER'"

# ── Built-in system prompts ──────────────────────────────────────────────────
CHUNK_SYSTEM='You are an expert SRE analyzing business application logs.
Given a log fragment, identify:
1. What business operations are in progress
2. Which steps completed successfully (with timestamps)
3. Which steps appear interrupted, missing, or anomalous
4. Any unusual time gaps between steps
Be concise. Output structured bullet points. Do not hallucinate steps not present in the logs.'

FINAL_SYSTEM='You are an expert SRE performing root cause analysis.
You will receive: (A) the expected business flow anchors, and (B) reconstructed execution sequence from logs.
Your task:
1. List each expected step and whether it was observed (✓/✗)
2. Identify the exact breakpoint where flow was interrupted
3. Propose root cause hypotheses ranked by likelihood
4. Suggest concrete investigation steps (check which code line, which dependency)
Output in structured Markdown with sections: ## Execution Summary, ## Breakpoint, ## Root Cause Hypotheses, ## Investigation Steps'

if [[ -z "$SYSTEM_PROMPT" ]]; then
  [[ "$PROMPT_TYPE" == "final" ]] && SYSTEM_PROMPT="$FINAL_SYSTEM" || SYSTEM_PROMPT="$CHUNK_SYSTEM"
fi

# ── Read user content from stdin ─────────────────────────────────────────────
USER_CONTENT="$(cat)"
[[ -z "$USER_CONTENT" ]] && die "No input content on stdin"

# ── Provider dispatch ─────────────────────────────────────────────────────────
call_openai_compatible() {
  local auth_header="$1"
  local body
  body=$(jq -n \
    --arg model   "$MODEL" \
    --arg system  "$SYSTEM_PROMPT" \
    --arg content "$USER_CONTENT" \
    '{model: $model, temperature: 0.2, max_tokens: 2048,
      messages: [
        {role: "system", content: $system},
        {role: "user",   content: $content}
      ]}')

  curl -sf "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "$auth_header" \
    -d "$body" \
  | jq -r '.choices[0].message.content // empty' \
  || die "LLM call failed (provider: $PROVIDER)"
}

call_claude() {
  local body
  body=$(jq -n \
    --arg model   "$MODEL" \
    --arg system  "$SYSTEM_PROMPT" \
    --arg content "$USER_CONTENT" \
    '{model: $model, max_tokens: 2048,
      system: $system,
      messages: [{role: "user", content: $content}]}')

  curl -sf "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "$body" \
  | jq -r '.content[0].text // empty' \
  || die "LLM call failed (provider: claude)"
}

# ── Route by provider ─────────────────────────────────────────────────────────
case "$PROVIDER" in
  minimax)
    [[ -z "$API_KEY" ]] && API_KEY="${MINIMAX_API_KEY}"
    [[ -z "$API_KEY" ]] && die "MINIMAX_API_KEY not set"
    call_openai_compatible "Authorization: Bearer $API_KEY"
    ;;
  claude)
    [[ -z "$API_KEY" ]] && API_KEY="${ANTHROPIC_API_KEY}"
    [[ -z "$API_KEY" ]] && die "ANTHROPIC_API_KEY not set"
    call_claude
    ;;
  ollama)
    call_openai_compatible "Content-Type: application/json"
    ;;
  openai)
    [[ -z "$API_KEY" ]] && API_KEY="${OPENAI_API_KEY}"
    [[ -z "$API_KEY" ]] && die "OPENAI_API_KEY not set"
    call_openai_compatible "Authorization: Bearer $API_KEY"
    ;;
  *)
    die "Unknown provider '$PROVIDER'. Supported: minimax | claude | ollama | openai"
    ;;
esac
