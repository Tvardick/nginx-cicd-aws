#!/usr/bin/env bash
# Runs on the server. deploy.py starts it over SSH.
# Starts <image>:<tag>. If the new container is not healthy, starts the previous tag again.
#
# Usage: remote-deploy.sh <image> <tag>
set -euo pipefail

image=$1
tag=$2
cd "${APP_DIR:-/opt/app}"

# Remember the tag that runs now. There is no .env before the first deploy.
previous_tag=""
if [ -f .env ]; then
  previous_tag=$(grep '^IMAGE_TAG=' .env | cut -d= -f2)
fi

# compose.yaml reads IMAGE and IMAGE_TAG from .env.
printf 'IMAGE=%s\nIMAGE_TAG=%s\n' "$image" "$tag" > .env
echo "deploying $image:$tag (previous: ${previous_tag:-none})"

# --wait: wait until the HEALTHCHECK says "healthy", fail after 60 seconds.
if docker compose up -d --wait --wait-timeout 60; then
  echo "deployed $tag"
  exit 0
fi

echo "new version is not healthy, last logs:"
# "|| true": a problem with the logs must not stop the rollback below.
docker compose logs --tail 30 || true

if [ -z "$previous_tag" ]; then
  echo "no previous version to roll back to"
  exit 1
fi

echo "ROLLBACK to $previous_tag"
printf 'IMAGE=%s\nIMAGE_TAG=%s\n' "$image" "$previous_tag" > .env
docker compose up -d --wait --wait-timeout 60
exit 1
