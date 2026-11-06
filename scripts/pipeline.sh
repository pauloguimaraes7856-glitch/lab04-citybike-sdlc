#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: ./scripts/pipeline.sh <image>}"
KEY="${PROD_API_KEY:-lab-secret}"

wait_health() {
  for i in $(seq 1 20); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" != "true" ]; then
      echo "$1 is not running"
      docker logs "$1" || true
      return 1
    fi
    if curl -sf "http://localhost:$2/health" > /dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "timeout waiting for /health"
  return 1
}

gate() {
  name=$1
  shift
  echo "--- $name ---"
  docker rm -f citybike-gate > /dev/null 2>&1 || true
  docker run -d --name citybike-gate -p 4174:4173 "$@" "$IMAGE" > /dev/null
  if ! wait_health citybike-gate 4174 || ! TARGET_URL=http://localhost:4174 IMAGE_NAME="$IMAGE" ./scripts/test-$name.sh; then
    echo "pipeline stopped at $name"
    docker rm -f citybike-gate > /dev/null 2>&1 || true
    exit 1
  fi
  docker rm -f citybike-gate > /dev/null
}

gate staging -e APP_ENV=staging
gate uat -e APP_ENV=uat
gate oat -e APP_ENV=oat
gate preprod -e APP_ENV=preprod -e PROD_API_KEY="$KEY"

echo "--- prod ---"
docker rm -f citybike-prod > /dev/null 2>&1 || true
docker run -d --name citybike-prod -p 4173:4173 -e APP_ENV=production -e PROD_API_KEY="$KEY" "$IMAGE" > /dev/null
wait_health citybike-prod 4173
TARGET_URL=http://localhost:4173 ./scripts/test-prod.sh
echo "all gates passed for $IMAGE"
