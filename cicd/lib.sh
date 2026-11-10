#!/bin/bash
# Shared helpers for sonic-cicd scripts. Source this file: . "$(dirname "$0")/lib.sh"
# Environment facts fixed for this machine (see skill SKILL.md before changing).

SONIC_WS="${SONIC_WS:-$HOME/SONiC}"                     # WSL-side build trees (ext4)
WIN_WS="/mnt/c/Users/liu/Documents/SONiC"               # Windows-side working copies
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGED_DIR="${STAGED_DIR:-$HOME/staged}"
PROXY_HOST="172.17.0.1"                                 # Windows host via WSL default route
PROXY="http://${PROXY_HOST}:7890"                       # Clash on 0.0.0.0:7890
WSL_DISTRO="Ubuntu-24.04"
SLAVE_IMG="sonicdev-microsoft.azurecr.io:443/sonic-slave-bookworm"
GITTRUST="$SONIC_WS/sonic-sairedis/.gitconfig-container"

log()  { echo "[sonic-cicd $(date +%H:%M:%S)] $*"; }
die()  { echo "[sonic-cicd] FATAL: $*" >&2; exit 1; }

with_proxy() {  # run a command with proxy env (GitHub/apt go through Clash)
  http_proxy="$PROXY" https_proxy="$PROXY" "$@"
}

ensure_git_trust() {
  # git "dubious ownership" guard: build containers run as root but the tree
  # belongs to the WSL user; without this attrversion.sh SILENTLY degrades
  # (SAI_METADATA_HAVE_ATTR_VERSION becomes 0, AttrVersionChecker test fails,
  # debs ship without attribute versions). Never remove this.
  printf '[safe]\n\tdirectory = *\n' > "$GITTRUST"
}

ensure_slave_tags() {
  # CI uses sonic-slave-bookworm:master-amd64; repo Dockerfiles reference
  # :latest (sairedis) and :master (swss). Align all three to the CI image.
  # The refresh-pull is SKIPPED when the image exists locally — a registry
  # fetch through the proxy can hang for hours (observed), and the image only
  # changes on slave rebuilds (refresh deliberately: docker rmi the local tag).
  if ! docker image inspect "${SLAVE_IMG}:master-amd64" >/dev/null 2>&1; then
    timeout 300 with_proxy docker pull "${SLAVE_IMG}:master-amd64" \
      || die "pull of ${SLAVE_IMG}:master-amd64 failed (check proxy ${PROXY})"
  fi
  docker image inspect "${SLAVE_IMG}:master-amd64" >/dev/null 2>&1 \
    || die "slave image ${SLAVE_IMG}:master-amd64 not available"
  docker tag "${SLAVE_IMG}:master-amd64" "${SLAVE_IMG}:latest"
  docker tag "${SLAVE_IMG}:master-amd64" "${SLAVE_IMG}:master"
}

apply_install_shim() {
  # Upstream debian/syncd-vs.install and syncd-rpc.install contain the literal
  # string "syncd.install" (self-reference since 2017). Current slave image's
  # debhelper cannot resolve it ("dh_install: missing files, aborting") while
  # CI's build somehow can. Local shim = copy the real list; verified
  # file-identical to CI artifacts. RE-APPLY AFTER ANY git checkout -- . !
  local d="$SONIC_WS/sonic-sairedis/debian"
  if grep -qx 'syncd.install' "$d/syncd-vs.install" 2>/dev/null; then
    cp "$d/syncd.install" "$d/syncd-vs.install"
    cp "$d/syncd.install" "$d/syncd-rpc.install"
    chmod 644 "$d/syncd-vs.install" "$d/syncd-rpc.install"
    log "applied syncd-vs/rpc.install shim"
  fi
}

normalize_repo() {  # normalize_repo <dir>  — EOL + exec bits + symlinks to match git index
  local d="$1"
  (cd "$d" || return 1
   git config core.autocrlf false
   # Windows copies have core.symlinks=false (rsynced in via .git/config): git
   # stores upstream symlinks (mode 120000) as PLAIN TEXT FILES there (e.g.
   # platform-common's sonic_eeprom/sonic_sfp, utilities' scripts/warm-reboot).
   # Delete the stand-ins so the checkout below recreates real symlinks.
   git config core.symlinks true
   while IFS=$'\t' read -r meta path; do
     [ "${meta%% *}" = "120000" ] && rm -f "$path" 2>/dev/null
   done < <(git ls-files -s)
   git checkout -- . 2>/dev/null || true          # tracked files back to LF/symlinks
   find . -path ./.git -prune -o -type f -print0 | xargs -0 -r chmod a-x 2>/dev/null
   while IFS=$'\t' read -r meta path; do
     [ "${meta%% *}" = "100755" ] && chmod 755 "$path" 2>/dev/null || true
   done < <(git ls-files -s)
  )
}

