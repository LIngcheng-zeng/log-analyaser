#!/usr/bin/env bash
# Resolve Service name → Pod nodeNames → Node InternalIPs via bastion SSH.
# Bastion IP is resolved from an Excel file.
#
# Dependencies: sshpass, python3 + openpyxl
#
# Usage:
#   find-nodes.sh --service <name> --namespace <ns>
#                 [--excel <path>] [--format csv|lines] [--ip-type InternalIP|ExternalIP]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

SERVICE=""
NAMESPACE=""
FORMAT="csv"
IP_TYPE="InternalIP"
EXCEL_PATH="${BASTION_EXCEL_PATH:-}"

info()  { echo "[INFO]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $0 --service <name> --namespace <ns>
          [--excel <path>] [--format csv|lines] [--ip-type InternalIP|ExternalIP]

  --service    Kubernetes Service name
  --namespace  Kubernetes namespace
  --excel      Path to Excel file containing bastion IP (overrides config)
  --format     csv (default) | lines
  --ip-type    InternalIP (default) | ExternalIP
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)    SERVICE="$2";    shift 2 ;;
    --namespace)  NAMESPACE="$2";  shift 2 ;;
    --excel)      EXCEL_PATH="$2"; shift 2 ;;
    --format)     FORMAT="$2";     shift 2 ;;
    --ip-type)    IP_TYPE="$2";    shift 2 ;;
    -h|--help)    usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$SERVICE" ]]   && die "--service is required"
[[ -z "$NAMESPACE" ]] && die "--namespace is required"
[[ -z "$BASTION_SSH_USER" ]]     && die "BASTION_SSH_USER not set in config"
[[ -z "$BASTION_SSH_PASSWORD" ]] && die "BASTION_SSH_PASSWORD not set in config"

# ── Step 1: Resolve bastion IP from Excel ────────────────────────────────────
resolve_bastion_ip() {
  # TODO: implement Excel parsing with openpyxl when table structure is confirmed.
  # Stub — read from env or fail with a clear message.
  if [[ -n "${BASTION_IP:-}" ]]; then
    echo "$BASTION_IP"
    return 0
  fi
  die "BASTION_IP not set. Excel parsing not yet implemented — export BASTION_IP=<ip> to proceed."
}

BASTION_IP="$(resolve_bastion_ip)"
info "Bastion: $BASTION_IP"

# ── Step 2: Build remote kubectl script (runs on bastion) ────────────────────
build_remote_script() {
  cat <<REMOTE
set -euo pipefail
SERVICE="${SERVICE}"
NAMESPACE="${NAMESPACE}"
IP_TYPE="${IP_TYPE}"

# Derive pod selector from Service spec
selector=\$(kubectl get svc "\$SERVICE" -n "\$NAMESPACE" -o json \
  | python3 -c "
import sys, json
svc = json.load(sys.stdin)
sel = svc.get('spec', {}).get('selector', {})
if not sel:
    raise SystemExit('Service has no selector')
print(','.join(f'{k}={v}' for k, v in sel.items()))
")

# Find Running pod node names
mapfile -t node_names < <(
  kubectl get pods -n "\$NAMESPACE" -l "\$selector" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | sort -u
)

[[ \${#node_names[@]} -eq 0 ]] && { echo "[WARN] No Running pods for \$selector" >&2; exit 0; }

# Batch fetch Node IPs (single kubectl call)
kubectl get nodes "\${node_names[@]}" -o json \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
ip_type = '${IP_TYPE}'
ips = set()
for item in data.get('items', []):
    for addr in item.get('status', {}).get('addresses', []):
        if addr.get('type') == ip_type:
            ips.add(addr['address'])
print('\n'.join(sorted(ips)))
"
REMOTE
}

# ── Step 3: Execute remote script on bastion ─────────────────────────────────
info "Connecting to bastion $BASTION_IP ..."
remote_script="$(build_remote_script)"

raw_ips=$(sshpass -p "$BASTION_SSH_PASSWORD" \
  ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_IP}" "bash -s" <<< "$remote_script") \
  || die "SSH to bastion failed or remote kubectl error"

[[ -z "$raw_ips" ]] && { echo "[WARN] No IPs returned" >&2; exit 0; }

info "Resolved IPs: $(echo "$raw_ips" | tr '\n' ' ')"

# ── Step 4: Output ────────────────────────────────────────────────────────────
if [[ "$FORMAT" == "csv" ]]; then
  echo "$raw_ips" | paste -sd','
else
  echo "$raw_ips"
fi
