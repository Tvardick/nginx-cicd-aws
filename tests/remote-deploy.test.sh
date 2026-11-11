#!/usr/bin/env bash
# Integration test for scripts/remote-deploy.sh against the local Docker daemon.
# Uses its own compose projects and host port, so it does not touch other containers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=nginx-cicd-aws-test
export HOST_PORT="${HOST_PORT:-18080}"
export PRUNE_IMAGES=0
WORK=$(mktemp -d)
failures=0
out=""
code=0

down_project() {
  local ids
  mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=$1")
  ((${#ids[@]} == 0)) || docker rm -f "${ids[@]}" >/dev/null
}

cleanup() {
  down_project "rd-test-first-$$"
  down_project "rd-test-main-$$"
  rm -rf "$WORK"
}
trap cleanup EXIT

# Runs remote-deploy.sh in directory $1 with tag $2. Sets $out and $code.
run_deploy() {
  set +e
  out=$(APP_DIR="$1" "$ROOT_DIR/scripts/remote-deploy.sh" "$IMAGE" "$2" 2>&1)
  code=$?
  set -e
}

# check <name> <command...>: the check passes when the command exits 0.
check() {
  local name=$1 line
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    while IFS= read -r line; do printf '    | %s\n' "$line"; done <<<"$out"
    failures=$((failures + 1))
  fi
}

refute() { ! "$@"; }
output_has() { grep -qF -- "$1" <<<"$out"; }
served_version() { curl -fsS "http://127.0.0.1:$HOST_PORT/version.txt" 2>/dev/null || true; }
serves() { [[ $(served_version) == "$1" ]]; }

echo "building test images"
IMAGE=$IMAGE TAG=good "$ROOT_DIR/scripts/deploy.sh" build >/dev/null 2>&1
IMAGE=$IMAGE TAG=good2 "$ROOT_DIR/scripts/deploy.sh" build >/dev/null 2>&1
docker build -q -t "$IMAGE:broken" "$ROOT_DIR/tests/fixtures/broken" >/dev/null

# Scenario 1: the very first deploy fails. There is nothing to roll back to.
mkdir "$WORK/first" && cp "$ROOT_DIR/compose.yaml" "$WORK/first/"
export COMPOSE_PROJECT_NAME="rd-test-first-$$"
run_deploy "$WORK/first" broken
check "first deploy failure exits 1" test "$code" -eq 1
check "first deploy failure explains why" output_has "no previous version"
check "first deploy failure has no bash error" refute output_has "unbound variable"
down_project "$COMPOSE_PROJECT_NAME"

# Scenarios 2-4 share one app directory, like a real server.
mkdir "$WORK/main" && cp "$ROOT_DIR/compose.yaml" "$WORK/main/"
export COMPOSE_PROJECT_NAME="rd-test-main-$$"

run_deploy "$WORK/main" good
check "first deploy succeeds" test "$code" -eq 0
check "first deploy serves good" serves good

run_deploy "$WORK/main" good2
check "second deploy succeeds" test "$code" -eq 0
check "second deploy serves good2" serves good2

run_deploy "$WORK/main" broken
check "broken deploy exits 1" test "$code" -eq 1
check "broken deploy reports rollback" output_has "ROLLBACK to good2"
check "rollback restores previous tag in .env" grep -q '^IMAGE_TAG=good2$' "$WORK/main/.env"
check "rollback serves good2" serves good2

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
