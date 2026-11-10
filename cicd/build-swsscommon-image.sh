#!/bin/bash
# Build the local sonic-swss-common build image (swsscommon-bookworm:latest)
# hermetically from ~/staged (run stage-upstream.sh first): zero Azure CDN
# downloads at build time. ~3-5 min.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -d "$STAGED_DIR/common-libs" ] || die "run stage-upstream.sh first"
[ -d "$STAGED_DIR/sonic-buildimage-vs" ] || die "~/staged/sonic-buildimage-vs missing (vs wheels)"
[ -d "$SONIC_WS/sonic-swss-common" ] || die "run sync-from-windows.sh sonic-swss-common first"
ensure_slave_tags

CTX="$HOME/swsscommon-ctx"
rm -rf "$CTX" && mkdir -p "$CTX"
cp -r "$SONIC_WS/sonic-swss-common/ci" "$CTX/ci"
cp -r "$SONIC_WS/sonic-swss-common/build-env" "$CTX/build-env"
mkdir -p "$CTX/staged"
cp -r "$STAGED_DIR/common-libs" "$CTX/staged/common-libs"
cp -r "$STAGED_DIR/sonic-buildimage-vs" "$CTX/staged/sonic-buildimage-vs"
cp "$(dirname "$0")/Dockerfile.swsscommon-local" "$CTX/Dockerfile"

cd "$CTX"
log "docker build swsscommon-bookworm:latest"
with_proxy docker build \
  --build-arg USER=liu --build-arg UID=1000 --build-arg GID=1000 \
  --build-arg HOME=/home/liu --build-arg DEBIAN=bookworm --build-arg BRANCH=master \
  -t swsscommon-bookworm:latest . | tail -5
log "image built: swsscommon-bookworm:latest"
