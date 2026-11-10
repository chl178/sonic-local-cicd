#!/bin/bash
# Pre-download all upstream artifact bundles to ~/staged/<name>/ so image builds
# need zero Azure CDN downloads (in-docker python downloads kept timing out).
# Idempotent: skips bundles already staged. Refresh with: rm -rf ~/staged/<name>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ORG="https://dev.azure.com/mssonic"
mkdir -p "$STAGED_DIR"

j() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
get() { command curl -fsS -x "$PROXY" --retry 5 --retry-delay 3 --retry-all-errors -m "${CURL_MAX_TIME:-600}" "$@"; }

fetch_artifact() {  # name pipeline artifact [resultfilter]
  local name="$1" pipeline="$2" artifact="$3" filter="${4:-succeeded}"
  if [ -d "$STAGED_DIR/$name" ] && [ -n "$(ls -A "$STAGED_DIR/$name" 2>/dev/null)" ]; then
    echo "[skip] $name already staged"; return 0
  fi
  echo "[fetch] $name <- $pipeline/$artifact"
  local defid run url tmp inner entries
  if [[ "$pipeline" =~ ^[0-9]+$ ]]; then
    defid="$pipeline"   # numeric pipeline id (e.g. 142 = Azure.sonic-buildimage.official.vs)
  else
    defid=$(get "${ORG}/build/_apis/build/definitions?name=${pipeline}" | j "d['value'][0]['id']")
  fi
  run=$(get "${ORG}/build/_apis/build/builds?definitions=${defid}&branchName=refs/heads/master&resultFilter=${filter}&statusFilter=completed&\$top=3&queryOrder=finishTimeDescending" | j "d['value'][0]['id']")
  echo "  def=$defid latest ok run=$run"
  tmp="$STAGED_DIR/.$name.tmp"; mkdir -p "$tmp"
  url=$(get "${ORG}/build/_apis/build/builds/${run}/artifacts?artifactName=${artifact}" | j "d['resource']['downloadUrl']")
  # -C -: resumable download (big bundles; CDN drops mid-transfer -- pitfalls.md
  # #5/#16). Fallback without -C - if ranges unsupported.
  get -L -C - -o "$tmp/art.zip" "$url" \
    || get -L -o "$tmp/art.zip" "$url" \
    || die "download failed for $name (rerun this script; it resumes)"
  # verify the zip BEFORE destroying anything: a truncated CDN stream exits
  # curl 0 but is NOT a zip (bit us once: 6GB downloaded, silently discarded)
  python3 -c "import zipfile;zipfile.ZipFile('$tmp/art.zip')" \
    || die "art.zip for $name is not a valid zip (kept at $tmp/art.zip for inspection)"
  python3 -c "import zipfile; zipfile.ZipFile('$tmp/art.zip').extractall('$tmp/x')"
  inner="$tmp/x"; entries=$(ls "$inner" | wc -l)
  if [ "$entries" = "1" ] && [ -d "$inner/$(ls "$inner")" ]; then inner="$inner/$(ls "$inner")"; fi
  mkdir -p "$STAGED_DIR/$name"
  mv "$inner"/* "$STAGED_DIR/$name/" 2>/dev/null || true
  rm -rf "$tmp"
  echo "  staged: $(find "$STAGED_DIR/$name" -name '*.deb' | wc -l) debs"
}

fetch_artifact common-libs       Azure.sonic-buildimage.common_libs common-lib                 succeeded
fetch_artifact sonic-swss-common Azure.sonic-swss-common           sonic-swss-common-bookworm  succeeded,partiallySucceeded
fetch_artifact sonic-sairedis    Azure.sonic-sairedis              sonic-sairedis-bookworm     succeeded,partiallySucceeded
fetch_artifact sonic-dash-api    sonic-net.sonic-dash-api          sonic-dash-api              succeeded
fetch_artifact vpp               sonic-net.sonic-platform-vpp      vpp-bookworm                succeeded,partiallySucceeded
# SONiC python wheels: the sonic-buildimage.vs artifact is a single 48.6GB
# PipelineArtifact zip whose CDN rejects Range requests (pitfalls.md #16) —
# NOT downloadable. The wheels are instead BUILT LOCALLY from the buildimage
# in-tree sources + the platform-common/utilities repos:
#   scripts/build-sonic-wheels.sh   (writes ~/staged/sonic-wheels-local/ and
#                                    the sonic-buildimage-vs compat path used
#                                    by swss-common's buildenv_setup)
if ! ls "$STAGED_DIR"/sonic-buildimage-vs/target/python-wheels/bookworm/*.whl >/dev/null 2>&1; then
  echo "[hint] SONiC python wheels not staged yet - run scripts/build-sonic-wheels.sh"
fi

# cascade requirement: sairedis bundle must carry its own build-env/
if [ ! -d "$STAGED_DIR/sonic-sairedis/build-env" ]; then
  cp -r "$SONIC_WS/sonic-sairedis/build-env" "$STAGED_DIR/sonic-sairedis/build-env"
  echo "[ok] copied sairedis build-env/ for cascade"
fi

echo "=== staged ==="
for d in "$STAGED_DIR"/*/; do
  echo "$(basename "$d"): $(find "$d" -name '*.deb' | wc -l) debs, $(find "$d" -name 'upstream-artifacts.yaml' | wc -l) cascade(s)"
done
