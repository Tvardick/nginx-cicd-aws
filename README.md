# nginx-cicd-aws

A "Hello, World!" page on nginx, packaged as a Docker image and deployed to AWS EC2
by a GitHub Actions pipeline on every push to `main`.

**Live:** http://13.48.53.223 (the deployed commit: http://13.48.53.223/version.txt)

## Architecture

```
git push ─► GitHub Actions
             ├─ test (every push and PR):
             │    hadolint, shellcheck → docker build → smoke test → Trivy → rollback test
             │    main only: push the tested image to GHCR (tag = git SHA)
             └─ deploy (main only, environment "production")
                  └─ scp + ssh ─► EC2 (Amazon Linux 2023, Docker + Compose)
                                    └─ remote-deploy.sh: compose up --wait
                                       unhealthy → automatic rollback
Browser ─HTTP :80─► Elastic IP ─► EC2 ─► nginx container (:8080, non-root)
```

## Repository layout

| Path | Purpose |
|---|---|
| `app/` | Static site |
| `nginx/default.conf` | nginx server: security headers, `/healthz` |
| `Dockerfile` | Image on `nginx-unprivileged` (alpine, uid 101, port 8080) |
| `compose.yaml` | How the server runs the image |
| `scripts/deploy.py` | `build`, `test`, `push`, `deploy`, `all` — used locally and by CI, Python standard library only |
| `scripts/remote-deploy.sh` | Runs on the server: switch version, health check, rollback |
| `tests/remote-deploy.test.sh` | Integration test of deploy and rollback on local Docker |
| `terraform/` | EC2, Elastic IP, security group, SSH key pair |
| `.github/workflows/ci-cd.yml` | The pipeline |

## Prerequisites

- Docker 25+ with the Compose plugin, Python 3.10+, `curl`, OpenSSH client
- Terraform 1.10+
- AWS CLI v2, logged in to an account that can create EC2 resources
- GitHub CLI (`gh`), a GitHub repository with this code

## Setup from scratch

1. Create the deploy SSH key:

   ```bash
   ssh-keygen -t ed25519 -N "" -C nginx-cicd-deploy -f ~/.ssh/nginx-cicd-deploy
   ```

2. Create the infrastructure:

   ```bash
   cd terraform
   terraform init
   terraform apply
   terraform output
   ```

3. Wait 2-3 minutes for Docker to install. Check the server host key: the fingerprint
   from `ssh-keyscan -t ed25519 <ip> | ssh-keygen -lf -` must match the one in
   EC2 → Instance → Actions → Monitor and troubleshoot → Get system log.

4. In GitHub → Settings → Environments, create `production` with deployment branch `main`.
   Fill it from the repository root:

   ```bash
   ip=$(terraform -chdir=terraform output -raw public_ip)
   gh variable set DEPLOY_HOST --env production --body "$ip"
   gh variable set APP_URL --env production --body "http://$ip"
   gh variable set SSH_KNOWN_HOSTS --env production --body "$(ssh-keyscan -t ed25519 "$ip" 2>/dev/null)"
   gh secret set SSH_PRIVATE_KEY --env production < ~/.ssh/nginx-cicd-deploy
   ```

5. Push to `main`. The first run pushes the image to GHCR and deploys it.

6. GHCR creates a new package as private. The server pulls without credentials, so make the
   package public: GitHub → Packages → `nginx-cicd-aws` → Package settings → Change visibility.
   If the first deploy failed because of this, re-run the `deploy` job.

## Local usage

The image name must be lowercase (GHCR rule).

```bash
export IMAGE=nginx-cicd-aws
scripts/deploy.py build                  # build $IMAGE:<git sha>
scripts/deploy.py test                   # run it and check pages, headers, version
tests/remote-deploy.test.sh              # deploy, upgrade and rollback on local Docker

IMAGE_TAG=$(git rev-parse HEAD) HOST_PORT=8088 docker compose up -d --wait
curl localhost:8088
docker compose down
```

