#!/bin/bash
# CI-equivalent unit tests for the SONiC python repos, each in a FRESH
# container from sonic-ci-py3:base (same isolation as upstream's one-container-
# per-job model). Usage:
#   test-pyrepo.sh <sonic-utilities|sonic-snmpagent|sonic-host-services|
#                   sonic-dbsyncd|sonic-platform-common|sonic-platform-daemons>
# Optional env:
#   FILTER=...   pass -k <FILTER> to pytest (focused TDD loop)
#   KEEP=1       keep the container after the run (debugging)
# The upstream CI sequence per repo is replicated exactly; see case below.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

REPO="${1:-}"
FILTER="${FILTER:-}"
case "$REPO" in
  sonic-utilities|sonic-snmpagent|sonic-host-services|sonic-dbsyncd|\
  sonic-platform-common|sonic-platform-daemons) ;;
  *) die "usage: $0 <sonic-utilities|sonic-snmpagent|sonic-host-services|sonic-dbsyncd|sonic-platform-common|sonic-platform-daemons>" ;;
esac

docker image inspect sonic-ci-py3:base >/dev/null 2>&1 \
  || die "image sonic-ci-py3:base missing - run scripts/build-pybase-image.sh first"
[ -d "$SONIC_WS/$REPO" ] || die "$SONIC_WS/$REPO missing - run sync-from-windows.sh $REPO"

KARGS=""
[ "${KEEP:-0}" = "1" ] && KARGS="--name py-ci-debug"
PYTEST_ARGS=""
[ -n "$FILTER" ] && PYTEST_ARGS="-k $FILTER"

# platform-daemons is a monorepo: pytest per sub-project (upstream matrix)
if [ "$REPO" = "sonic-platform-daemons" ]; then
  PROJECTS="sonic-chassisd sonic-ledd sonic-pcied sonic-psud sonic-syseepromd \
            sonic-thermalctld sonic-xcvrd sonic-ycabled sonic-sensormond \
            sonic-stormond sonic-bmcctld"
  FAIL=0
  for p in $PROJECTS; do
    log "platform-daemons/$p: pip install + pytest"
    docker run --rm $KARGS \
      -v /home/liu:/home/liu -v sonic-pip-cache:/root/.cache/pip \
      -e http_proxy="$PROXY" -e https_proxy="$PROXY" \
      -w "/home/liu/SONiC/$REPO/$p" sonic-ci-py3:base \
      bash -c "pip3 install -q '.[testing]' && pytest $PYTEST_ARGS" \
      || { FAIL=1; log "FAILED: $p (rerun single: test-pyrepo.sh + KEEP=1, see above cmd)"; }
  done
  [ "$FAIL" = 0 ] && log "OK: all platform-daemons suites green" || die "platform-daemons had failures"
  exit 0
fi

# single-project repos
case "$REPO" in
  sonic-utilities)
    CMD="pip3 install '.[testing]' && pip3 uninstall --yes sonic-utilities && pytest $PYTEST_ARGS" ;;
  sonic-snmpagent)
    CMD="pip3 install '.[testing]' && pip3 uninstall --yes asyncsnmp && python -m pytest $PYTEST_ARGS" ;;
  sonic-host-services)
    CMD="pip3 install '.[testing]' && pip3 uninstall --yes sonic-host-services && pytest $PYTEST_ARGS" ;;
  sonic-dbsyncd)
    CMD="python3 setup.py test $PYTEST_ARGS" ;;
  sonic-platform-common)
    CMD="pip3 install '.[testing]' && pytest $PYTEST_ARGS" ;;
esac

log "$REPO: $CMD"
docker run --rm $KARGS \
  -v /home/liu:/home/liu -v sonic-pip-cache:/root/.cache/pip \
  -e http_proxy="$PROXY" -e https_proxy="$PROXY" \
  -w "/home/liu/SONiC/$REPO" sonic-ci-py3:base \
  bash -c "$CMD"
rc=$?
log "$REPO exit=$rc"
exit $rc
