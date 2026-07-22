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

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

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

install -d -m 0755 -o deploy -g deploy /opt/0xda-market
install -d -m 0750 -o deploy -g deploy /opt/0xda-market/releases
install -d -m 0750 -o deploy -g deploy /opt/0xda-market/shared
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
# current session, before enabling UFW. This prevents remote lockout on VPS
# images that expose SSH on a non-standard port such as 22022.
mapfile -t ssh_ports < <(
  {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      awk '{print $4}' <<<"${SSH_CONNECTION}"
    fi
    sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
  } | awk '/^[0-9]+$/' | sort -nu
)

if [[ "${#ssh_ports[@]}" -eq 0 ]]; then
  ssh_ports=(22)
fi

for ssh_port in "${ssh_ports[@]}"; do
  ufw allow "${ssh_port}/tcp"
done
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

primary_ssh_port="${ssh_ports[0]}"

cat <<EOF

Bootstrap complete.

GitHub Actions private key:
  ${key_path}

Copy its full contents into the production environment secret:
  VPS_SSH_PRIVATE_KEY

Repository production settings:
  secret VPS_HOST=<public VPS IP>
  secret VPS_USER=deploy
  variable VPS_PORT=${primary_ssh_port}
  variable VPS_DEPLOY_PATH=/opt/0xda-market

Before the first release deployment, create:
  /opt/0xda-market/shared/.env

Start from deploy/vps/.env.example and keep VERIFY_PUBLIC_HTTPS=0 until DNS points to this VPS.
EOF
