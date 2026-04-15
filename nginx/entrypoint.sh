#!/bin/sh
# Resolve openrouter.ai to IPv4 only (avoid AAAA/IPv6 which Docker on macOS can't reach)
OPENROUTER_IP=$(getent ahostsv4 openrouter.ai | grep -m1 STREAM | awk '{print $1}')
if [ -n "$OPENROUTER_IP" ]; then
    echo "$OPENROUTER_IP openrouter.ai" >> /etc/hosts
    echo "[entrypoint] Added openrouter.ai -> $OPENROUTER_IP to /etc/hosts"
else
    echo "[entrypoint] WARNING: Could not resolve openrouter.ai to IPv4"
fi

# Substitute env vars in nginx config template
envsubst '${OPENROUTER_API_KEY}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Start nginx
nginx -g 'daemon off;'