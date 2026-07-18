#!/usr/bin/env bash
# LocalStack: runs as a container, exposes 4566, and itself spawns per-service
# containers via the Docker socket — a good stress of "a container that uses
# Docker". Assert health + a real S3 operation end-to-end.
source "$(dirname "$0")/../lib.sh"
NAME=ls
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# Pre-pull the (large) images so the first-run fetch doesn't race the budget and
# so the s3 op below isn't waiting on the aws-cli pull.
dcsh "$NAME" 'docker pull -q localstack/localstack:3 >/dev/null 2>&1; docker pull -q amazon/aws-cli:latest >/dev/null 2>&1' >/dev/null 2>&1

# LocalStack needs to reach the daemon it runs in; share the same private socket
# (the filter socket — passthrough is allowed and stays filtered).
if dcsh "$NAME" 'docker run -d --name ls -p 4566:4566 -v /var/run/dind/docker.sock:/var/run/docker.sock -e SERVICES=s3 localstack/localstack:3' >/tmp/ls.log 2>&1; then
  pass "$NAME: localstack container started"
else fail "$NAME: localstack start"; rc=1; down "$NAME"; exit 1; fi

ok=""
for i in $(seq 1 60); do
  st=$(dcsh "$NAME" 'curl -s http://localhost:4566/_localstack/health' 2>/dev/null)
  echo "$st" | grep -q '"s3": *"\(available\|running\)"' && { ok=1; break; }
  sleep 2
done
[ -n "$ok" ] && pass "$NAME: /_localstack/health reports s3 available (localhost:4566)" || { fail "$NAME: health never ready"; rc=1; }

# Real S3 op via awscli in a throwaway container pointed at localstack. Retry: s3
# can lag the health endpoint's "available" by a few seconds on a cold start.
s3=""
for i in $(seq 1 8); do
  s3=$(dcsh "$NAME" 'docker run --rm --network container:ls -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli:latest --endpoint-url=http://localhost:4566 s3 mb s3://compat 2>&1' | tr -d "\r")
  printf '%s' "$s3" | grep -q "make_bucket: compat" && break
  # already-exists also proves it works (a prior iteration succeeded)
  printf '%s' "$s3" | grep -qi "BucketAlreadyOwnedByYou" && { s3="make_bucket: compat"; break; }
  sleep 3
done
assert_contains "$s3" "make_bucket: compat" "$NAME: aws s3 mb via localstack" || rc=1

dcsh "$NAME" 'docker rm -f ls >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
