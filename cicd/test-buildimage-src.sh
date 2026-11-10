#!/bin/bash
# Unit tests for the python components checked in INSIDE sonic-buildimage
# (upstream exercises them during image builds; locally we run each repo's
# pytest suite directly in a fresh sonic-ci-py3:base container).
# Usage: test-buildimage-src.sh [subrepo ...]   (default: all five)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ALL="sonic-config-engine sonic-yang-mgmt sonic-yang-models sonic-py-common sonic-bgpcfgd"
SUBS="${*:-$ALL}"
docker image inspect sonic-ci-py3:base >/dev/null 2>&1 \
  || die "image sonic-ci-py3:base missing - run scripts/build-pybase-image.sh first"
[ -d "$SONIC_WS/sonic-buildimage/src" ] || die "run sync-from-windows.sh sonic-buildimage first"

FAIL=0
for s in $SUBS; do
  d="$SONIC_WS/sonic-buildimage/src/$s"
  [ -d "$d" ] || { log "skip $s (not present)"; continue; }
  # config-engine's tests run sonic-cfggen with CFGGEN_UNIT_TESTING=2, which
  # walks /sonic/device AND copies MMU profile files INTO it (select_mmu_profiles
  # does sudo cp) — mount read-write (git checkout restores any copies).
  EXTRA_V=""
  [ "$s" = "sonic-config-engine" ] && EXTRA_V="-v $SONIC_WS/sonic-buildimage/device:/sonic/device"
  log "$s: pip install + pytest (fresh container)"
  # these are source packages, NOT wheels: install with deps so their own
  # install_requires resolve; the preinstalled SONiC wheels satisfy the SONiC
  # ones (pip sees them satisfied, same as upstream CI).
  # pip needs the proxy; the TESTS must not see it (grpc clients would try to
  # route local test-server connections through Clash and fail with
  # "failed to connect to all addresses")
  if docker run --rm $EXTRA_V \
      -v /home/liu:/home/liu -v sonic-pip-cache:/root/.cache/pip \
      -e http_proxy="$PROXY" -e https_proxy="$PROXY" \
      -w "/home/liu/SONiC/sonic-buildimage/src/$s" sonic-ci-py3:base \
      bash -c "pip3 install -q -e '.[testing]' 2>/dev/null || pip3 install -q -e .; \
               env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
                 pytest ${FILTER:+-k $FILTER}"; then
    log "$s: OK"
  else
    log "$s: FAILED"
    FAIL=1
  fi
done
[ "$FAIL" = 0 ] || die "one or more buildimage src repos failed"
log "OK: buildimage src suites green"
