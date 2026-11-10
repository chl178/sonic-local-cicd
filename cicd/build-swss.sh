#!/bin/bash
# Build sonic-swss packages + run Rust tests (CI-identical build-env/build.sh:
# autogen + dpkg-buildpackage + cargo test). Uses the persistent "swss-build"
# container (sleep infinity; the compose CMD sshd would exit).
# Full run ~25-40 min (compile ~16 jobs + cargo). Produces swss_1.0.0_amd64.deb
# + swss-dbg_1.0.0_amd64.deb in ~/SONiC/sonic-swss/.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ensure_swss_container
start_redis_in_container swss-build

log "running build-env/build.sh as container user liu"
docker exec -u liu swss-build bash -c \
  "cd /home/liu/SONiC/sonic-swss && ./build-env/build.sh" | tail -25
rc=${PIPESTATUS[0]}
if [ "$rc" -eq 0 ]; then
  log "OK: $(ls "$SONIC_WS/sonic-swss"/*.deb | wc -l) debs + cargo test green"
  ls -la "$SONIC_WS/sonic-swss"/*.deb | awk '{print $NF, $5}'
else
  die "build.sh exit=$rc (cargo test failures usually mean redis died - restart with scripts/test-swss.sh)"
fi