Manual deploy from a workstation (needs `docker login ghcr.io`):

```bash
export IMAGE=ghcr.io/<owner-lowercase>/nginx-cicd-aws
export DEPLOY_HOST=$(terraform -chdir=terraform output -raw public_ip)
export SSH_KEY=~/.ssh/nginx-cicd-deploy
scripts/deploy.py all
```

## Pipeline

| Job | Runs on | What it does |
|---|---|---|
| `test` | every push and PR | lint, build, smoke test, Trivy (HIGH/CRITICAL, fixed only), rollback test; on `main` also pushes the image |
| `deploy` | push to `main` | copy config to the server over SSH, run `remote-deploy.sh`, check the public URL |

The `deploy` job does not build. The server pulls the exact image that `test` checked and pushed.
At the end the job reads `/version.txt` from the public URL and compares it with the commit SHA.

## Rollback

- **Automatic.** `remote-deploy.sh` starts the new version with `docker compose up --wait`.
  If the container does not become healthy in 60 seconds, the script restores the previous
  version and the pipeline fails.
- **Manual.** Revert the commit and push: `git revert <sha> && git push`. Every image is
  tagged with its commit SHA, so any earlier version can be deployed again:
  `TAG=<old sha> scripts/deploy.py deploy`.

## Rotate the deploy key

Terraform puts the key on the server only at first boot, so rotate it on the server:

1. Create a new key pair (setup step 1, new file name).
2. Append the new public key to `/home/ec2-user/.ssh/authorized_keys` on the server.
3. Update the `SSH_PRIVATE_KEY` secret and run the pipeline.
4. Remove the old public key from `authorized_keys`.

## Design decisions and trade-offs

- **SSH for deploys.** The simplest delivery path: two commands (`scp`, `ssh`), the remote
  exit code fails the pipeline, the server output goes straight to the CI log. The trade-off:
  port 22 is open to the internet, because GitHub-hosted runners have no fixed IPs.
  To limit the risk:
  - key authentication only, passwords are disabled on Amazon Linux 2023;
  - a dedicated deploy key, not a personal one;
  - the key is an environment secret: only jobs in `production` (branch `main`) can read it;
  - `known_hosts` pins the server host key, `BatchMode=yes` never accepts an unknown key.
- **Python for the build and deploy script, bash on the server.** The Python script uses only
  the standard library, so nothing has to be installed. The server script stays in bash:
  it needs nothing but Docker.
- **Immutable SHA tags, no `latest`.** The tag says exactly which commit runs, rollback is a
  tag change. Compose pulls a tag only when the server does not have it yet, and a SHA tag never changes.
- **Config travels with the deploy.** Each deploy copies `compose.yaml` and
  `remote-deploy.sh` to the server, so the server always matches the deployed commit.
- **Hardened container.** Non-root user, read-only root filesystem, all capabilities dropped,
  `no-new-privileges`, log rotation.
- **`apk upgrade` in the Dockerfile.** It installs security fixes released after the base
  image. The cost: the build is not byte-for-byte reproducible even with a pinned digest.
- **Public GHCR package.** The server needs no registry credentials.
- **Local Terraform state.** Enough for one person and one environment. For a team: an S3
  backend with `use_lockfile = true`.
- **One instance.** No high availability: a deploy restarts the container (a few seconds of
  downtime).

## What I would add for production

- AWS SSM Run Command instead of SSH: port 22 closed, no SSH keys, every command in CloudTrail
- GitHub OIDC for AWS access instead of long-lived secrets
- HTTPS (ALB with ACM, or Caddy with Let's Encrypt)
- ALB + Auto Scaling Group for zero-downtime deploys
- S3 remote state, separate environments (staging, production)
- Monitoring and logs: Prometheus, Grafana, Loki or CloudWatch
- Alerts on failed deploys and on `/healthz`
- Remove old images on the server after a successful deploy (`docker image prune`)

## Clean up

```bash
cd terraform && terraform destroy
```

