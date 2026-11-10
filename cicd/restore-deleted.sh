#!/bin/bash
# Restore git-deleted files in a repo tree — handles both staged ('D ') and
# worktree-only (' D') deletions. The known case: sonic-gnmi's Windows copy
# has 69 testdata/COUNTERS* files staged-deleted (carried into WSL by rsync).
# NOTE: several filenames contain colons — pass them via xargs -0 from a
# NUL-joined list; wsl.exe inline quoting cannot express them (pitfalls #11).
# Usage: restore-deleted.sh <repo>
. "$(dirname "$0")/lib.sh"
r="${1:-sonic-gnmi}"
cd "$SONIC_WS/$r" || die "no such repo $r"

# porcelain: XY<space>path — path starts at column 4 for BOTH deletion kinds
mapfile -t dels < <(git status --porcelain | awk '/^D|^ D/ {print substr($0, 4)}')
[ "${#dels[@]}" -eq 0 ] && { echo "nothing deleted"; exit 0; }
printf 'restoring %s deleted files\n' "${#dels[@]}"
printf '%s\n' "${dels[@]}" | tr '\n' '\0' | xargs -0 git checkout HEAD --
git status --porcelain | grep -c "^.D\|^D" || true
echo "deletions remaining: $(git status --porcelain | awk '/^D|^ D/' | wc -l)"
