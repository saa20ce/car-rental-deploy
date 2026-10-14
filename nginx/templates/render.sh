#!/bin/sh
set -eu

mode="${1:-init}"
case "$mode" in
  init|reload) ;;
  *) echo "Unknown Nginx render mode: $mode" >&2; exit 1 ;;
esac

case "${FRONTEND_UPSTREAM:-}" in
  host.docker.internal:3000|frontend:3000|frontend-green:3000) ;;
  *) echo "Invalid frontend upstream: ${FRONTEND_UPSTREAM:-unset}" >&2; exit 1 ;;
esac

if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  template=/etc/nginx/templates/https.conf.template
else
  template=/etc/nginx/templates/http.conf.template
fi

current=/etc/nginx/conf.d/default.conf
candidate="$(mktemp /etc/nginx/conf.d/default.conf.XXXXXX)"
previous=/tmp/default.conf.previous
trap 'rm -f "$candidate"' EXIT

# Substitute only deployment variables: Nginx variables such as $host and
# $request_uri must remain intact.
envsubst '${DOMAIN} ${FRONTEND_UPSTREAM}' < "$template" > "$candidate"

had_previous=0
if [ -f "$current" ]; then
  cp "$current" "$previous"
  had_previous=1
fi
mv "$candidate" "$current"

if nginx -t && { [ "$mode" = init ] || nginx -s reload; }; then
  echo "Nginx now routes frontend traffic to $FRONTEND_UPSTREAM"
  exit 0
fi

if [ "$had_previous" -eq 1 ]; then
  cp "$previous" "$current"
  nginx -t || true
  if [ "$mode" = reload ]; then nginx -s reload || true; fi
else
  rm -f "$current"
fi
echo "Nginx configuration update failed; previous configuration restored" >&2
exit 1
