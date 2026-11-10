#!/bin/bash
# Build sonic-swss-common packages (CI-identical build-env/build.sh).
# Uses the persistent "swsscommon-build" container. Produces libswsscommon,
# libswsscommon-dev, python3-swsscommon, sonic-db-cli (+dbgsym) debs in
# ~/SONiC/sonic-swss-common/. Follow with test-swsscommon.sh for the full
# CI unit-test battery. ~10-15 min.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ensure_swsscommon_container() {
  docker image inspect swsscommon-bookworm:latest >/dev/null 2>&1 \
    || die "image swsscommon-bookworm:latest missing - run scripts/build-swsscommon-image.sh first"
  if docker ps --format '{{.Names}}' | grep -q '^swsscommon-build$'; then return 0; fi
  if docker ps -a --format '{{.Names}}' | grep -q '^swsscommon-build$'; then
    log "starting existing container swsscommon-build"
    docker start swsscommon-build >/dev/null
  else
    log "creating persistent container swsscommon-build"
    docker run -d --name swsscommon-build --restart unless-stopped \
      -v /home/liu:/home/liu swsscommon-bookworm:latest sleep infinity >/dev/null
  fi
  docker ps --format '{{.Names}}' | grep -q '^swsscommon-build$' \
    || die "container swsscommon-build failed to start"
}

ensure_swsscommon_container
ensure_git_trust

log "build-env/build.sh (as container user liu, git trust injected)"
docker exec -u liu -e GIT_CONFIG_GLOBAL="$SONIC_WS/sonic-sairedis/.gitconfig-container" \
  swsscommon-build bash -c \
  "cd /home/liu/SONiC/sonic-swss-common && ./build-env/build.sh" | tail -25
rc=${PIPESTATUS[0]}
if [ "$rc" -eq 0 ]; then
  log "OK: $(ls "$SONIC_WS/sonic-swss-common"/*.deb | wc -l) debs in $SONIC_WS/sonic-swss-common/"
  ls -la "$SONIC_WS/sonic-swss-common"/*.deb | awk '{print $NF, $5}'
else
  die "build.sh exit=$rc — check references/pitfalls.md"
fi
