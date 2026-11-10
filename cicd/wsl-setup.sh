#!/bin/bash
# One-time WSL bootstrap (already done on this machine; safe to re-run).
# Run INSIDE WSL as root:  wsl -d Ubuntu-24.04 -u root -- bash <this file>
# Idempotent: apt mirror, docker-ce, build user, repo staging.
set -euo pipefail
say(){ echo -e "\n=== [setup $(date +%H:%M:%S)] $* ==="; }

GW=$(ip route show default | awk '{print $3; exit}')
say "gateway (Windows host): ${GW:-none}"

# apt: TUNA mirror (fast in China, no proxy needed)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i.bak -E 's#https?://(archive\.ubuntu\.com|security\.ubuntu\.com)#https://mirrors.tuna.tsinghua.edu.cn#g' \
    /etc/apt/sources.list.d/ubuntu.sources
fi
apt-get update -qq
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq ca-certificates curl gnupg rsync git python3 >/dev/null

# docker-ce from TUNA mirror
if ! command -v docker >/dev/null 2>&1; then
  say "installing docker-ce"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu noble stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
[ "$(ps -p 1 -o comm=)" = "systemd" ] && systemctl enable --now docker || service docker start || true

# build user (non-root; swss compose requires a real uid/gid)
if ! id liu >/dev/null 2>&1; then
  useradd -m -u 1000 -s /bin/bash liu
  echo 'liu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/liu
  chmod 440 /etc/sudoers.d/liu
fi
usermod -aG docker liu

say "DONE. docker: $(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo not-running)"
echo "Next: as user liu run scripts/sync-from-windows.sh then stage-upstream.sh"
