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

backend_before_sha="$(git -C "$BACKEND_DIR" rev-parse HEAD 2>/dev/null || true)"
frontend_before_sha="$(git -C "$FRONTEND_DIR" rev-parse HEAD 2>/dev/null || true)"

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

backend_after_sha="$(git -C "$BACKEND_DIR" rev-parse HEAD 2>/dev/null || true)"
frontend_after_sha="$(git -C "$FRONTEND_DIR" rev-parse HEAD 2>/dev/null || true)"

# The old watcher labels a deploy-repository-only update as "all". Do not
# replace a healthy backend merely because Nginx/deployment code changed.
if [[ "$TARGET" == all && "${DEPLOY_SOURCE_REPO:-}" == watcher &&
      "$backend_before_sha" == "$backend_after_sha" &&
      "$frontend_before_sha" == "$frontend_after_sha" ]]; then
  log "Only deployment files changed; using the deploy target"
  TARGET=deploy
fi

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

FRONTEND_STATE_FILE="$DEPLOY_DIR/runtime/frontend-target"

read_frontend_target() {
  local target=legacy
  if [[ -f "$FRONTEND_STATE_FILE" ]]; then
    target="$(<"$FRONTEND_STATE_FILE")"
  fi
  case "$target" in
    legacy|blue|green) printf '%s\n' "$target" ;;
    *) die "Invalid frontend target in $FRONTEND_STATE_FILE: $target" ;;
  esac
}

save_frontend_target() {
  local target="$1" temp
  temp="$(mktemp "$FRONTEND_STATE_FILE.XXXXXX")"
  printf '%s\n' "$target" > "$temp"
  mv -f "$temp" "$FRONTEND_STATE_FILE"
}

wait_for_frontend() {
  local service="$1" id health attempt
  for ((attempt = 1; attempt <= 36; attempt += 1)); do
    id="$(compose ps -q "$service")"
    if [[ -n "$id" ]]; then
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$id")"
      if [[ "$health" == healthy ]]; then
        for path in / /cars /robots.txt; do
          docker exec "$id" wget -q -O /dev/null -T 30 \
            "http://127.0.0.1:3000${path}" || return 1
        done
        return 0
      fi
    fi
    sleep 5
  done
  log "Frontend $service did not become healthy"
  compose logs --tail=80 "$service" || true
  return 1
}

reload_frontend_route() {
  local target="$1" upstream nginx_id
  case "$target" in
    legacy) upstream=host.docker.internal:3000 ;;
    blue) upstream=frontend:3000 ;;
    green) upstream=frontend-green:3000 ;;
    *) die "Invalid frontend target: $target" ;;
  esac
  nginx_id="$(compose ps -q nginx)"
  [[ -n "$nginx_id" ]] || die "Nginx container is not running"
  docker exec -e FRONTEND_UPSTREAM="$upstream" "$nginx_id" \
    sh /etc/nginx/templates/render.sh reload
}

switch_frontend() {
  local old_target="$1" new_target="$2"
  save_frontend_target "$new_target"
  if ! reload_frontend_route "$new_target"; then
    save_frontend_target "$old_target"
    reload_frontend_route "$old_target" || true
    return 1
  fi
}

mkdir -p "$DEPLOY_DIR/runtime"
active_target="$(read_frontend_target)"
if [[ ! -f "$FRONTEND_STATE_FILE" ]]; then
  save_frontend_target "$active_target"
fi

case "$TARGET" in
  all|backend)
    run_step "Build backend" compose build --pull backend
    run_step "Start backend" compose up -d --no-deps backend
    ;;
esac

case "$TARGET" in
  all|deploy)
    # The first rollout adds a runtime bind mount and briefly recreates Nginx.
    # Later template-only changes are applied by a graceful config reload.
    run_step "Apply Nginx service configuration" compose up -d --no-deps nginx
    run_step "Reload Nginx template" reload_frontend_route "$active_target"
    ;;
esac

if [[ "$TARGET" == all || "$TARGET" == deploy || "$TARGET" == frontend ]]; then
  if [[ "$active_target" == legacy || "$active_target" == blue ]]; then
    candidate_service=frontend-green
    candidate_target=green
  else
    candidate_service=frontend
    candidate_target=blue
  fi

  wp_cache_build_key="$(date +%s)"
  log "Building inactive frontend $candidate_service"
  run_step "Build inactive frontend" compose build --pull \
    --build-arg WP_CACHE_BUILD_KEY="$wp_cache_build_key" "$candidate_service"
  run_step "Start inactive frontend" compose up -d --no-deps "$candidate_service"
  run_step "Verify inactive frontend" wait_for_frontend "$candidate_service"
  run_step "Switch frontend" switch_frontend "$active_target" "$candidate_target"

  log "Running production smoke tests"
  if ! run_step "Production smoke tests" /bin/bash "$DEPLOY_DIR/scripts/smoke-test.sh"; then
    log "Smoke tests failed; returning traffic to the previously healthy frontend"
    switch_frontend "$candidate_target" "$active_target" || die "Frontend rollback failed"
    die "Production smoke tests failed after frontend switch"
  fi
else
  log "Running production smoke tests"
  run_step "Production smoke tests" /bin/bash "$DEPLOY_DIR/scripts/smoke-test.sh"
fi

log "Deployment finished (elapsed $((SECONDS - DEPLOY_STARTED_SECONDS))s)"
compose ps
