#!/bin/bash
# Download release image bundles and restore them locally: verify sha256,
# reassemble split parts, docker load (or rebuild sonic-vs.img.gz).
#
# Usage: load-images.sh <tag> [bundle ...]
#   tag     release tag, e.g. v2026.11.10
#   bundle  ci-images | vrnetlab-sonic-vs | sonic-vs.img.gz
#           (default: the two docker bundles)
#
# Requires: gh (authenticated), zstd, docker.
# Without gh: download the parts + SHA256SUMS from the release page manually,
# then run:  cat <bundle>.tar.zst.part-* | zstd -d | docker load
set -euo pipefail

TAG="${1:?usage: load-images.sh <tag> [bundle...]}"; shift || true
REPO="${GH_REPO:-chl178/sonic-local-cicd}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gh release download "$TAG" -R "$REPO" --pattern SHA256SUMS --dir "$TMP"

restore() {  # restore <bundle-name>
  local b="$1" prefix
  # release asset names: <bundle>.tar.zst.part-NN (docker) or sonic-vs.img.gz.part-NN
  case "$b" in
    sonic-vs.img.gz) prefix="$b.part-" ;;
    *)               prefix="$b.tar.zst.part-" ;;
  esac

  echo "== [$b] downloading parts"
  gh release download "$TAG" -R "$REPO" --pattern "$prefix*" --dir "$TMP"
  ( cd "$TMP" && grep -F "$prefix" SHA256SUMS | sha256sum -c --ignore-missing )

  if [ "$b" = "sonic-vs.img.gz" ]; then
    cat "$TMP/$prefix"* > "$TMP/$b"
    gzip -t "$TMP/$b"
    mv "$TMP/$b" ./
    echo "restored ./$b — unpack with: gunzip -c $b > sonic-vs.img (QEMU image)"
  else
    cat "$TMP/$prefix"* | zstd -d | docker load
  fi
  rm -f "$TMP/$prefix"*
}

if [ $# -gt 0 ]; then
  for b in "$@"; do restore "$b"; done
else
  restore ci-images
  restore vrnetlab-sonic-vs
fi

echo "== done. Images now:"
docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep -Ei 'swss|sonic-ci|slave-bookworm|vrnetlab' || true
