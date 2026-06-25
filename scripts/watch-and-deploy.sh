#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="${DEPLOY_BRANCH:-main}"
INTERVAL="${DEPLOY_WATCH_INTERVAL:-60}"

SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_PATH" != /* ]]; then
  SCRIPT_PATH="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)/$(basename -- "$SCRIPT_PATH")"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
DEPLOY_DIR="${CAR_RENTAL_DEPLOY_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
ROOT_DIR="${CAR_RENTAL_ROOT:-$(cd -- "$DEPLOY_DIR/.." && pwd)}"
BACKEND_DIR="${CAR_RENTAL_BACKEND_DIR:-$ROOT_DIR/cars-rental-backend}"
FRONTEND_DIR="${CAR_RENTAL_FRONTEND_DIR:-$ROOT_DIR/cars-rental-frontend}"
DEPLOY_SCRIPT="${CAR_RENTAL_DEPLOY_SCRIPT:-$DEPLOY_DIR/scripts/deploy.sh}"
LOCK_FILE="${DEPLOY_WATCH_LOCK_FILE:-/tmp/car-rental-deploy-watch.lock}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

if command -v flock >/dev/null 2>&1 && [[ -z "${CAR_RENTAL_DEPLOY_WATCH_LOCKED:-}" ]]; then
  mkdir -p "$(dirname -- "$LOCK_FILE")"
  exec flock -n "$LOCK_FILE" env CAR_RENTAL_DEPLOY_WATCH_LOCKED=1 "$SCRIPT_PATH" "$@"
fi

trap 'log "Watcher stopped"; exit 0' INT TERM

[[ -f "$DEPLOY_SCRIPT" ]] || die "Deploy script was not found at $DEPLOY_SCRIPT"
[[ -d "$DEPLOY_DIR/.git" ]] || die "Deploy repository was not found at $DEPLOY_DIR"
[[ -d "$FRONTEND_DIR/.git" ]] || die "Frontend repository was not found at $FRONTEND_DIR"

remote_sha() {
  local dir="$1"
  local output

  output="$(git -C "$dir" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null || true)"
  [[ -n "$output" ]] || return 1
  printf '%s\n' "$output" | awk '{print $1}' | head -n 1
}

local_sha() {
  local dir="$1"

  git -C "$dir" rev-parse "refs/heads/$BRANCH" 2>/dev/null \
    || git -C "$dir" rev-parse HEAD 2>/dev/null
}

repo_has_remote_change() {
  local dir="$1"
  local name="$2"
  local local_ref remote_ref

  [[ -d "$dir/.git" ]] || return 1

  if ! remote_ref="$(remote_sha "$dir")"; then
    log "Could not read remote branch for $name; will retry later"
    return 1
  fi

  local_ref="$(local_sha "$dir")"
  if [[ "$local_ref" != "$remote_ref" ]]; then
    log "$name changed: ${local_ref:0:12} -> ${remote_ref:0:12}"
    return 0
  fi

  return 1
}

pick_target() {
  local deploy_changed="$1"
  local backend_changed="$2"
  local frontend_changed="$3"

  if [[ "$deploy_changed" == "1" ]]; then
    printf 'all\n'
  elif [[ "$backend_changed" == "1" && "$frontend_changed" == "1" ]]; then
    printf 'all\n'
  elif [[ "$backend_changed" == "1" ]]; then
    printf 'backend\n'
  elif [[ "$frontend_changed" == "1" ]]; then
    printf 'frontend\n'
  else
    printf '\n'
  fi
}

run_deploy() {
  local target="$1"

  log "Running deploy target: $target"
  DEPLOY_SOURCE_REPO="watcher" "$DEPLOY_SCRIPT" "$target"
  log "Deploy target finished: $target"
}

log "Watcher started: branch=$BRANCH interval=${INTERVAL}s deploy_dir=$DEPLOY_DIR"

while true; do
  deploy_changed=0
  backend_changed=0
  frontend_changed=0

  if repo_has_remote_change "$DEPLOY_DIR" "deploy"; then
    deploy_changed=1
  fi

  if [[ -d "$BACKEND_DIR/.git" ]] && repo_has_remote_change "$BACKEND_DIR" "backend"; then
    backend_changed=1
  fi

  if repo_has_remote_change "$FRONTEND_DIR" "frontend"; then
    frontend_changed=1
  fi

  target="$(pick_target "$deploy_changed" "$backend_changed" "$frontend_changed")"
  if [[ -n "$target" ]]; then
    if run_deploy "$target"; then
      if [[ "$deploy_changed" == "1" ]]; then
        log "Deploy repository changed; restarting watcher to use the latest script"
        exec "$SCRIPT_PATH" "$@"
      fi
    else
      log "Deploy failed; will retry on the next check"
    fi
  fi

  sleep "$INTERVAL"
done
