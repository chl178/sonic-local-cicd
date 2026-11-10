#!/bin/bash
# Build the local swss build image (swss-bookworm-master:latest) hermetically:
# upstream DEBs come from ~/staged (run stage-upstream.sh first), so the image
# build performs ZERO Azure CDN downloads. ~5-8 min.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -d "$STAGED_DIR/sonic-sairedis" ] || die "run stage-upstream.sh first"
ensure_slave_tags

CTX="$HOME/swss-ctx"
rm -rf "$CTX" && mkdir -p "$CTX"
cp -r "$SONIC_WS/sonic-swss/build-env/packages" "$CTX/packages"
cp "$SONIC_WS/sonic-swss/build-env/upstream-artifacts.yaml" "$CTX/"
[ -f "$SONIC_WS/sonic-swss/build-env/custom-setup.sh" ] || \
  { echo '#!/bin/bash' > "$CTX/custom-setup.sh"; echo '# custom setup stub' >> "$CTX/custom-setup.sh"; }
cp "$SONIC_WS/sonic-swss/build-env/custom-setup.sh" "$CTX/"
cp -r "$STAGED_DIR" "$CTX/staged"
cp "$(dirname "$0")/Dockerfile.swss-local" "$CTX/Dockerfile"

cd "$CTX"
log "docker build (staged upstreams, proxy for github clone)"
with_proxy docker build \
  --build-arg USER=liu --build-arg UID=1000 --build-arg GID=1000 \
  --build-arg HOME=/home/liu --build-arg DEBIAN=bookworm --build-arg BRANCH=master \
  -t swss-bookworm-master:latest . | tail -5
log "image built: swss-bookworm-master:latest"
