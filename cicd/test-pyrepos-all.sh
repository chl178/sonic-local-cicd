#!/bin/bash
# Run test-pyrepo.sh over the quick python repos (driver so wsl.exe never sees
# shell variables). platform-daemons included; utilities excluded (long).
S="$(cd "$(dirname "$0")" && pwd)"
FAIL=0
for r in sonic-snmpagent sonic-dbsyncd sonic-platform-common sonic-host-services sonic-platform-daemons; do
  echo "########## $r"
  if bash "$S/test-pyrepo.sh" "$r"; then
    echo "########## $r OK"
  else
    echo "########## $r FAILED"
    FAIL=1
  fi
done
exit $FAIL
