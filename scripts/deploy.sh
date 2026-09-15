#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="${1:-all}"
BRANCH="${DEPLOY_BRANCH:-main}"

SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_PATH" != /* ]]; then
  SCRIPT_PATH="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)/$(basename -- "$SCRIPT_PATH")"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
DEPLOY_DIR="${CAR_RENTAL_DEPLOY_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
ROOT_DIR="${CAR_RENTAL_ROOT:-$(cd -- "$DEPLOY_DIR/.." && pwd)}"
BACKEND_DIR="${CAR_RENTAL_BACKEND_DIR:-$ROOT_DIR/cars-rental-backend}"
FRONTEND_DIR="${CAR_RENTAL_FRONTEND_DIR:-$ROOT_DIR/cars-rental-frontend}"
LOCK_FILE="${DEPLOY_LOCK_FILE:-/tmp/car-rental-deploy.lock}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

DEPLOY_STARTED_SECONDS=$SECONDS
HEARTBEAT_PID=""
CURRENT_STEP="initialization"

stop_heartbeat() {
  if [[ -n "$HEARTBEAT_PID" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}

finish_deploy() {
  local status=$?
  stop_heartbeat
  if (( status != 0 )); then
    log "Deployment stopped: stage=$CURRENT_STEP exit=$status elapsed=$((SECONDS - DEPLOY_STARTED_SECONDS))s"
  fi
}
trap finish_deploy EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_step() {
  local label="$1" started=$SECONDS status=0
  shift
  CURRENT_STEP="$label"
  log "START: $label"
  (
    # The status reporter must not retain the deployment lock.
    exec 9>&-
    sleeper=""
    trap 'exit 0' INT TERM
    trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi' EXIT
    while true; do
      sleep 10 &
      sleeper=$!
      wait "$sleeper"
      sleeper=""
      log "IN PROGRESS: $label (elapsed $((SECONDS - started))s; waiting for command to finish)"
    done
  ) &
  HEARTBEAT_PID=$!
  "$@" || status=$?
  stop_heartbeat
  if (( status != 0 )); then
    log "FAILED: $label (exit=$status, elapsed=$((SECONDS - started))s)"
    return "$status"
  fi
  log "DONE: $label (elapsed $((SECONDS - started))s)"
}

export BUILDKIT_PROGRESS=plain

case "$TARGET" in
  all|backend|frontend|deploy) ;;
  *) die "Unknown deploy target '$TARGET'. Use: all, backend, frontend, or deploy." ;;
esac

if command -v flock >/dev/null 2>&1 && [[ -z "${CAR_RENTAL_DEPLOY_LOCKED:-}" ]]; then
  mkdir -p "$(dirname -- "$LOCK_FILE")"
  CURRENT_STEP="waiting for deployment lock"
  log "Waiting for deployment lock: $LOCK_FILE (another deployment may be running)"
  exec 9>"$LOCK_FILE"
  while true; do
    if flock -w 10 9; then
      break
    else
      lock_status=$?
      (( lock_status == 1 )) || die "Cannot acquire deployment lock (exit=$lock_status)"
      log "Still waiting for another deployment to finish (elapsed ${SECONDS}s)"
    fi
  done
  export CAR_RENTAL_DEPLOY_LOCKED=1
  log "Deployment lock acquired"
fi

log "Deployment started: target=$TARGET source=${DEPLOY_SOURCE_REPO:-manual} sha=${DEPLOY_SHA:-unknown}"

update_repo() {
  local dir="$1"
  local name="$2"

  [[ -d "$dir/.git" ]] || die "Git repository '$name' was not found at $dir"

  log "Updating $name ($BRANCH)"
  run_step "Fetch $name" git -C "$dir" fetch --prune origin "$BRANCH"
  run_step "Checkout $name ($BRANCH)" git -C "$dir" checkout "$BRANCH"
  run_step "Pull $name ($BRANCH)" git -C "$dir" pull --ff-only origin "$BRANCH"
  log "$name is at $(git -C "$dir" rev-parse --short HEAD)"
}

if [[ -z "${CAR_RENTAL_DEPLOY_SELF_UPDATED:-}" ]]; then
  before_sha="$(git -C "$DEPLOY_DIR" rev-parse HEAD 2>/dev/null || true)"
  update_repo "$DEPLOY_DIR" "deploy"
  after_sha="$(git -C "$DEPLOY_DIR" rev-parse HEAD 2>/dev/null || true)"

  if [[ "$before_sha" != "$after_sha" ]]; then
    log "Deploy repo changed; restarting deploy script"
    exec env \
      CAR_RENTAL_DEPLOY_LOCKED="${CAR_RENTAL_DEPLOY_LOCKED:-}" \
      CAR_RENTAL_DEPLOY_SELF_UPDATED=1 \
      /bin/bash "$SCRIPT_PATH" "$@"
  fi
fi

case "$TARGET" in
  all|backend)
    update_repo "$BACKEND_DIR" "backend"
    ;;
esac

case "$TARGET" in
  all|frontend)
    update_repo "$FRONTEND_DIR" "frontend"
    ;;
esac

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  die "Docker Compose was not found. Install Docker Compose v2 or docker-compose."
fi

compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

cd "$DEPLOY_DIR"

log "Pulling public Docker images"
if ! run_step "Pull public Docker images" compose pull db nginx certbot certbot-renew nginx-reload; then
  log "Some public images were not pulled; continuing with local images"
fi

case "$TARGET" in
  all|deploy|backend)
    log "Building Docker service: backend"
    run_step "Build backend" compose build --pull backend
    ;;
esac

case "$TARGET" in
  all|deploy|frontend)
    wp_cache_build_key="$(date +%s)"
    log "Building Docker service: frontend (WordPress cache key: $wp_cache_build_key)"
    run_step "Build frontend" compose build --pull \
      --build-arg WP_CACHE_BUILD_KEY="$wp_cache_build_key" \
      frontend
    ;;
esac

log "Starting Docker Compose stack"
run_step "Start Docker Compose stack" compose up -d --remove-orphans

log "Running production smoke tests"
if ! run_step "Production smoke tests" /bin/bash "$DEPLOY_DIR/scripts/smoke-test.sh"; then
  die "Production smoke tests failed; see the deploy journal for diagnostics"
fi

log "Deployment finished (elapsed $((SECONDS - DEPLOY_STARTED_SECONDS))s)"
compose ps
