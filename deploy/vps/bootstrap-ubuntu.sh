#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi

. /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
  echo "This bootstrap targets Ubuntu LTS; detected ${ID}" >&2
  exit 1
fi

apt-get update
apt-get install --yes ca-certificates curl fail2ban openssh-server ufw

for package in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove --yes "$package" 2>/dev/null || true
done

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER

apt-get update
apt-get install --yes docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker fail2ban ssh

if ! swapon --show=NAME --noheadings | grep -q .; then
  fallocate -l 2G /swapfile
  chmod 0600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

if ! id deploy >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" deploy
fi
usermod --append --groups docker deploy

for root in /opt/0xda-market /opt/0xda-market-bot; do
  install -d -m 0755 -o deploy -g deploy "$root"
  for environment in development production; do
    install -d -m 0750 -o deploy -g deploy "$root/environments/$environment/releases"
    install -d -m 0750 -o deploy -g deploy "$root/environments/$environment/shared"
  done
done
install -d -m 0750 -o deploy -g deploy /opt/0xda-market-runtime
install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh

key_path=/root/0xda-market-github-actions
if [[ ! -f "$key_path" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "github-actions@0xda-market" -f "$key_path"
fi

cat "${key_path}.pub" >>/home/deploy/.ssh/authorized_keys
sort -u /home/deploy/.ssh/authorized_keys -o /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 0600 /home/deploy/.ssh/authorized_keys

# Preserve every configured SSH port, and especially the port used by the
# current session, before enabling UFW. The deployment workflows connect to
# port 22022, so keep that firewall rule open even if sshd is not listening on
# it yet.
required_deploy_port=22022
mapfile -t ssh_ports < <(
  {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      awk '{print $4}' <<<"${SSH_CONNECTION}"
    fi
    sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
    printf '%s\n' "$required_deploy_port"
  } | awk '/^[0-9]+$/' | sort -nu
)

if [[ "${#ssh_ports[@]}" -eq 0 ]]; then
  ssh_ports=("$required_deploy_port")
fi

for ssh_port in "${ssh_ports[@]}"; do
  ufw allow "${ssh_port}/tcp"
done
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

if ! sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | grep -qx "$required_deploy_port"; then
  cat >&2 <<EOF_WARNING
WARNING: UFW allows TCP ${required_deploy_port}, but sshd does not currently
listen on that port. Configure and test SSH on ${required_deploy_port} before
running a deployment workflow.
EOF_WARNING
fi

cat <<EOF_SUMMARY

Bootstrap complete.

GitHub Actions private key:
  ${key_path}

Use the same key in the development and production GitHub environments for:
  0xda-market/0xda-market
  0xda-market/0xda-market-bot

Each repository environment requires:
  secret VPS_HOST=<public VPS IP>
  secret VPS_USER=deploy
  secret VPS_SSH_PRIVATE_KEY=<full private key>

Core variable:
  VPS_DEPLOY_PATH=/opt/0xda-market

Bot variable:
  VPS_BOT_DEPLOY_PATH=/opt/0xda-market-bot

The workflows use the fixed SSH port:
  22022

Create four runtime files before deploying:
  /opt/0xda-market/environments/development/shared/.env
  /opt/0xda-market/environments/production/shared/.env
  /opt/0xda-market-bot/environments/development/shared/.env
  /opt/0xda-market-bot/environments/production/shared/.env

Set DEPLOY_ENV to match each directory. Keep production inactive until its
runtime values, CI and smoke checks have been reviewed.
EOF_SUMMARY
