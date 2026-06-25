# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the Analyzer

The main entry point is `analyzer/analyze.sh`. There is no build step — all scripts are pure Bash.

```bash
# Full pipeline example
./analyzer/analyze.sh \
  --entry    "createOrder" \
  --src      "./src" \
  --servers  "app01,app02" \
  --log-path "/var/log/app/" \
  --since    "2024-01-15 10:00:00" \
  --until    "2024-01-15 11:00:00" \
  --provider minimax \
  --api-key  "$MINIMAX_API_KEY" \
  --output   "./reports/incident.md"
```

Supported `--provider` values: `minimax`, `claude`, `ollama`, `openai`.  
API keys can be passed via `--api-key` flag or environment variables `MINIMAX_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`.

### Running individual stages

Each script is independently invokable for debugging:

```bash
# Stage 1: scan source code for log statements
./analyzer/code-scan.sh --entry "createOrder" --src ./src --depth 2 --out /tmp/stmts.txt

# Stage 2 / 5 (LLM calls): pipe content to log-llm.sh
echo "log text" | ./analyzer/log-llm.sh --provider ollama --prompt-type chunk

# Stage 3: fetch logs from remote servers
./analyzer/log-fetch.sh --servers "app01" --log-path "/var/log/" \
  --since "2024-01-15 10:00:00" --until "2024-01-15 11:00:00" \
  --keywords /tmp/keywords.txt --user ubuntu --out /tmp/matched.log

# Stage 4: reconstruct and annotate execution sequence
./analyzer/log-reconstruct.sh --logs /tmp/matched.log --anchors /tmp/anchors.txt --out /tmp/seq.txt

# Stage 5: generate final report
./analyzer/log-report.sh --anchors /tmp/anchors.txt --seq /tmp/seq.txt \
  --out ./report.md --provider minimax --api-key "$MINIMAX_API_KEY"
```

## Architecture

The system is a **5-stage linear pipeline** where each stage writes intermediate files to a shared `$WORK_DIR` (a `mktemp -d` directory, auto-cleaned on exit). All shared state — LLM endpoints, models, chunking constants, SSH defaults, and logging helpers — lives in `config.sh`, which every script `source`s first.

```
analyze.sh (orchestrator)
  │
  ├─ 1. code-scan.sh     — grep entry func → expand call-chain N hops (UpperCamelCase heuristic)
  │                        → extract log.info/warn/error/debug lines → raw_log_statements.txt
  │
  ├─ 2. log-llm.sh       — LLM Phase 1: infer ordered flow anchors (step1/step2/... keywords)
  │                        → flow_anchors.txt, keywords.txt
  │
  ├─ 3. log-fetch.sh     — SSH to each server in parallel (max $PARALLEL=4)
  │                        → build_remote_script() runs on the remote side
  │                        → finds .zip/.log.gz archives, unzips, time-filters via awk,
  │                          greps keywords, merges → matched_logs.txt
  │
  ├─ 4. log-reconstruct.sh — sort by timestamp, fold duplicate stack frames,
  │                          annotate each line with [✓ stepN], detect time gaps → exec_seq.txt
  │
  └─ 5. log-report.sh    — LLM Phase 2: gap analysis comparing expected anchors vs actual seq
                           → Markdown report with ## Execution Summary / ## Breakpoint /
                             ## Root Cause Hypotheses / ## Investigation Steps
```

### Key design decisions

- **`log-llm.sh` is the only LLM adapter.** It handles all four providers (minimax, claude, ollama, openai) with two prompt modes (`chunk` for incremental analysis, `final` for root-cause synthesis). The Claude provider uses a different API shape (`content[0].text` vs `choices[0].message.content`).

- **Call-chain expansion in `code-scan.sh`** uses a UpperCamelCase suffix heuristic (`Service|Repository|Client|Mapper|Dao|Manager|Handler|Util|Helper`) to discover related files without parsing the AST. It is language-agnostic but optimised for Java naming conventions.

- **Remote log fetch** (`log-fetch.sh`) builds a self-contained bash heredoc and runs it on the remote server via `ssh ... bash -s`. The remote side handles archive discovery, decompression, and awk-based timestamp filtering without requiring any tooling beyond standard POSIX utilities.

- **`config.sh` constants** (`CHUNK_LINES`, `CONTEXT_LINES`, `STACK_FOLD_THRESHOLD`, `SCAN_DEPTH`) are tuning knobs; override them in `config.sh` or via the `--depth` flag on individual scripts.

## Dependencies

Runtime: `bash`, `ssh`, `curl`, `jq`, `awk`, `grep`, `sort`, `unzip`, `zcat`, `date -d` (GNU coreutils).  
No package manager, no compiled code.
