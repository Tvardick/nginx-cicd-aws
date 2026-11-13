#!/bin/bash
# First boot of the EC2 instance: install Docker and the Compose plugin.
# Terraform templatefile() fills in compose_version. $${...} is a literal bash variable.
set -euo pipefail

dnf install -y docker
systemctl enable --now docker

# Amazon Linux 2023 has no docker-compose-plugin package, so install the release binary.
plugin_dir=/usr/local/lib/docker/cli-plugins
release=https://github.com/docker/compose/releases/download/${compose_version}
mkdir -p "$${plugin_dir}"
cd "$${plugin_dir}"
curl -fsSLO --retry 3 "$${release}/docker-compose-linux-x86_64"
curl -fsSLO --retry 3 "$${release}/docker-compose-linux-x86_64.sha256"
sha256sum -c docker-compose-linux-x86_64.sha256
rm docker-compose-linux-x86_64.sha256
mv docker-compose-linux-x86_64 docker-compose
chmod 755 docker-compose

# The deploy logs in as ec2-user. The docker group lets it run docker without sudo.
usermod -aG docker ec2-user
install -d -o ec2-user -g ec2-user /opt/app
