#!/bin/bash
# Run sonic-sairedis unit tests, CI-identical sequence:
# redis up -> setcap syncd_tests & unittest tests -> make check.
# Optional env: TARGET=<make target or dir> for a focused subset during TDD,
#   e.g. TARGET="check-am" or cd into unittest/syncd.
# Full run ~20-30 min. Exit code = make's.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ensure_git_trust
cd "$SONIC_WS/sonic-sairedis/build-env"
export DEBIAN_VERSION=bookworm

log "make check via compose shell service (redis started inside)"
docker compose run --rm -e GIT_CONFIG_GLOBAL=/workspace/.gitconfig-container \
  shell bash -c '
    cd /workspace
    (service redis-server start || redis-server --daemonize yes) >/dev/null 2>&1; sleep 1
    redis-cli ping || { echo "redis not running — tests will fail"; exit 2; }
    setcap cap_sys_time=eip syncd/.libs/syncd_tests 2>/dev/null || true
    setcap cap_dac_override,cap_ipc_lock,cap_ipc_owner,cap_sys_time=eip \
      unittest/syncd/.libs/tests 2>/dev/null || true
    make '"${TARGET:-check}"'
  '
rc=$?
log "make ${TARGET:-check} exit=$rc"
exit $rc
