# log-analyzer

基于 LLM 的微服务日志故障分析工具。给定入口函数名与时间窗口，自动完成代码扫描 → 流程锚点推断 → 远程日志采集 → 执行序列重建 → 根因分析报告全流程。

---

## 目录

- [架构概览](#架构概览)
- [依赖](#依赖)
- [快速开始](#快速开始)
- [配置说明](#配置说明)
- [模块说明](#模块说明)
- [node-ip-finder](#node-ip-finder)

---

## 架构概览

```
analyze.sh（编排入口）
  │
  ├─ Step 1  code-scan.sh        从源码中提取入口函数的调用链日志语句
  │
  ├─ Step 2  log-llm.sh          LLM 第一轮：推断业务执行顺序，生成流程锚点关键词
  │
  ├─ Step 3  log-fetch.sh        SSH 登录各服务器，从 zip/gz 归档中提取匹配日志行
  │
  ├─ Step 4  log-reconstruct.sh  按时间戳排序，标注锚点步骤，标记异常时间间隔
  │
  └─ Step 5  log-report.sh       LLM 第二轮：对比预期流程与实际执行，输出 Markdown 报告
```

各阶段通过 `$WORK_DIR`（临时目录，进程退出自动清理）传递中间文件，共享配置统一在 `analyzer/config.sh` 中管理。

---

## 依赖

### analyzer

| 工具 | 用途 |
|---|---|
| `bash` ≥ 4.0 | 脚本运行时 |
| `curl` | 调用 LLM API |
| `jq` | 解析 LLM JSON 响应 |
| `ssh` / `sshpass` | 远程登录服务器 |
| `unzip` / `zcat` | 解压日志归档 |
| `awk` `sort` `grep` | 日志过滤与排序（GNU coreutils） |
| `date -d` | 时间戳解析（需 GNU date） |

### node-ip-finder

| 工具 | 用途 |
|---|---|
| `sshpass` | 密码认证 SSH 登录跳板机 |
| `python3` + `openpyxl` | 解析 Excel 获取跳板机 IP |
| `kubectl` | 在跳板机上执行（本地无需安装） |

```bash
pip install openpyxl
```

---

## 快速开始

### 1. 配置 LLM、SSH 与日志路径

编辑 `analyzer/config.sh`：

```bash
# LLM API Key（按使用的 provider 填写）
MINIMAX_API_KEY="your-key"
ANTHROPIC_API_KEY="your-key"
OPENAI_API_KEY="your-key"

# SSH 登录用户
SSH_USER="ubuntu"

# 微服务名 → 日志目录映射，配置后无需每次传 --log-path
declare -A SERVICE_LOG_PATH=(
  ["order-service"]="/var/log/order/"
  ["user-service"]="/var/log/user/"
  ["payment-service"]="/var/log/payment/"
)
```

### 2. 配置跳板机（node-ip-finder）

编辑 `node-ip-finder/config.sh`：

```bash
BASTION_SSH_USER="admin"
BASTION_SSH_PASSWORD="your-password"
BASTION_EXCEL_PATH="/path/to/servers.xlsx"
```

### 3. 端到端运行（K8s 自动发现 + 日志分析）

```bash
# Step A：通过 K8s Service 名称发现宿主机 IP
SERVERS=$(./node-ip-finder/find-nodes.sh \
  --service   order-service \
  --namespace production)

# Step B：使用发现的 IP 运行日志分析
./analyzer/analyze.sh \
  --entry    "createOrder" \
  --src      "./src" \
  --service  "order-service" \
  --servers  "$SERVERS" \
  --since    "2024-01-15 10:00:00" \
  --until    "2024-01-15 11:00:00" \
  --provider minimax \
  --api-key  "$MINIMAX_API_KEY" \
  --output   "./reports/incident.md"
```

### 4. 直接指定服务器 IP（跳过 node-ip-finder）

```bash
./analyzer/analyze.sh \
  --entry    "createOrder" \
  --src      "./src" \
  --service  "order-service" \
  --servers  "10.0.1.3,10.0.1.7" \
  --since    "2024-01-15 10:00:00" \
  --until    "2024-01-15 11:00:00" \
  --provider minimax \
  --api-key  "$MINIMAX_API_KEY" \
  --output   "./reports/incident.md"
```

> `--log-path` 可临时覆盖 `SERVICE_LOG_PATH` 中的配置值。

---

## 配置说明

### `analyzer/config.sh`

| 参数 | 默认值 | 说明 |
|---|---|---|
| `SERVICE_LOG_PATH` | 空映射 | 微服务名 → 日志目录，`--log-path` 优先级更高 |
| `CHUNK_LINES` | `150` | 每次送入 LLM 的日志行数 |
| `CONTEXT_LINES` | `3` | 匹配行周围保留的上下文行数 |
| `STACK_FOLD_THRESHOLD` | `3` | 重复堆栈帧折叠阈值 |
| `SCAN_DEPTH` | `2` | 调用链扫描深度（从入口函数向外扩展跳数） |
| `SSH_USER` | 空 | SSH 登录用户名，也可通过 `--user` 参数传入 |

### `node-ip-finder/config.sh`

| 参数 | 默认值 | 说明 |
|---|---|---|
| `BASTION_SSH_USER` | 空 | 跳板机 SSH 用户名 |
| `BASTION_SSH_PASSWORD` | 空 | 跳板机 SSH 密码 |
| `BASTION_EXCEL_PATH` | 空 | 存放跳板机 IP 的 Excel 文件路径 |
| `BASTION_EXCEL_SHEET` | `0` | Excel Sheet 索引（0-based） |
| `BASTION_EXCEL_IP_COL` | `1` | IP 所在列索引（1-based） |

### 支持的 LLM Provider

| Provider | 所需环境变量 | 备注 |
|---|---|---|
| `minimax` | `MINIMAX_API_KEY` | |
| `claude` | `ANTHROPIC_API_KEY` | |
| `openai` | `OPENAI_API_KEY` | |
| `ollama` | 无需 key | 默认连接 `localhost:11434` |

---

## 模块说明

### 单独调用各阶段（调试用）

```bash
# Step 1：扫描源码，提取调用链日志语句
./analyzer/code-scan.sh \
  --entry "createOrder" --src ./src --depth 2 --out /tmp/stmts.txt

# Step 2/5：调用 LLM（stdin 传入内容）
echo "log text" | ./analyzer/log-llm.sh \
  --provider ollama --prompt-type chunk

# Step 3：从远程服务器拉取日志
./analyzer/log-fetch.sh \
  --servers  "10.0.1.3" \
  --log-path "/var/log/order/" \
  --since    "2024-01-15 10:00:00" \
  --until    "2024-01-15 11:00:00" \
  --keywords /tmp/keywords.txt \
  --user     ubuntu \
  --out      /tmp/matched.log

# Step 4：重建执行序列
./analyzer/log-reconstruct.sh \
  --logs    /tmp/matched.log \
  --anchors /tmp/anchors.txt \
  --out     /tmp/seq.txt

# Step 5：生成报告
./analyzer/log-report.sh \
  --anchors /tmp/anchors.txt \
  --seq     /tmp/seq.txt \
  --out     ./report.md \
  --provider minimax --api-key "$MINIMAX_API_KEY"
```

### 报告格式

生成的 Markdown 报告包含以下章节：

- **Execution Summary** — 各预期步骤是否被观测到（✓/✗）
- **Breakpoint** — 流程中断的精确位置
- **Root Cause Hypotheses** — 根因假设（按可能性排序）
- **Investigation Steps** — 具体排查建议

---

## node-ip-finder

通过 K8s Service 名称，经跳板机 SSH 执行 `kubectl`，自动发现服务 Pod 所在宿主机 IP，供 `log-fetch.sh --servers` 参数使用。

### 数据流

```
Excel 文件 ──→ 跳板机 IP
                  │
                  └─ sshpass SSH
                       │
                       ├─ kubectl get svc <name>        → .spec.selector
                       ├─ kubectl get pods -l <sel>     → .spec.nodeName[]（仅 Running）
                       └─ kubectl get nodes <names...>  → InternalIP[]
                                                              │
                                                              ▼
                                                    10.0.1.3,10.0.1.7
```

### 参数说明

```bash
./node-ip-finder/find-nodes.sh \
  --service    <K8s Service 名称>          # 必填
  --namespace  <命名空间>                  # 必填
  [--excel     <Excel 文件路径>]           # 覆盖配置中的 BASTION_EXCEL_PATH
  [--format    csv|lines]                  # 默认 csv，lines 每行一个 IP
  [--ip-type   InternalIP|ExternalIP]      # 默认 InternalIP
```

**输出示例：**

```
10.0.1.3,10.0.1.7,10.0.1.12
```

> **注意**：Excel 解析逻辑待表结构确认后补全。当前可通过 `export BASTION_IP=<ip>` 临时绕过。
