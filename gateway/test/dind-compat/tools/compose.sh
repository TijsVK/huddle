#!/usr/bin/env bash
# docker compose: multi-service, healthcheck gating, service-name DNS, and a
# published port reachable on the devcontainer's localhost (shared netns).
source "$(dirname "$0")/../lib.sh"
NAME=compose
NET="${1:-bridge}"
rc=0

up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'mkdir -p /home/dev/app && cat > /home/dev/app/compose.yaml' <<'YAML'
services:
  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 2s
      retries: 15
  web:
    image: nginx:alpine
    ports: ["8080:80"]
    depends_on:
      redis:
        condition: service_healthy
YAML

# Pre-pull with retry: compose's own pull uses a short deadline and the registry
# can be slow on the bridge network (transient "context deadline exceeded").
dcsh "$NAME" 'for img in redis:7-alpine nginx:alpine; do for i in 1 2 3 4; do docker pull -q "$img" >/dev/null 2>&1 && break; sleep 3; done; done' >/dev/null 2>&1

if dcsh "$NAME" 'cd /home/dev/app && docker compose up -d --wait' >/tmp/compose.log 2>&1; then
  pass "$NAME: compose up --wait (healthcheck gate satisfied)"
else
  fail "$NAME: compose up --wait"; rc=1
fi

# Published port on the devcontainer's own localhost (shared netns).
code=$(dcsh "$NAME" 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8080' 2>/dev/null)
[ "$code" = "200" ] && pass "$NAME: nginx reachable on localhost:8080 (=$code)" || { fail "$NAME: localhost:8080 -> $code"; rc=1; }

# IPv6 loopback too (Aspire/DCP addresses http://[::1]:port).
code6=$(dcsh "$NAME" 'curl -s -o /dev/null -w "%{http_code}" "http://[::1]:8080"' 2>/dev/null)
[ "$code6" = "200" ] && pass "$NAME: nginx reachable on [::1]:8080 (=$code6)" || { fail "$NAME: [::1]:8080 -> $code6"; rc=1; }

# Cross-service DNS by compose service name.
ping=$(dcsh "$NAME" 'cd /home/dev/app && docker compose exec -T redis redis-cli -h redis ping' 2>/dev/null | tr -d "\r")
[ "$ping" = "PONG" ] && pass "$NAME: service-name DNS redis->redis PONG" || { fail "$NAME: cross-service DNS ($ping)"; rc=1; }

dcsh "$NAME" 'cd /home/dev/app && docker compose down -v' >/dev/null 2>&1
down "$NAME"
exit $rc
