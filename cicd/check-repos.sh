#!/bin/bash
# Sanity: verify each WSL repo tree is a valid git work tree with a HEAD.
. "$(dirname "$0")/lib.sh"
fail=0
for r in sonic-sairedis sonic-swss sonic-swss-common sonic-utilities sonic-snmpagent \
         sonic-host-services sonic-dbsyncd sonic-platform-common sonic-platform-daemons \
         sonic-linkmgrd sonic-dhcp-relay sonic-dhcpmon sonic-mgmt-common sonic-gnmi \
         sonic-buildimage; do
  d="$SONIC_WS/$r"
  if [ ! -e "$d/.git" ]; then
    printf '%-26s NO .git\n' "$r"; fail=1
  elif ! head=$(git -C "$d" rev-parse --short HEAD 2>/dev/null); then
    printf '%-26s BROKEN GIT: %s\n' "$r" "$(git -C "$d" rev-parse --is-inside-work-tree 2>&1 | head -1)"; fail=1
  else
    printf '%-26s ok @ %s\n' "$r" "$head"
  fi
done
[ "$fail" = 0 ] && echo "ALL-OK"
