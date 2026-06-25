#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="${AUTODEPLOY_SERVICE_NAME:-car-rental-autodeploy}"
BRANCH="${DEPLOY_BRANCH:-main}"
INTERVAL="${DEPLOY_WATCH_INTERVAL:-60}"

SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_PATH" != /* ]]; then
  SCRIPT_PATH="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)/$(basename -- "$SCRIPT_PATH")"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
DEPLOY_DIR="${CAR_RENTAL_DEPLOY_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
ROOT_DIR="${CAR_RENTAL_ROOT:-$(cd -- "$DEPLOY_DIR/.." && pwd)}"
WATCHER="$DEPLOY_DIR/scripts/watch-and-deploy.sh"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

[[ -f "$WATCHER" ]] || die "Watcher script was not found at $WATCHER"
command -v systemctl >/dev/null 2>&1 || die "systemctl was not found; this installer supports systemd servers"

SUDO=()
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Run as root or install sudo"
  SUDO=(sudo)
fi

tmp_service="$(mktemp)"
cat > "$tmp_service" <<SERVICE
[Unit]
Description=Car Rental auto deploy watcher
Wants=network-online.target docker.service
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=$DEPLOY_DIR
Environment=DEPLOY_BRANCH=$BRANCH
Environment=DEPLOY_WATCH_INTERVAL=$INTERVAL
Environment=CAR_RENTAL_DEPLOY_DIR=$DEPLOY_DIR
Environment=CAR_RENTAL_ROOT=$ROOT_DIR
ExecStart=/bin/bash $WATCHER
Restart=always
RestartSec=10
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
SERVICE

log "Installing systemd service: $SERVICE_FILE"
"${SUDO[@]}" install -m 0644 "$tmp_service" "$SERVICE_FILE"
rm -f "$tmp_service"

"${SUDO[@]}" systemctl daemon-reload
"${SUDO[@]}" systemctl enable --now "${SERVICE_NAME}.service"

log "Service installed and started"
"${SUDO[@]}" systemctl --no-pager --lines=20 status "${SERVICE_NAME}.service" || true
