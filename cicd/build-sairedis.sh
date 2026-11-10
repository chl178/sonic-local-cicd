#!/bin/bash
# Build sonic-sairedis packages (CI-identical: compose build service runs the
# same build-env/build.sh as Azure Pipelines). Produces 13 .deb incl. syncd-vs.
# First run ~15-20 min (image + full compile); incremental reruns ~3-10 min.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ensure_slave_tags
ensure_git_trust
apply_install_shim

cd "$SONIC_WS/sonic-sairedis/build-env"
export DEBIAN_VERSION=bookworm BUILD_BRANCH=master
log "compose run build (GIT_CONFIG_GLOBAL injected)"
if docker compose run --rm -e GIT_CONFIG_GLOBAL=/workspace/.gitconfig-container build; then
  log "OK: $(ls "$SONIC_WS/sonic-sairedis"/*.deb | wc -l) debs in $SONIC_WS/sonic-sairedis/"
  ls -la "$SONIC_WS/sonic-sairedis"/*.deb | awk '{print $NF, $5}'
else
  die "build failed — see ~/SONiC hints: rerun with output visible, and check references/pitfalls.md in the skill"
fi
