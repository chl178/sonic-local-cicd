#!/bin/bash
# Sync Windows working copies into the WSL build trees and normalize them
# (CRLF + exec bits). Run INSIDE WSL as user liu, after editing on Windows side.
#
# Repo list is split by pipeline:
#   REPOS_DPKGBUILD : repos with build-env/ + build.sh (sairedis/swss pattern)
#   REPOS_PYTEST    : pure-python repos tested via pytest in the py3 container
#   REPOS_CPP       : gtest/autotools C++ repos (make test pattern)
#   REPOS_GO        : CGO/go repos (need sibling sonic-mgmt-common checkout)
#   REPOS_BIG       : heavy repos, synced only on demand (pass as args)
# Sync a subset:  sync-from-windows.sh sonic-gnmi sonic-restapi
# (Order matters: submodule -> EOL checkout -> exec bits -> install shim.
#  git checkout -- . wipes the shim, so the shim is re-applied LAST.)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

REPOS_DPKGBUILD="sonic-sairedis sonic-swss sonic-swss-common"
REPOS_PYTEST="sonic-utilities sonic-snmpagent sonic-host-services sonic-dbsyncd sonic-platform-common sonic-platform-daemons"
REPOS_CPP="sonic-linkmgrd sonic-dhcp-relay sonic-dhcpmon"
REPOS_GO="sonic-mgmt-common sonic-gnmi sonic-restapi"
REPOS_BIG="sonic-mgmt-framework sonic-redfish sonic-buildimage sonic-frr"

if [ $# -gt 0 ]; then
  REPOS="$*"
else
  REPOS="$REPOS_DPKGBUILD $REPOS_PYTEST $REPOS_CPP $REPOS_GO"
fi

for r in $REPOS; do
  [ -d "$WIN_WS/$r" ] || die "$WIN_WS/$r not found (Windows working copy missing?)"
  log "rsync $r"
  mkdir -p "$SONIC_WS"
  # Container builds (sairedis compose runs as root) leave root-owned autotools/
  # debhelper residue that rsync --delete cannot unlink; hand the tree back first.
  if [ -d "$SONIC_WS/$r" ]; then
    sudo -n chown -R "$(id -u):$(id -g)" "$SONIC_WS/$r" 2>/dev/null || true
  fi
  rsync -a --delete --exclude '.artifactignore' "$WIN_WS/$r/" "$SONIC_WS/$r/" \
    || die "rsync $r failed (exit $?)"
done

log "ensuring SAI submodule (needed at build time; never initialized on Windows copies)"
(cd "$SONIC_WS/sonic-sairedis" && with_proxy git submodule update --init SAI >/dev/null 2>&1 || \
  with_proxy git submodule update --init SAI)

for r in $REPOS; do
  normalize_repo "$SONIC_WS/$r"
done
normalize_repo "$SONIC_WS/sonic-sairedis/SAI"
apply_install_shim
ensure_git_trust

for r in $REPOS; do
  (cd "$SONIC_WS/$r" && echo "$r: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)")
done
log "sync+normalize done"
