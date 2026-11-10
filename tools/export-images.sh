#!/bin/bash
# Export the pipeline's docker images into release-ready, split archives.
#
# GitHub Release assets are capped at 2 GiB per file, so each bundle is
# docker-save'd (shared layers are stored ONCE across the images of a
# bundle), zstd-compressed, then split into 1900 MiB parts. Consumers
# reassemble with tools/load-images.sh (cat parts | zstd -d | docker load).
#
# Bundles produced (see README "Prebuilt images"):
#   ci-images.tar.zst.part-*     swss-bookworm-master + swsscommon-bookworm
#                                 + sonic-ci-py3:base + sonic-slave-bookworm
#                                 (slave layers are shared with the other
#                                 three, so tagging it costs ~nothing)
#   vrnetlab-sonic-vs.tar.zst.part-*   vrnetlab SONiC VS container image
#   sonic-vs.img.gz.part-*       official SONiC VS nightly (QEMU), split as-is
#                                 (it is already gzip; do not recompress)
#
# Usage: export-images.sh [out-dir]     (default ~/image-export)
set -euo pipefail

OUT="${1:-$HOME/image-export}"
VS_DIR="${VS_DIR:-$HOME/SONiC/vs}"
PART_SIZE=1900M
SLAVE_IMG="sonicdev-microsoft.azurecr.io:443/sonic-slave-bookworm"

command -v zstd >/dev/null || { echo "zstd not found (apt-get install zstd)"; exit 1; }
mkdir -p "$OUT"

bundle() {  # bundle <name> <image> [<image>...]
  local name="$1"; shift
  echo "== [$name] docker save $*"
  docker save "$@" | zstd -T0 -3 -o "$OUT/$name.tar.zst"
  echo "== [$name] splitting into ${PART_SIZE} parts"
  rm -f "$OUT/$name.tar.zst.part-"*
  split -b "$PART_SIZE" -d "$OUT/$name.tar.zst" "$OUT/$name.tar.zst.part-"
  rm -f "$OUT/$name.tar.zst"
}

bundle ci-images \
  swss-bookworm-master:latest \
  swsscommon-bookworm:latest \
  sonic-ci-py3:base \
  "$SLAVE_IMG:master-amd64"

bundle vrnetlab-sonic-vs \
  vrnetlab/sonic_sonic-vs:master \
  vrnetlab/vr-sonic:master

if [ -f "$VS_DIR/sonic-vs.img.gz" ]; then
  echo "== [sonic-vs.img.gz] splitting official nightly archive"
  rm -f "$OUT/sonic-vs.img.gz.part-"*
  split -b "$PART_SIZE" -d "$VS_DIR/sonic-vs.img.gz" "$OUT/sonic-vs.img.gz.part-"
else
  echo "== sonic-vs.img.gz not found in $VS_DIR, skipping (run vs/download-vs.sh)"
fi

echo "== sha256"
cd "$OUT"
sha256sum *.part-* > SHA256SUMS

echo "== done:"
ls -lah "$OUT"
