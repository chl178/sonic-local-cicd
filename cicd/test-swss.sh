#!/bin/bash
# Run sonic-swss Rust tests only (fast TDD loop: crates are cached, ~2-4 min).
# Optional env: FILTER passed to cargo test as-is, e.g.
#   FILTER=countersyncd  scripts/test-swss.sh
#   FILTER="actor::swss" scripts/test-swss.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ensure_swss_container
start_redis_in_container swss-build

log "cargo test ${FILTER:-<all>}"
docker exec -u liu swss-build bash -c \
  "cd /home/liu/SONiC/sonic-swss && RUSTFLAGS=-Dwarnings cargo test ${FILTER:-}" | tail -30
rc=${PIPESTATUS[0]}
log "cargo test exit=$rc"
exit $rc
