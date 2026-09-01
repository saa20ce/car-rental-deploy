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

case "$TARGET" in
  all|backend|frontend|deploy) ;;
  *) die "Unknown deploy target '$TARGET'. Use: all, backend, frontend, or deploy." ;;
esac

if command -v flock >/dev/null 2>&1 && [[ -z "${CAR_RENTAL_DEPLOY_LOCKED:-}" ]]; then
  mkdir -p "$(dirname -- "$LOCK_FILE")"
  exec flock "$LOCK_FILE" env CAR_RENTAL_DEPLOY_LOCKED=1 /bin/bash "$SCRIPT_PATH" "$@"
fi

log "Deployment started: target=$TARGET source=${DEPLOY_SOURCE_REPO:-manual} sha=${DEPLOY_SHA:-unknown}"

update_repo() {
  local dir="$1"
  local name="$2"

  [[ -d "$dir/.git" ]] || die "Git repository '$name' was not found at $dir"

  log "Updating $name ($BRANCH)"
  git -C "$dir" fetch --prune origin "$BRANCH"
  git -C "$dir" checkout "$BRANCH"
  git -C "$dir" pull --ff-only origin "$BRANCH"
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
if ! compose pull db nginx certbot certbot-renew nginx-reload; then
  log "Some public images were not pulled; continuing with local images"
fi

case "$TARGET" in
  all|deploy|backend)
    log "Building Docker service: backend"
    compose build --pull backend
    ;;
esac

case "$TARGET" in
  all|deploy|frontend)
    wp_cache_build_key="$(date +%s)"
    log "Building Docker service: frontend (WordPress cache key: $wp_cache_build_key)"
    compose build --pull \
      --build-arg WP_CACHE_BUILD_KEY="$wp_cache_build_key" \
      frontend
    ;;
esac

log "Starting Docker Compose stack"
compose up -d --remove-orphans

log "Running production smoke tests"
if ! /bin/bash "$DEPLOY_DIR/scripts/smoke-test.sh"; then
  die "Production smoke tests failed; see the deploy journal for diagnostics"
fi

log "Deployment finished"
compose ps
