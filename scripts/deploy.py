#!/usr/bin/env python3
"""Build, test, push and deploy the nginx hello-world image.

Usage: scripts/deploy.py <build|test|push|deploy|all>

Environment variables:
  IMAGE        required, for example ghcr.io/<user>/nginx-cicd-aws
  TAG          optional, default: the current git commit SHA
  SOURCE_URL   optional, repository URL; GHCR uses it to link the image to the repository
  DEPLOY_HOST  required for deploy: the server IP (terraform output public_ip)
  SSH_KEY      optional, private key file for ssh and scp
"""

import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SMOKE_PORT = 8089


def run(*command):
    """Print a command, run it and stop the script if it fails."""
    print("+", " ".join(command), flush=True)
    subprocess.run(command, check=True)


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def git_sha():
    result = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    )
    return result.stdout.strip()


IMAGE = os.environ.get("IMAGE") or fail("IMAGE is required, e.g. ghcr.io/<user>/nginx-cicd-aws")
TAG = os.environ.get("TAG") or git_sha()
REF = f"{IMAGE}:{TAG}"

# The deploy sends IMAGE and TAG to a shell on the server.
# Only safe characters are allowed, so they cannot add extra commands there.
if not re.fullmatch(r"[a-z0-9./_-]+", IMAGE):
    fail(f"IMAGE has unsafe characters: {IMAGE}")
if not re.fullmatch(r"[A-Za-z0-9_.-]+", TAG):
    fail(f"TAG has unsafe characters: {TAG}")


def build():
    run(
        "docker", "build",
        "--build-arg", f"GIT_SHA={TAG}",
        "--label", f"org.opencontainers.image.source={os.environ.get('SOURCE_URL', 'unknown')}",
        "--tag", REF,
        str(ROOT),
    )


def get(path):
    """Return the response headers and body of http://127.0.0.1:SMOKE_PORT<path>."""
    with urllib.request.urlopen(f"http://127.0.0.1:{SMOKE_PORT}{path}", timeout=5) as response:
        return response.headers, response.read().decode()


def check(name, ok):
    if not ok:
        fail(f"smoke test failed: {name}")
    print(f"PASS {name}")


def smoke_test():
    name = f"smoke-{os.getpid()}"
    run("docker", "run", "-d", "--name", name, "-p", f"127.0.0.1:{SMOKE_PORT}:8080", REF)
    try:
        # nginx needs a moment to start. Try for up to 30 seconds.
        for _ in range(30):
            try:
                get("/healthz")
                break
            except OSError:
                time.sleep(1)

        headers, body = get("/")
        check("index page says Hello, World!", "Hello, World!" in body)
        check("header X-Content-Type-Options", headers.get("X-Content-Type-Options") == "nosniff")
        check("header X-Frame-Options", headers.get("X-Frame-Options") == "DENY")

        _, body = get("/healthz")
        check("healthz returns ok", body.strip() == "ok")

        _, body = get("/version.txt")
        check("version.txt shows the tag", body.strip() == TAG)
    finally:
        # Remove the test container even if a check failed.
        subprocess.run(["docker", "rm", "-f", name], check=False, capture_output=True)


def push():
    run("docker", "push", REF)


def deploy():
    host = os.environ.get("DEPLOY_HOST") or fail("DEPLOY_HOST is required: the server IP")
    target = f"ec2-user@{host}"
    # BatchMode: fail at once instead of asking for a password or a "yes".
    ssh_options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    if os.environ.get("SSH_KEY"):
        ssh_options += ["-i", os.environ["SSH_KEY"]]

    # Copy the server files with every deploy, so the server always matches this commit.
    run("scp", *ssh_options,
        str(ROOT / "compose.yaml"), str(ROOT / "scripts" / "remote-deploy.sh"),
        f"{target}:/opt/app/")

    # ssh exits with the exit code of remote-deploy.sh.
    # A failed deploy on the server makes run() fail here too.
    run("ssh", *ssh_options, target, "bash", "/opt/app/remote-deploy.sh", IMAGE, TAG)
    print(f"deployed {REF}")


COMMANDS = {
    "build": [build],
    "test": [smoke_test],
    "push": [push],
    "deploy": [deploy],
    "all": [build, smoke_test, push, deploy],
}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        fail(f"usage: {sys.argv[0]} <{'|'.join(COMMANDS)}>")
    try:
        for step in COMMANDS[sys.argv[1]]:
            step()
    except subprocess.CalledProcessError as error:
        fail(f"command failed with exit code {error.returncode}: {' '.join(error.cmd)}")
    except OSError as error:
        # For example, the smoke test cannot open a page: connection refused or HTTP 500.
        fail(f"smoke test failed: {error}")
