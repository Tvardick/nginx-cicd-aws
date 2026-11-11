#!/usr/bin/env bash
# Build, test, push and deploy the nginx hello-world image.
#
# Usage: scripts/deploy.sh <build|test|push|deploy|all>
#
# Environment:
#   IMAGE        required, e.g. ghcr.io/<user>/nginx-cicd-aws
#   TAG          optional, default: current git commit SHA
#   SOURCE_URL   optional, repository URL for the OCI label (links the GHCR package to the repo)
#   INSTANCE_ID  required for deploy: EC2 instance ID (terraform output instance_id)
#   AWS_REGION   required for deploy
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:?IMAGE is required, e.g. ghcr.io/<user>/nginx-cicd-aws}"
TAG="${TAG:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
REF="${IMAGE}:${TAG}"

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# IMAGE and TAG end up inside a shell command that runs as root on the server.
# Only safe characters are allowed, so they cannot inject extra commands.
[[ $IMAGE =~ ^[a-z0-9./_-]+$ ]] || die "IMAGE has unsafe characters: $IMAGE"
[[ $TAG =~ ^[A-Za-z0-9_.-]+$ ]] || die "TAG has unsafe characters: $TAG"

build() {
  log "building $REF"
  docker build \
    --build-arg GIT_SHA="$TAG" \
    --label org.opencontainers.image.revision="$TAG" \
    --label org.opencontainers.image.source="${SOURCE_URL:-unknown}" \
    --tag "$REF" \
    "$ROOT_DIR"
}

# Fails the script with a clear message when $2 does not contain $3.
assert_contains() {
  local name=$1 haystack=$2 needle=$3
  grep -qiF -- "$needle" <<<"$haystack" || die "smoke test '$name': expected '$needle'"
  log "PASS $name"
}

smoke_test() {
  local name="smoke-$$" base headers path
  # Port 0 on the host: Docker picks a free port, so parallel runs do not collide.
  docker run -d --name "$name" -p 127.0.0.1::8080 "$REF" >/dev/null
  # shellcheck disable=SC2064 # expand $name now, not when the trap fires
  trap "docker rm -f '$name' >/dev/null 2>&1 || true" EXIT
  base="http://$(docker port "$name" 8080/tcp | head -n1)"

  for _ in $(seq 1 30); do
    curl -fsS "$base/healthz" >/dev/null 2>&1 && break
    sleep 1
  done

  assert_contains "index page" "$(curl -fsS "$base/")" "Hello, World!"
  assert_contains "healthz" "$(curl -fsS "$base/healthz")" "ok"
  assert_contains "version" "$(curl -fsS "$base/version.txt")" "$TAG"

  # Security headers must be on every page, not only on "/".
  for path in / /version.txt /missing-page; do
    headers=$(curl -sS -o /dev/null -D - "$base$path")
    assert_contains "nosniff $path" "$headers" "X-Content-Type-Options: nosniff"
    assert_contains "frame $path" "$headers" "X-Frame-Options: DENY"
    assert_contains "referrer $path" "$headers" "Referrer-Policy: no-referrer"
    assert_contains "csp $path" "$headers" "Content-Security-Policy:"
  done

  if grep -qi '^server: nginx/' <<<"$headers"; then
    die "smoke test 'server header': nginx version is visible"
  fi
  log "PASS server header hides version"

  [[ $(docker exec "$name" id -u) != 0 ]] || die "smoke test 'non-root': container runs as root"
  log "PASS non-root"

  docker rm -f "$name" >/dev/null
  trap - EXIT
}

push() {
  log "pushing $REF"
  docker push "$REF"
}

deploy() {
  : "${INSTANCE_ID:?INSTANCE_ID is required}"
  : "${AWS_REGION:?AWS_REGION is required}"
  local params command_id status

  # The server gets compose.yaml and remote-deploy.sh with every deploy,
  # so its configuration always matches this git commit.
  params=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$params'" RETURN
  jq -n \
    --arg compose "$(base64 -w0 "$ROOT_DIR/compose.yaml")" \
    --arg script "$(base64 -w0 "$ROOT_DIR/scripts/remote-deploy.sh")" \
    --arg image "$IMAGE" \
    --arg tag "$TAG" \
    '{
      commands: [
        "set -eu",
        "mkdir -p /opt/app",
        "echo \($compose) | base64 -d > /opt/app/compose.yaml",
        "echo \($script) | base64 -d > /opt/app/remote-deploy.sh",
        "bash /opt/app/remote-deploy.sh \($image) \($tag)"
      ],
      executionTimeout: ["300"]
    }' >"$params"

  log "sending deploy command to $INSTANCE_ID"
  # --timeout-seconds: if the agent does not start the command within 60 s, SSM drops it.
  # Without it, a queued old deploy could run later, after a newer one.
  command_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 60 \
    --comment "deploy ${TAG:0:12}" \
    --parameters "file://$params" \
    --query Command.CommandId \
    --output text)

  # send-command only queues the command. Poll until it finishes,
  # otherwise a failed deploy would look successful.
  local output
  status=Pending
  for _ in $(seq 1 72); do
    sleep 5
    if ! output=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$INSTANCE_ID" \
      --query Status \
      --output text 2>&1); then
      # Right after send-command the invocation may not exist yet. Any other error is real.
      [[ $output == *InvocationDoesNotExist* ]] || die "cannot read command status: $output"
      continue
    fi
    status=$output
    case $status in
      Pending | InProgress | Delayed) continue ;;
      *) break ;;
    esac
  done

  # Show the server output in the local terminal or the CI log.
  aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent \
    --output text || true
  aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" \
    --query StandardErrorContent \
    --output text >&2 || true

  [[ $status == Success ]] || die "remote deploy finished with status: $status"
  log "deployed $REF"
}

case "${1:-}" in
  build) build ;;
  test) smoke_test ;;
  push) push ;;
  deploy) deploy ;;
  all)
    build
    smoke_test
    push
    deploy
    ;;
  *)
    echo "usage: $0 <build|test|push|deploy|all>" >&2
    exit 2
    ;;
esac
