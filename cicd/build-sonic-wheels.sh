#!/bin/bash
# Build the SONiC python wheels LOCALLY (in the swss-build container) instead of
# downloading the sonic-buildimage.vs artifact — that PipelineArtifact is 48.6GB
# (single zip, CDN rejects Range requests), unusable for 7 wheels worth ~30MB.
#
# Build order matters: setup.py of each package IMPORTS its SONiC deps, so each
# wheel is built and INSTALLED before the next one (same trick buildimage uses).
#   yang-models -> redis-dump-load -> py-common -> py-swsssdk -> yang-mgmt
#   -> config-engine -> platform-common (own repo) -> utilities (own repo)
#
# Output: ~/staged/sonic-wheels-local/*.whl  (pybase image source)
#         ~/staged/sonic-buildimage-vs/target/python-wheels/bookworm/ (compat
#         path consumed by swss-common's buildenv_setup --upstream-staged-dir)
# Requires: sync-from-windows.sh sonic-buildimage + sonic-platform-common +
# sonic-utilities already synced; swss-build container up. ~5 min.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ensure_swss_container
B="$SONIC_WS/sonic-buildimage/src"
for d in "$B/sonic-yang-models" "$B/sonic-py-common" "$B/sonic-yang-mgmt" "$B/sonic-config-engine"; do
  [ -d "$d" ] || die "$d missing - run sync-from-windows.sh sonic-buildimage first"
done
for d in "$SONIC_WS/sonic-platform-common" "$SONIC_WS/sonic-utilities"; do
  [ -d "$d" ] || die "$d missing - run sync-from-windows.sh sonic-platform-common sonic-utilities first"
done

# swsssdk shim + redis-dump-load (uninitialized submodules in the Windows copy; clone once)
if [ ! -f "$SONIC_WS/sonic-py-swsssdk/setup.py" ]; then
  log "cloning sonic-py-swsssdk"
  with_proxy git clone -q --depth 1 https://github.com/sonic-net/sonic-py-swsssdk.git \
    "$SONIC_WS/sonic-py-swsssdk"
fi
if [ ! -f "$SONIC_WS/redis-dump-load/setup.py" ]; then
  log "cloning redis-dump-load (py-common setup-time dependency)"
  with_proxy git clone -q --depth 1 https://github.com/p/redis-dump-load.git \
    "$SONIC_WS/redis-dump-load"
fi

OUT="$STAGED_DIR/sonic-wheels-local"
COMPAT="$STAGED_DIR/sonic-buildimage-vs/target/python-wheels/bookworm"
rm -rf "$OUT" && mkdir -p "$OUT" "$COMPAT"

WHEEL_ENV="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin http_proxy=$PROXY https_proxy=$PROXY"

build_one() {  # build_one <srcdir> — wheel to $OUT (bind-mounted) + install into container
  local src="$1" name
  name=$(basename "$src")
  log "wheel: $name"
  docker exec -u liu swss-build bash -c "
    set -e; cd '$src'
    env $WHEEL_ENV pip3 wheel --no-deps -q -w '$OUT' .
    env $WHEEL_ENV pip3 install -q --no-deps --force-reinstall '$OUT'/*.whl || \
      env $WHEEL_ENV pip3 install -q --no-deps '$OUT'/*.whl"
}

# dependency-ordered build + install
build_one "$B/sonic-yang-models"
build_one "$SONIC_WS/redis-dump-load"
build_one "$B/sonic-py-common"
build_one "$SONIC_WS/sonic-py-swsssdk"
build_one "$B/sonic-yang-mgmt"
build_one "$B/sonic-config-engine"
build_one "$SONIC_WS/sonic-platform-common"
build_one "$SONIC_WS/sonic-utilities"

log "wheels built: $(ls "$OUT" | wc -l)"
ls -la "$OUT"
[ "$(ls "$OUT"/*.whl 2>/dev/null | wc -l)" -ge 8 ] || die "expected >=8 wheels (7 SONiC + redis_dump_load) - inspect output above"
rm -f "$COMPAT"/*.whl
cp "$OUT"/*.whl "$COMPAT/"
log "compat path refreshed: $COMPAT (for swss-common buildenv)"
