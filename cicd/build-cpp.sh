#!/bin/bash
# CI-equivalent build + unit test for the C++ repos on the swss-build
# container (toolchain + libswsscommon-dev + gtest + boost 1.83 already there).
# Usage: build-cpp.sh <sonic-linkmgrd|sonic-dhcp-relay|sonic-dhcpmon>
#   sonic-linkmgrd  : make test (190 gtest cases, ASan + gcovr) + dpkg-buildpackage
#   sonic-dhcp-relay: dpkg-buildpackage per subproject (gtest runs inside dh),
#                     submodules (PcapPlusPlus) auto-initialized
#   sonic-dhcpmon   : dpkg-buildpackage (upstream ships no unit tests)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

REPO="${1:-}"
case "$REPO" in
  sonic-linkmgrd|sonic-dhcp-relay|sonic-dhcpmon) ;;
  *) die "usage: $0 <sonic-linkmgrd|sonic-dhcp-relay|sonic-dhcpmon>" ;;
esac

ensure_swss_container
[ -d "$SONIC_WS/$REPO" ] || die "$SONIC_WS/$REPO missing - run sync-from-windows.sh $REPO"

run() {  # run <workdir-in-repo> <command...>
  local wd="$1"; shift
  docker exec -u liu -e GIT_CONFIG_GLOBAL=/home/liu/SONiC/sonic-sairedis/.gitconfig-container \
    swss-build bash -c "cd /home/liu/SONiC/$REPO${wd:+/$wd} && $*"
}

case "$REPO" in
  sonic-linkmgrd)
    start_redis_unix swss-build
    log "linkmgrd: make test (gtest+ASan+gcovr)"
    run "" "make -j\$(nproc) test 2>&1 | tail -20"
    log "linkmgrd: dpkg-buildpackage"
    run "" "dpkg-buildpackage -us -uc -b -j\$(nproc) 2>&1 | tail -3"
    ;;
  sonic-dhcp-relay)
    # submodules never initialized on the Windows copy; re-init after every sync
    log "dhcp-relay: init submodules (PcapPlusPlus)"
    (cd "$SONIC_WS/$REPO" && with_proxy git submodule update --init --recursive)
    normalize_repo "$SONIC_WS/$REPO" 2>/dev/null || true
    docker exec -u root swss-build bash -c \
      'which stg >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq stgit redis-server >/dev/null)' \
      || die "failed to ensure stgit/redis in container"
    start_redis_unix swss-build
    for sub in dhcp6relay dhcp4relay; do
      log "$sub: dpkg-buildpackage (gtest runs via dh_auto_test)"
      # NOTE: no `rm ../*.deb` here — dpkg-buildpackage overwrites its own
      # output and the parent dir ~/SONiC holds OTHER repos' debs too.
      run "$sub" "git config --global user.email build@sonic.net; git config --global user.name 'SONiC Build'; \
                  dpkg-buildpackage -us -uc -b -j\$(nproc) 2>&1 | tail -6"
    done
    ;;
  sonic-dhcpmon)
    log "dhcpmon: dpkg-buildpackage (no unit tests upstream)"
    run "" "dpkg-buildpackage -us -uc -b -j\$(nproc) 2>&1 | tail -3"
    ;;
esac

log "OK: $REPO done. debs produced this run:"
ls -1t "$SONIC_WS"/*.deb 2>/dev/null | head -4 || true
