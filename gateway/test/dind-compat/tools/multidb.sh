#!/usr/bin/env bash
# Databases workflow: Postgres + MySQL + MongoDB via compose, health-gated, each
# reached with its own client and answering a query. Common backend dev stack.
source "$(dirname "$0")/../lib.sh"
NAME=multidb
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'mkdir -p /work/db && cat > /work/db/compose.yaml' <<'YAML'
services:
  pg:
    image: postgres:16-alpine
    environment: { POSTGRES_PASSWORD: pw }
    healthcheck: { test: ["CMD","pg_isready","-U","postgres"], interval: 2s, timeout: 2s, retries: 30 }
  my:
    image: mysql:8
    environment: { MYSQL_ROOT_PASSWORD: pw }
    healthcheck: { test: ["CMD","mysqladmin","ping","-uroot","-ppw"], interval: 3s, timeout: 3s, retries: 40 }
  mo:
    image: mongo:7
    healthcheck: { test: ["CMD","mongosh","--quiet","--eval","db.runCommand({ping:1}).ok"], interval: 3s, timeout: 3s, retries: 30 }
YAML

if dcsh "$NAME" 'cd /work/db && docker compose up -d --wait' >/tmp/multidb.log 2>&1; then
  pass "$NAME: compose up --wait (pg + mysql + mongo healthy)"
else fail "$NAME: compose up --wait"; tail -8 /tmp/multidb.log >&2; down "$NAME"; exit 1; fi

pg=$(dcsh "$NAME" 'cd /work/db && docker compose exec -T pg psql -U postgres -tAc "select 40+2"' 2>/dev/null | tr -d '[:space:]')
[ "$pg" = 42 ] && pass "$NAME: postgres query (=$pg)" || { fail "$NAME: postgres ($pg)"; rc=1; }

# mysql:8's healthcheck can go healthy just before the root password is applied,
# so retry the authenticated query a few times.
my=""; for i in $(seq 1 15); do
  my=$(dcsh "$NAME" 'cd /work/db && docker compose exec -T my mysql -uroot -ppw -N -e "select 40+2" 2>/dev/null' | tr -d '[:space:]')
  [ "$my" = 42 ] && break; sleep 3
done
[ "$my" = 42 ] && pass "$NAME: mysql query (=$my)" || { fail "$NAME: mysql ($my)"; rc=1; }

mo=$(dcsh "$NAME" 'cd /work/db && docker compose exec -T mo mongosh --quiet --eval "print(40+2)"' 2>/dev/null | tr -d '[:space:]')
[ "$mo" = 42 ] && pass "$NAME: mongo query (=$mo)" || { fail "$NAME: mongo ($mo)"; rc=1; }

dcsh "$NAME" 'cd /work/db && docker compose down -v' >/dev/null 2>&1
down "$NAME"
exit $rc
