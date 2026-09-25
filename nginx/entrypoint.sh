#!/bin/sh
set -eu

mkdir -p /var/cache/nginx/wp-media
chown nginx:nginx /var/cache/nginx/wp-media

echo "DOMAIN=$DOMAIN"

if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  echo "Using HTTPS template"
  envsubst "\$DOMAIN" < /etc/nginx/templates/https.conf.template > /etc/nginx/conf.d/default.conf
else
  echo "Using HTTP bootstrap template"
  envsubst "\$DOMAIN" < /etc/nginx/templates/http.conf.template > /etc/nginx/conf.d/default.conf
fi

nginx -t
exec nginx -g 'daemon off;'
