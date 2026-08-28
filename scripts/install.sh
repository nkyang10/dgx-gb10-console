#!/usr/bin/env bash
# scripts/install.sh — idempotent DGX status exporter install for DGX OS
# (Ubuntu 24.04 noble, ARM64, Python 3.12, systemd).
#
# Usage (N-node cluster):
#   sudo ./scripts/install.sh --role=aggregator --node-id=dgx-01 --mgmt-ip=10.0.20.10   # Node-A (aggregator)
#   sudo ./scripts/install.sh --role=exporter    --node-id=dgx-02 --mgmt-ip=10.0.20.11   # Node-B (leaf)
#   sudo ./scripts/install.sh --role=exporter    --node-id=dgx-03 --mgmt-ip=10.0.20.12   # Node-C (leaf) ...
#   sudo ./scripts/install.sh --update                                 # 升級
#   sudo ./scripts/install.sh --uninstall                              # 回滾
#   sudo ./scripts/install.sh --mode=container                         # Docker 後備路徑
#
# Safe to re-run (idempotent): creates users/dirs, rebuilds venv if missing,
# installs systemd unit, reloads daemon, (re)starts only if it was running.

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="dgx-status-exporter"
SERVICE_USER="status"
SERVICE_GROUP="status"
INSTALL_DIR="/opt/dgx-status"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="/etc/dgx-status/status.env"
CONFIG_FILE="${INSTALL_DIR}/config.yaml"
DATA_DIR="/var/lib/dgx-status"

# ---- CLI flags --------------------------------------------------------------
MODE="host"          # host|container
ROLE=""              # aggregator|exporter
NODE_ID=""           # e.g. dgx-01 (optional)
MGMT_IP=""           # e.g. 10.0.20.10 (optional)

for arg in "$@"; do
  case "$arg" in
    --mode=*) MODE="${arg#*=}" ;;
    --role=*) ROLE="${arg#*=}" ;;
    --node-id=*) NODE_ID="${arg#*=}" ;;
    --mgmt-ip=*) MGMT_IP="${arg#*=}" ;;
    --update)  DO_UPDATE=1 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    *) echo "unknown flag: $arg"; exit 1 ;;
  esac
done

log()  { echo -e "\033[1;34m[install]\033[0m $*"; }
err()  { echo -e "\033[1;31m[install]\033[0m $*" >&2; }

require_root() { [[ "$EUID" -eq 0 ]] || { err "run with sudo/root"; exit 1; }; }

