#!/usr/bin/env bash
# Node-IP-Finder configuration

# ── Bastion SSH credentials ───────────────────────────────────────────────────
BASTION_SSH_USER="${BASTION_SSH_USER:-}"
BASTION_SSH_PASSWORD="${BASTION_SSH_PASSWORD:-}"

# ── Excel config (path + column indices, 1-based) ────────────────────────────
BASTION_EXCEL_PATH="${BASTION_EXCEL_PATH:-}"
BASTION_EXCEL_SHEET="${BASTION_EXCEL_SHEET:-0}"      # sheet index, 0-based
BASTION_EXCEL_IP_COL="${BASTION_EXCEL_IP_COL:-1}"    # column index of IP field

# ── SSH options ───────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=no"
