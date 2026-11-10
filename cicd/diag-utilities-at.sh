#!/bin/bash
# Diagnostic: run utilities tests at a given upstream commit (fetched into a
# THROWAWAY worktree) to classify failures as upstream-window vs local-env.
# Usage: diag-utilities-at.sh <full-or-unique-sha> [pytest args...]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
SHA="${1:?usage: diag-utilities-at.sh <sha> [pytest args...]}"
shift || true
ARGS="${*:-tests/switchstat_test.py -x -q --no-header --no-cov}"

cd "$SONIC_WS/sonic-utilities"
with_proxy git fetch -q origin master
git worktree prune
rm -rf /tmp/ut-at
git worktree add -f --detach /tmp/ut-at "$SHA" >/dev/null

docker run --rm -v /home/liu:/home/liu -v sonic-pip-cache:/root/.cache/pip \
  -e http_proxy="$PROXY" -e https_proxy="$PROXY" \
  -w /tmp/ut-at sonic-ci-py3:base \
  bash -c "pip3 install -q '.[testing]' 2>/dev/null; pip3 uninstall -q -y sonic-utilities; \
           env -u http_proxy -u https_proxy pytest $ARGS 2>&1 | tail -6"
cd "$SONIC_WS/sonic-utilities" && git worktree remove --force /tmp/ut-at 2>/dev/null || true
