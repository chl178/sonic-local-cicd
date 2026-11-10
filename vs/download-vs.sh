#!/usr/bin/env bash
# Fetch the official SONiC VS image (master nightly) into this directory.
#
# Link source (published by the SONiC build system):
#   https://raw.githubusercontent.com/sonic-net/SONiC/sonic_latest_images_links/sonic_image_links.json
#   (referenced by https://sonic-net.github.io/SONiC/sonic_latest_images.html)
# The Azure Artifacts endpoint answers plain GET only (Range requests get
# HTTP 400), so a failed transfer restarts from zero -- retries are generous
# on purpose. sonic-vs.img.gz is ~1.1 GB, the raw image ~4 GB.
set -euo pipefail
cd "$(dirname "$0")"

LINKS_JSON_URL="https://raw.githubusercontent.com/sonic-net/SONiC/sonic_latest_images_links/sonic_image_links.json"
# BuildId snapshot from 2026-11-09, used when the live JSON is unreachable.
FALLBACK_URL="https://artprodcus3.artifacts.visualstudio.com/Af91412a5-a906-4990-9d7c-f697b81fc04d/be1b070f-be15-4154-aade-b1d3bfb17054/_apis/artifact/cGlwZWxpbmVhcnRpZmFjdDovL21zc29uaWMvcHJvamVjdElkL2JlMWIwNzBmLWJlMTUtNDE1NC1hYWRlLWIxZDNiZmIxNzA1NC9idWlsZElkLzEyNjk4OTEvYXJ0aWZhY3ROYW1lL3NvbmljLWJ1aWxkaW1hZ2UudnM1/content?format=file&subpath=/target/sonic-vs.img.gz"

# Direct first; then the two shapes of the Clash proxy on the Windows side
# (docker bridge IP used by sonic-cicd, and the WSL default gateway).
GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
PROXIES=("" "http://172.17.0.1:7890")
[ -n "${GW:-}" ] && PROXIES+=("http://${GW}:7890")

fetch() { # fetch <url> <output-file>
    local url=$1 out=$2 p
    for p in "${PROXIES[@]}"; do
        if [ -n "$p" ]; then
            echo ">> GET $url"
            echo ">> via proxy $p"
            if curl -fSL --retry 8 --retry-all-errors --retry-delay 5 \
                    --connect-timeout 20 --speed-time 60 --speed-limit 10240 \
                    ${p:+-x "$p"} -o "$out" "$url"; then
                return 0
            fi
        else
            echo ">> GET $url (direct)"
            if curl -fSL --retry 8 --retry-all-errors --retry-delay 5 \
                    --connect-timeout 20 --speed-time 60 --speed-limit 10240 \
                    -o "$out" "$url"; then
                return 0
            fi
        fi
        echo ">> attempt failed, trying next transport"
    done
    return 1
}

echo "== resolving latest sonic-vs.img.gz link =="
URL=""
if fetch "$LINKS_JSON_URL" links.json.tmp; then
    # The JSON maps image names to either a plain URL or an object carrying
    # url/build/date metadata -- normalize both to the URL string.
    URL=$(python3 -c '
import json
v = json.load(open("links.json.tmp"))["master"]["sonic-vs.img.gz"]
print(v["url"] if isinstance(v, dict) else v)' || true)
    rm -f links.json.tmp
fi
if [ -z "${URL:-}" ]; then
    echo "!! live link list unavailable, falling back to embedded buildId"
    URL=$FALLBACK_URL
fi
printf '%s\nfetched: %s\n' "$URL" "$(date -Is)" > sonic-vs.img.gz.source

if [ -f sonic-vs.img ] && [ -f sonic-vs.img.gz ]; then
    echo "== sonic-vs.img already present, nothing to do =="
    exit 0
fi

echo "== downloading (no resume support on this endpoint) =="
fetch "$URL" sonic-vs.img.gz.part

echo "== verifying gzip integrity =="
gzip -t sonic-vs.img.gz.part

mv sonic-vs.img.gz.part sonic-vs.img.gz
echo "== unpacking raw image (~4 GB) =="
gunzip -c sonic-vs.img.gz > sonic-vs.img.part
mv sonic-vs.img.part sonic-vs.img

ls -lh sonic-vs.img.gz sonic-vs.img
echo "== done =="