ensure_host_tools() {
  # Tools the collectors shell out to. DGX OS already ships nvidia-smi, python3,
  # iproute2(ip), lspci(pciutils), curl. Sensors + nvme-cli + ethtool may be missing.
  local missing=()
  for b in nvidia-smi python3 lspci ip curl; do command -v "$b" >/dev/null || missing+=("$b"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "missing base tools: ${missing[*]} — DGX OS should preinstall these; aborting."
    exit 1
  fi
  # Best-effort optional packages (won't fail install if unavailable)
  command -v sensors >/dev/null || apt-get install -y -qq lm-sensors >/dev/null 2>&1 || true
  command -v nvme   >/dev/null || apt-get install -y -qq nvme-cli  >/dev/null 2>&1 || true
  command -v ethtool>/dev/null || apt-get install -y -qq ethtool   >/dev/null 2>&1 || true
  # GPU management engine (DCGM) is optional; provides dcgmi. Ships with driver on some builds.
  command -v dcgmi >/dev/null || apt-get install -y -qq datacenter-gpu-manager >/dev/null 2>&1 || true
}

setup_user_and_dirs() {
  getent group  "$SERVICE_GROUP" >/dev/null || groupadd --system "$SERVICE_GROUP"
  getent passwd "$SERVICE_USER"  >/dev/null || useradd --system --shell /usr/sbin/nologin \
      --gid "$SERVICE_GROUP" --home "$INSTALL_DIR" --no-create-home "$SERVICE_USER"

  install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$INSTALL_DIR" "$DATA_DIR"
  install -d -m 0700 -o root -g root /etc/dgx-status

  # Copy project files (preserve upstream if re-running)
  cp -a "${PROJECT_DIR}/app"   "$INSTALL_DIR/"
  cp -a "${PROJECT_DIR}/requirements.txt" "$INSTALL_DIR/"
}

create_venv() {
  log "creating/updating venv at $INSTALL_DIR/.venv"
  if [[ ! -x "$INSTALL_DIR/.venv/bin/python" ]]; then
    python3 -m venv "$INSTALL_DIR/.venv"
  fi
  # upgrade pip + tools, then install pinned deps
  "$INSTALL_DIR/.venv/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null
  "$INSTALL_DIR/.venv/bin/python" -m pip install -r "$INSTALL_DIR/requirements.txt"
  # optional dependency for realtime graphs (skip if unavailable on arm64)
  # "$INSTALL_DIR/.venv/bin/python" -m pip install python-socketio || true
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR/.venv"
}

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log "writing default $ENV_FILE (please edit token!)"
    cat >"$ENV_FILE" <<EOF
DGX_STATUS_TOKEN=CHANGE_ME_openssl_rand_hex_32
DGX_STATUS_PORT=9101
DGX_STATUS_ROLE=${ROLE:-aggregator}
DGX_STATUS_NODE_ID=${NODE_ID:-dgx-01}
DGX_STATUS_MGMT_IP=${MGMT_IP:-10.0.20.10}
EOF
  fi
  # Apply CLI overrides if given (idempotent for N-node provisioning)
  [[ -n "$ROLE" ]]     && sed -i "s/^DGX_STATUS_ROLE=.*/DGX_STATUS_ROLE=$ROLE/"     "$ENV_FILE"
  [[ -n "$NODE_ID" ]]  && sed -i "s/^DGX_STATUS_NODE_ID=.*/DGX_STATUS_NODE_ID=$NODE_ID/" "$ENV_FILE"
  [[ -n "$MGMT_IP" ]]  && sed -i "s/^DGX_STATUS_MGMT_IP=.*/DGX_STATUS_MGMT_IP=$MGMT_IP/" "$ENV_FILE"
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
}

install_systemd() {
  log "installing systemd unit $UNIT_FILE"
  install -m 0644 "${PROJECT_DIR}/deploy/dgx-status-exporter.service" "$UNIT_FILE"
  systemctl daemon-reload
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "service already active — restarting to apply changes"
    systemctl restart "$SERVICE_NAME"
  else
    systemctl enable --now "$SERVICE_NAME"
  fi
  log "health: curl -fsS http://127.0.0.1:\$(grep -oP 'DGX_STATUS_PORT=\\K.*' "$ENV_FILE")/health"
}

install_container() {
  log "building + starting ${SERVICE_NAME} via docker-compose"
  cp -a "${PROJECT_DIR}/config.yaml" "$INSTALL_DIR/"
  ( cd "$INSTALL_DIR" && docker compose -f deploy/docker-compose.yml up -d --build )
}

uninstall() {
  [[ "$MODE" == "container" ]] && \
      ( cd "$INSTALL_DIR" && docker compose -f deploy/docker-compose.yml down -v ) || true
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_FILE"; systemctl daemon-reload
  # Leave /opt/dgx-status and data for safety; tell user how to purge fully.
  err "removed service. Purge data with: rm -rf $INSTALL_DIR $DATA_DIR /etc/dgx-status"
  log "user/group ($SERVICE_USER) left in place; deluser --system $SERVICE_USER to remove."
}

# ---- main -------------------------------------------------------------------
require_root
if [[ "${DO_UNINSTALL:-0}" == "1" ]]; then uninstall; exit 0; fi

ensure_host_tools
setup_user_and_dirs

case "$MODE" in
  host)
    ensure_env_file
    create_venv
    # For N-node setup, copy the SAME config.yaml to all hosts, then set per-host:
    #   Node-A: node_id/role=aggregator + aggregation.pull=all-except-self
    #   Node-B..N: node_id=<id>, role=exporter (see docs/實作-多節點擴展.md)
    install -m 0644 "${PROJECT_DIR}/config.yaml" "$CONFIG_FILE"
    install_systemd
    ;;
  container)
    ensure_env_file
    install_container
    ;;
  *) err "unknown mode $MODE"; exit 1 ;;
esac

log "done. For two-node aggregation, see README: Node-B needs its own role=exporter + 10G mgmt IP."
