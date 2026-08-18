#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${CAR_RENTAL_DEPLOY_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
SITE_URL="${DEPLOY_SITE_URL:-}"
WP_URL="${DEPLOY_WP_URL:-https://staged.rentasib.ru/wp-json/wp/v2/}"
ATTEMPTS="${DEPLOY_SMOKE_ATTEMPTS:-6}"
DELAY="${DEPLOY_SMOKE_DELAY:-5}"

log() {
  printf '[%s] [smoke] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
else
  COMPOSE_CMD=(docker-compose)
fi

compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

print_diagnostics() {
  local label="$1"
  local url="$2"
  local frontend_id

  log "Diagnostics for $label ($url)"
  curl -sS --max-time 30 -D - -o /dev/null "$url" || true
  compose ps || true
  compose logs --tail=300 frontend nginx || true

  frontend_id="$(compose ps -q frontend 2>/dev/null || true)"
  if [[ -n "$frontend_id" ]]; then
    docker inspect --format \
      'container={{.Name}} image={{.Image}} started={{.State.StartedAt}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      "$frontend_id" || true
  fi
}

check_url() {
  local label="$1"
  local url="$2"
  local attempt status total

  for ((attempt = 1; attempt <= ATTEMPTS; attempt += 1)); do
    read -r status total < <(
      curl -sS -o /dev/null --max-time 30 \
        -w '%{http_code} %{time_total}\n' "$url" || printf '000 30\n'
    )
    log "$label attempt=$attempt status=$status time=${total}s"
    if [[ "$status" == "200" ]]; then
      return 0
    fi
    sleep "$DELAY"
  done

  print_diagnostics "$label" "$url"
  return 1
}

check_wordpress_from_frontend() {
  local attempt

  for ((attempt = 1; attempt <= ATTEMPTS; attempt += 1)); do
    if compose exec -T frontend wget -q -O /dev/null -T 20 "$WP_URL"; then
      log "wordpress attempt=$attempt status=200"
      return 0
    fi
    log "wordpress attempt=$attempt failed"
    sleep "$DELAY"
  done

  print_diagnostics "wordpress" "$WP_URL"
  return 1
}

cd "$DEPLOY_DIR"

if [[ -z "$SITE_URL" ]]; then
  domain="${DOMAIN:-$(compose config | sed -n 's/^[[:space:]]*DOMAIN: //p' | head -n 1)}"
  [[ -n "$domain" ]] || {
    log "Could not resolve DOMAIN from the environment or Docker Compose"
    exit 1
  }
  SITE_URL="https://$domain"
fi
SITE_URL="${SITE_URL%/}"

check_url "homepage" "$SITE_URL/"
check_url "cars" "$SITE_URL/cars"
check_url "robots" "$SITE_URL/robots.txt"
check_wordpress_from_frontend

log "All production checks passed"
