#!/bin/bash
# Check upstream Azure CI results for a pipeline, optionally filtered to a
# source commit:  check-ci-status.sh [pipeline] [commit-prefix]
P="${1:-Azure.sonic-utilities}"
C="${2:-}"
ORG="https://dev.azure.com/mssonic"
PX="http://172.17.0.1:7890"
DID=$(curl -fsS -x "$PX" "$ORG/build/_apis/build/definitions?name=$P" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["value"][0]["id"])')
curl -fsS -x "$PX" \
  "$ORG/build/_apis/build/builds?definitions=$DID&\$top=60&queryOrder=finishTimeDescending" \
  | python3 -c "
import json,sys
for b in json.load(sys.stdin)['value']:
    sv = b['sourceVersion'][:8]
    if '$C' and not sv.startswith('$C'):
        continue
    print(sv, b['result'], b['finishTime'][:16], b['buildNumber'])"
