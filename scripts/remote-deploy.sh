#!/usr/bin/env bash
# Runs on the server (through SSM Run Command, as root).
# Switches the app to <image>:<tag> and rolls back if the new container is not healthy.
#
# Usage: remote-deploy.sh <image> <tag>
#
# Environment:
#   APP_DIR        directory with compose.yaml, default /opt/app
#   PRUNE_IMAGES   1 (default) removes unused images older than 72 h after a good deploy
set -euo pipefail

IMAGE="${1:?usage: remote-deploy.sh <image> <tag>}"
TAG="${2:?usage: remote-deploy.sh <image> <tag>}"
APP_DIR="${APP_DIR:-/opt/app}"
PRUNE_IMAGES="${PRUNE_IMAGES:-1}"

cd "$APP_DIR"

up() {
  # --pull missing: SHA tags never change, so a local copy is always the right image.
  # --wait: return only when the HEALTHCHECK reports "healthy", fail otherwise.
  docker compose up -d --pull missing --wait --wait-timeout 60
}

previous_tag=""
if [[ -f .env ]]; then
  previous_tag=$(grep -E '^IMAGE_TAG=' .env | cut -d= -f2- || true)
  cp .env .env.previous
fi

printf 'IMAGE=%s\nIMAGE_TAG=%s\n' "$IMAGE" "$TAG" >.env
echo "deploying $IMAGE:$TAG (previous: ${previous_tag:-none})"

if up; then
  rm -f .env.previous
  if [[ $PRUNE_IMAGES == 1 ]]; then
    docker image prune -af --filter "until=72h" >/dev/null || true
  fi
  echo "deployed $TAG"
  exit 0
fi

echo "new version is not healthy, last logs:"
docker compose logs --tail 30 || true

if [[ -z $previous_tag ]]; then
  echo "deploy failed, no previous version to roll back to"
  exit 1
fi

mv .env.previous .env
echo "ROLLBACK to $previous_tag"
if ! up; then
  echo "rollback also failed, manual action needed"
fi
exit 1
