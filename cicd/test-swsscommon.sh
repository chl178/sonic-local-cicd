#!/bin/bash
# Full CI unit-test battery for sonic-swss-common, replicating the
# "Run swss common unit tests" step of .azure-pipelines/build-template.yml:
#   dpkg -i libswsscommon/-dev/python3-swsscommon (built by build-swsscommon.sh)
#   cargo test --workspace --all-features   (+ --release)
#   ./build-env/configure-redis-for-tests.sh
#   ./tests/tests                            (gtest binary)
#   redis-cli FLUSHALL; pytest-3
#   make -C goext; make -C goext check
# ~15-25 min total. FILTER=... narrows the cargo phase only.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

docker ps --format '{{.Names}}' | grep -q '^swsscommon-build$' \
  || die "container swsscommon-build not running - run scripts/build-swsscommon.sh first"
cd "$SONIC_WS/sonic-swss-common"
ls libswsscommon_*.deb python3-swsscommon_*.deb >/dev/null 2>&1 \
  || die "no built debs in ~/SONiC/sonic-swss-common - run scripts/build-swsscommon.sh first"

run() { docker exec -u liu -e GIT_CONFIG_GLOBAL="$SONIC_WS/sonic-sairedis/.gitconfig-container" \
        swsscommon-build bash -c "cd /home/liu/SONiC/sonic-swss-common && $*"; }

log "1/6 dpkg -i built debs (sudo inside container)"
docker exec -u liu swsscommon-build bash -c \
  "cd /home/liu/SONiC/sonic-swss-common && sudo dpkg -i libswsscommon_*.deb libswsscommon-dev_*.deb python3-swsscommon_*.deb 2>&1 | tail -2"

log "2/6 cargo test --workspace --all-features (+ release)"
run "cargo test --workspace --all-features ${FILTER:-} 2>&1 | tail -12"
run "cargo test --release --workspace --all-features 2>&1 | tail -8"

log "3/6 configure redis for tests (unix socket)"
run "./build-env/configure-redis-for-tests.sh"

log "4/6 gtest: ./tests/tests"
run "./tests/tests 2>&1 | tail -12"

log "5/6 pytest-3"
run "redis-cli FLUSHALL >/dev/null; pytest-3 2>&1 | tail -12"

log "6/6 goext build + go test"
run "make -C goext 2>&1 | tail -3; make -C goext check 2>&1 | tail -8"

log "OK: swss-common full battery green"
