#!/bin/sh
set -eu

mkdir -p /var/cache/nginx/wp-media
chown nginx:nginx /var/cache/nginx/wp-media

FRONTEND_TARGET=legacy
if [ -f /etc/nginx/runtime/frontend-target ]; then
  FRONTEND_TARGET="$(cat /etc/nginx/runtime/frontend-target)"
fi
case "$FRONTEND_TARGET" in
  legacy) FRONTEND_UPSTREAM=host.docker.internal:3000 ;;
  blue) FRONTEND_UPSTREAM=frontend:3000 ;;
  green) FRONTEND_UPSTREAM=frontend-green:3000 ;;
  *) echo "Invalid frontend target: $FRONTEND_TARGET" >&2; exit 1 ;;
esac
export FRONTEND_UPSTREAM

sh /etc/nginx/templates/render.sh init
exec nginx -g 'daemon off;'
