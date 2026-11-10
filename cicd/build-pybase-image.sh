#!/bin/bash
# Build sonic-ci-py3:base — the shared dependency image for SONiC python-repo
# unit tests (sonic-utilities / snmpagent / host-services / dbsyncd /
# platform-common / platform-daemons). Contents mirror each repo's
# azure-pipelines.yml dependency steps (see Dockerfile.pybase).
# Requires: stage-upstream.sh has fetched common-libs, sonic-swss-common,
# sonic-dash-api and sonic-buildimage-vs. ~10 min (mostly dotnet apt).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

for b in common-libs sonic-swss-common sonic-dash-api; do
  [ -d "$STAGED_DIR/$b" ] || die "~/staged/$b missing - run stage-upstream.sh first"
done
[ -n "$(ls "$STAGED_DIR"/sonic-wheels-local/*.whl 2>/dev/null)" ] \
  || die "~/staged/sonic-wheels-local empty - run scripts/build-sonic-wheels.sh first (the 48GB vs artifact is NOT downloadable; see pitfalls.md #16)"
ensure_slave_tags

CTX="$HOME/pybase-ctx"
rm -rf "$CTX" && mkdir -p "$CTX/debs" "$CTX/wheels"

# debs: exactly what the repo CIs dpkg -i (bookworm flavor)
cp "$STAGED_DIR"/common-libs/target/debs/bookworm/libnl-3-200_*.deb       "$CTX/debs/"
cp "$STAGED_DIR"/common-libs/target/debs/bookworm/libnl-genl-3-200_*.deb  "$CTX/debs/"
cp "$STAGED_DIR"/common-libs/target/debs/bookworm/libnl-route-3-200_*.deb "$CTX/debs/"
cp "$STAGED_DIR"/common-libs/target/debs/bookworm/libnl-nf-3-200_*.deb    "$CTX/debs/"
cp "$STAGED_DIR"/common-libs/target/debs/bookworm/libyang3_*.deb          "$CTX/debs/"
cp "$STAGED_DIR"/common-libs/target/debs/bookworm/libyang-dev_3*.deb      "$CTX/debs/" 2>/dev/null || true
cp "$STAGED_DIR"/common-libs/target/debs/bookworm/python3-libyang_*.deb   "$CTX/debs/"
cp "$STAGED_DIR"/sonic-swss-common/libswsscommon_1.0.0_amd64.deb          "$CTX/debs/"
cp "$STAGED_DIR"/sonic-swss-common/libswsscommon-dev_1.0.0_amd64.deb      "$CTX/debs/"
cp "$STAGED_DIR"/sonic-swss-common/python3-swsscommon_1.0.0_amd64.deb    "$CTX/debs/"
cp "$STAGED_DIR"/sonic-dash-api/libdashapi_*.deb                          "$CTX/debs/" 2>/dev/null || true

# wheels: the SONiC stack wheels, BUILT LOCALLY by build-sonic-wheels.sh
W="$STAGED_DIR/sonic-wheels-local"
for w in 'swsssdk-' 'sonic_py_common-' 'sonic_yang_mgmt-' 'sonic_yang_models-' \
         'sonic_config_engine-' 'sonic_platform_common-' 'sonic_utilities-'; do
  ls "$W"/${w}*.whl >/dev/null 2>&1 || die "wheel ${w}*.whl missing in $W"
  cp "$W"/${w}*.whl "$CTX/wheels/"
done

cp "$(dirname "$0")/Dockerfile.pybase" "$CTX/Dockerfile"
cd "$CTX"
log "docker build sonic-ci-py3:base ($(ls debs | wc -l) debs, $(ls wheels | wc -l) wheels)"
with_proxy docker build \
  --build-arg http_proxy="$PROXY" --build-arg https_proxy="$PROXY" \
  -t sonic-ci-py3:base . | tail -5
log "image built: sonic-ci-py3:base (tests: scripts/test-pyrepo.sh <repo>)"