start_redis_in_container() {  # start_redis_in_container <container>
  local c="$1"
  docker exec -u root "$c" bash -c \
    '(service redis-server start || redis-server --daemonize yes) >/dev/null 2>&1; sleep 1; redis-cli ping' \
    | grep -q PONG || die "redis failed to start in container $c (tests need it)"
}

start_redis_unix() {  # start_redis_unix <container> — TCP + /var/run/redis/redis.sock
  # Several CI jobs (dhcp-relay, mgmt-common, gnmi, swss-common) sed a unix
  # socket into redis.conf; tests read SONiC DB config pointing at that socket.
  local c="$1"
  docker exec -u root "$c" bash -c '
    (service redis-server stop || pkill redis-server || true) >/dev/null 2>&1
    sed -ri "s|^# *unixsocket .*|unixsocket /var/run/redis/redis.sock|" /etc/redis/redis.conf 2>/dev/null || true
    grep -q "^unixsocket " /etc/redis/redis.conf || echo "unixsocket /var/run/redis/redis.sock" >> /etc/redis/redis.conf
    sed -ri "s/^unixsocketperm .*/unixsocketperm 777/" /etc/redis/redis.conf
    sed -ri "s/redis-server.sock/redis.sock/" /etc/redis/redis.conf
    (service redis-server start || redis-server --daemonize yes) >/dev/null 2>&1
    sleep 1; redis-cli ping' | grep -q PONG || die "redis failed to start in container $c"
}

ensure_go125() {  # ensure_go125 <container> — Go 1.25.9 at /usr/local/go125 (staged/tools/go)
  # gnmi/mgmt-common go.mod require go >= 1.25; slave images only ship 1.19,
  # and mgmt-common's Makefile hardcodes /usr/local/go/bin/go (1.19 cannot even
  # parse "go 1.25.9" in go.mod). So: install staged 1.25.9 and repoint
  # /usr/local/go at it (old 1.19 kept at /usr/local/go1.19-backup).
  local c="$1"
  docker exec -u root "$c" bash -c '
    if [ ! -x /usr/local/go125/bin/go ]; then
      [ -d /home/liu/staged/tools/go ] || { echo "staged go missing"; exit 1; }
      rm -rf /usr/local/go125 && cp -r /home/liu/staged/tools/go /usr/local/go125
    fi
    if [ -d /usr/local/go ] && [ ! -d /usr/local/go1.19-backup ]; then
      mv /usr/local/go /usr/local/go1.19-backup
    fi
    rm -rf /usr/local/go && ln -s /usr/local/go125 /usr/local/go'
  docker exec -u root "$c" /usr/local/go/bin/go version \
    || die "go 1.25 setup failed in container $c"
}

ensure_swss_container() {
  # Persistent build/test container. The compose CMD (sshd) exits, so we run
  # sleep infinity; --restart unless-stopped survives WSL/dockerd restarts.
  # NET_RAW/NET_ADMIN: dhcp4relay's sock_open test opens AF_PACKET sockets
  # (CI agents run privileged); without the caps that gtest fails locally.
  docker image inspect swss-bookworm-master:latest >/dev/null 2>&1 \
    || die "image swss-bookworm-master:latest missing - run scripts/build-swss-image.sh first"
  if docker ps --format '{{.Names}}' | grep -q '^swss-build$'; then return 0; fi
  if docker ps -a --format '{{.Names}}' | grep -q '^swss-build$'; then
    log "starting existing container swss-build"
    docker start swss-build >/dev/null
  else
    log "creating persistent container swss-build"
    docker run -d --name swss-build --restart unless-stopped \
      --cap-add NET_RAW --cap-add NET_ADMIN \
      -v /home/liu:/home/liu swss-bookworm-master:latest sleep infinity >/dev/null
  fi
  docker ps --format '{{.Names}}' | grep -q '^swss-build$' \
    || die "container swss-build failed to start"
}
