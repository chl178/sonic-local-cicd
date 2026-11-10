#!/bin/bash
# VS end-to-end verification (workflow D): deploy locally built SONiC
# components into the running SONiC VS virtual machine, run a health smoke,
# and write an English markdown report meant to be pasted into PR comments.
#
# Two-layer model: TDD red/green loops stay on component tests (fast);
# this script is the pre-PR system-level gate (deploy + restart + smoke
# takes ~5-10 min under QEMU TCG).
#
# Usage: vs-verify.sh <repo> [--report <path>] [--note "..."]
# Repos: sonic-swss | sonic-sairedis | sonic-utilities
# Prereq: run the matching build script first (artifacts listed per repo
# below); the VS VM is auto-started if down (~/SONiC/vs/run-vs.sh).
. "$(dirname "$0")/lib.sh"

VS_DIR="${VS_DIR:-$SONIC_WS/vs}"
SSH_PORT="${SSH_PORT:-10022}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20"
VS_SSH_PASS="${VS_SSH_PASS:-YourPaSsWoRd}"
REPORT="$VS_DIR/last-vs-report.md"
NOTE=""
REPO=""

vssh() { sshpass -p "$VS_SSH_PASS" ssh $SSH_OPTS -p "$SSH_PORT" admin@127.0.0.1 "$@"; }
vscp()  { sshpass -p "$VS_SSH_PASS" scp $SSH_OPTS -P "$SSH_PORT" "$@"; }

# ---------------------------------------------------------------- repo map
# Each entry: artifacts (WSL paths), deploy kind, target, the process that
# must be RUNNING after restart, the build script to hint when artifacts are
# missing, and EXTRA_LIBS — shared objects to bundle from the local build
# container because local builds are bookworm-based while the VS nightly
# image is trixie-based (e.g. swss links libhiredis.so.0.14, trixie only
# ships so.1). dpkg -i runs with --force-depends for the same reason: the
# dependency PACKAGE names differ across the distro versions although the
# real ABI is satisfied (bundled so + newer-everything-else).
# Extend this table to cover more repos.
resolve_repo() {
  local ws_swss="$SONIC_WS/sonic-swss" ws_sairedis="$SONIC_WS/sonic-sairedis"
  local staged_sai="$STAGED_DIR/sonic-sairedis" staged_swc="$STAGED_DIR/sonic-swss-common"
  BUILD_CTR="swss-build"   # persistent bookworm container carrying the local libs
  EXTRA_LIBS=""
  EXTRA_DEBS=""            # co-deployed ABI-matching libs (see below)
  case "$REPO" in
    sonic-swss)
      ARTIFACTS=$(ls "$ws_swss"/swss_*.deb 2>/dev/null | grep -v -- '-dbg' || true)
      KIND=container; CONTAINER=swss; KEYPROC=orchagent
      EXTRA_LIBS="libhiredis.so.0.14"
      # The swss binaries were compiled against the STAGED libswsscommon /
      # sairedis headers inside the build container; the nightly VS image
      # carries different builds of those libs and every daemon segfaults
      # (NULL deref in libc, see pitfalls #27). Co-deploy the exact staged
      # libs so binary and library ABIs match — INCLUDING python3-swsscommon:
      # orchagent.sh -> sonic-cfggen uses the python binding, which must come
      # from the same build as the C++ lib or ConfigDB connect() throws
      # UnicodeDecodeError.
      EXTRA_DEBS="$staged_swc/libswsscommon_1.0.0_amd64.deb $staged_swc/python3-swsscommon_1.0.0_amd64.deb"
      for p in libsairedis libsaivs libsaimetadata; do
        EXTRA_DEBS="$EXTRA_DEBS $staged_sai/${p}_1.0.0_amd64.deb"
      done
      GITDIR="$ws_swss"
      BUILD_HINT="build-swss.sh"
      ;;
    sonic-sairedis)
      # Local builds already use the VS profile (-Psyncd,vs,nopython2), so the
      # runtime set is syncd-vs + the sai libs; dev/dbg packages stay out.
      ARTIFACTS=$(cd "$ws_sairedis" 2>/dev/null && ls syncd-vs_*.deb libsairedis_*.deb \
                     libsaivs_*.deb libsaimetadata_*.deb 2>/dev/null \
                   | grep -vE -- '-(dev|dbg|dbgsym)_' \
                   | sed "s|^|$ws_sairedis/|" || true)
      KIND=container; CONTAINER=syncd; KEYPROC=syncd
      EXTRA_LIBS="libhiredis.so.0.14"
      EXTRA_DEBS="$staged_swc/libswsscommon_1.0.0_amd64.deb $staged_swc/python3-swsscommon_1.0.0_amd64.deb"
      GITDIR="$ws_sairedis"
      BUILD_HINT="build-sairedis.sh"
      ;;
    sonic-utilities)
      ARTIFACTS=$(ls "$STAGED_DIR"/sonic-wheels-local/sonic_utilities-*.whl 2>/dev/null || true)
      KIND=host; CONTAINER=""; KEYPROC=""
      GITDIR="$SONIC_WS/sonic-utilities"
      BUILD_HINT="build-sonic-wheels.sh"
      ;;
    *) die "unknown repo '$REPO' (supported: sonic-swss sonic-sairedis sonic-utilities)" ;;
  esac
}

# ---------------------------------------------------------------- helpers
ensure_vm() {
  local pidfile="$VS_DIR/qemu.pid" pid
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "VS VM already running (pid $pid)"
  else
    log "VS VM down -> starting"
    "$VS_DIR/run-vs.sh" start >/dev/null
  fi
  "$VS_DIR/run-vs.sh" wait-ssh
}

wait_container_healthy() {  # wait_container_healthy <container> <keyproc> <timeout_s>
  local c="$1" proc="$2" timeout="${3:-600}" i=0
  while :; do
    if vssh "docker ps --filter name=^$c\$ --format '{{.Status}}' 2>/dev/null" | grep -q ^Up; then
      if vssh "docker exec $c supervisorctl status $proc 2>/dev/null" | grep -q RUNNING; then
        log "container $c Up, $proc RUNNING (after ${i}0s)"
        return 0
      fi
    fi
    i=$((i+1)); [ $((i*10)) -ge "$timeout" ] && return 1
    sleep 10
  done
}

md5_audit() {  # md5_audit <deb> <container> — compare a key binary deb vs container
  local deb="$1" c="$2" tmp keybin local_md5 vm_md5
  # First regular FILE under ./usr/bin (dpkg-deb -c also lists directories
  # like ./usr/bin/ itself, whose md5 would always "mismatch" meaninglessly).
  keybin=$(dpkg-deb -c "$deb" 2>/dev/null | awk '$1 ~ /^-/ && $NF ~ /^\.\/usr\/bin\/[^\/]+$/ {print $NF; exit}' | sed 's|^\.||')
  [ -n "$keybin" ] || { echo "no /usr/bin payload found"; return 0; }
  tmp=$(mktemp -d)
  dpkg-deb -x "$deb" "$tmp" 2>/dev/null
  local_md5=$(md5sum "$tmp$keybin" 2>/dev/null | awk '{print $1}')
  rm -rf "$tmp"
  vm_md5=$(vssh "docker exec $c md5sum '$keybin' 2>/dev/null" | awk '{print $1}')
  if [ -n "$local_md5" ] && [ "$local_md5" = "$vm_md5" ]; then
    echo "md5 OK: $keybin ($local_md5)"
  else
    echo "MD5 MISMATCH: $keybin deb=$local_md5 container=$vm_md5"
  fi
}

wait_all_healthy() {  # every container Up — target restart cascades (syncd, bgp...)
  local timeout=300 i=0 total up
  while :; do
    # denominator must count ALL containers (docker ps -a): plain `docker ps`
    # only lists running ones and makes the check vacuously true.
    total=$(vssh "docker ps -a -q | wc -l")
    up=$(vssh "docker ps --filter status=running -q | wc -l")
    [ "$total" = "$up" ] && [ "$total" -gt 0 ] && { log "all $up containers Up"; return 0; }
    i=$((i+1)); [ $((i*10)) -ge "$timeout" ] && { log "WARN: $up/$total containers Up after ${timeout}s"; return 1; }
    sleep 10
  done
}

# ---------------------------------------------------------------- main
REPO="${1:-}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --report) REPORT="$2"; shift 2 ;;
    --note)   NOTE="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
[ -n "$REPO" ] || die "usage: vs-verify.sh <repo> [--report <path>] [--note ...]"

resolve_repo
[ -n "$ARTIFACTS" ] || die "no build artifacts for $REPO (run $BUILD_HINT first)"
for a in $ARTIFACTS; do [ -f "$a" ] || die "artifact missing: $a"; done
log "artifacts: $(echo "$ARTIFACTS" | xargs -n1 basename | tr '\n' ' ')"

GIT_DESC=$(git -C "$GITDIR" describe --always --dirty 2>/dev/null || echo "unknown")
rm -f /tmp/vs-fail          # failure markers accumulate from here on
ensure_vm

VS_IMAGE=$(vssh "show version 2>/dev/null | grep 'SONiC Software Version'" | sed 's/^.*: //')
log "VS image: $VS_IMAGE"

# --- deploy ---
# NOTE: never pipe vssh/vscp through tail/head when checking their exit
# status — the pipeline's status is the LAST command's, hiding deploy
# failures (a silent dpkg failure once survived an entire run this way).
DEPLOY_LOG=""
if [ "$KIND" = container ]; then
  vssh "mkdir -p /tmp/vs-verify && rm -f /tmp/vs-verify/*"
  SCP_SET="$ARTIFACTS"
  for d in $EXTRA_DEBS; do [ -f "$d" ] && SCP_SET="$SCP_SET $d"; done
  vscp $SCP_SET admin@127.0.0.1:/tmp/vs-verify/ || die "scp of artifacts failed"
  vssh "ls /tmp/vs-verify/ | grep -q . " || die "artifacts not visible on VS host"
  if [ -n "$EXTRA_LIBS" ]; then
    rm -rf "$VS_DIR/payload" && mkdir -p "$VS_DIR/payload"
    for so in $EXTRA_LIBS; do
      docker cp "$BUILD_CTR:/usr/lib/x86_64-linux-gnu/$so" "$VS_DIR/payload/" 2>/dev/null \
        || die "cannot extract $so from build container $BUILD_CTR"
    done
    vscp "$VS_DIR"/payload/* admin@127.0.0.1:/tmp/vs-verify/ || die "scp of bundled libs failed"
  fi
  # In-container staging path must NOT be /tmp: SONiC containers mount /tmp as
  # tmpfs, and docker cp writes the overlay layer underneath — files silently
  # invisible to the running container. / (overlay writable layer) is safe.
  vssh "docker exec $CONTAINER rm -rf /vs-verify" 2>/dev/null
  vssh "docker cp /tmp/vs-verify $CONTAINER:/" || die "docker cp into $CONTAINER failed"
  # the target container may be down (e.g. crash-looped from a previous bad
  # deploy, or still starting after VM boot) — dpkg needs it running
  vssh "docker start $CONTAINER" >/dev/null 2>&1 || true
  vssh "docker exec $CONTAINER ls /vs-verify/ | grep -q ." || die "artifacts not visible inside $CONTAINER"
  if ! DEPLOY_LOG=$(vssh "docker exec $CONTAINER sh -c \
      'for f in /vs-verify/*.so.*; do [ -f \"\$f\" ] && mv \"\$f\" /usr/lib/x86_64-linux-gnu/; done; ldconfig; dpkg -i --force-depends /vs-verify/*.deb' 2>&1"); then
    die "dpkg -i in $CONTAINER failed: $(echo "$DEPLOY_LOG" | tail -5)"
  fi
  log "dpkg -i done in $CONTAINER"
  RESTART_START=$(date +%s)
  vssh "docker restart $CONTAINER" >/dev/null || die "docker restart $CONTAINER failed"
  log "restarted $CONTAINER, waiting for health (TCG is slow, up to 10 min)"
  wait_container_healthy "$CONTAINER" "$KEYPROC" 600 \
    || { echo "FAIL: container $CONTAINER did not come healthy with $KEYPROC RUNNING" >> /tmp/vs-fail; }
  wait_all_healthy || echo "not all containers Up (see status above)" >> /tmp/vs-fail
  RESTART_SECS=$(( $(date +%s) - RESTART_START ))
else  # host (python wheel)
  vssh "mkdir -p /tmp/vs-verify && rm -f /tmp/vs-verify/*"
  vscp $ARTIFACTS admin@127.0.0.1:/tmp/vs-verify/ || die "scp of wheel failed"
  if ! DEPLOY_LOG=$(vssh "sudo pip3 install --force-reinstall --no-deps /tmp/vs-verify/*.whl" 2>&1); then
    die "pip3 install on VS host failed: $(echo "$DEPLOY_LOG" | tail -3)"
  fi
  RESTART_SECS=0
  log "wheel installed on VS host"
fi

# --- smoke ---
HEALTH=$(vssh "docker ps --format '{{.Names}} {{.Status}}'")
TOTAL=$(echo "$HEALTH" | wc -l); UP=$(echo "$HEALTH" | grep -c " Up ")
NOTUP=$(echo "$HEALTH" | grep -v " Up " | awk '{print $1}' | tr '\n' ' ')
[ "$TOTAL" = "$UP" ] || echo "containers not Up: $NOTUP" >> /tmp/vs-fail

PROCS=""; MD5=""; DB=""; CLI=""
if [ "$KIND" = container ]; then
  PROCS=$(vssh "docker exec $CONTAINER supervisorctl status" | awk '{printf "%s=%s ", $1, $2}')
  echo "$PROCS" | grep -q "$KEYPROC=RUNNING" || echo "$KEYPROC not RUNNING" >> /tmp/vs-fail
  for a in $ARTIFACTS; do
    MD5="$MD5$(basename "$a"): $(md5_audit "$a" "$CONTAINER")
"
  done
  echo "$MD5" | grep -q MISMATCH && echo "binary md5 mismatch" >> /tmp/vs-fail
fi
# sonic-db-cli is present on modern SONiC hosts (verified on master nightly)
# and talks to each DB by name over its socket; NOK marks a failed DB.
DB=$(vssh 'for db in APPL_DB CONFIG_DB STATE_DB; do sonic-db-cli $db PING 2>/dev/null || echo NOK_$db; done' | tr '\n' ' ')
echo "$DB" | grep -q NOK && echo "redis PING failed: $DB" >> /tmp/vs-fail
CLI=$(vssh "show version >/dev/null 2>&1 && show vlan brief >/dev/null 2>&1 && echo OK" || echo FAILED)
[ "$CLI" = OK ] || echo "CLI smoke failed" >> /tmp/vs-fail
LOGSCAN=""
if [ "$KIND" = container ]; then
  LOGSCAN=$(vssh "docker logs --tail 300 $CONTAINER 2>&1 | grep -icE 'segfault|fatal|crash|aborted|panic'" || true)
fi

# --- report (English, for PR comments) ---
{
  echo "## VS (virtual switch) end-to-end validation"
  echo
  echo "- **VS image**: $VS_IMAGE (QEMU TCG on WSL2)"
  echo "- **Source**: \`$REPO\` @ \`$GIT_DESC\` (locally built)"
  echo "- **Deployed**: $(echo "$ARTIFACTS" | xargs -n1 basename | tr '\n' ' ')"
  if [ "$KIND" = container ]; then
    echo "  into \`$CONTAINER\` container (docker cp + dpkg -i --force-depends + docker restart, back in ${RESTART_SECS}s)"
    [ -n "$EXTRA_DEBS" ] && echo "  co-deployed ABI-matching libs: $(echo "$EXTRA_DEBS" | xargs -n1 basename | tr '\n' ' ')"
    [ -n "$EXTRA_LIBS" ] && echo "  bundled so: $EXTRA_LIBS (local build is bookworm, VS image is trixie)"
  else
    echo "  on VS host (pip3 install --force-reinstall --no-deps)"
  fi
  echo
  echo "| Check | Result |"
  echo "|---|---|"
  echo "| Container health | $UP/$TOTAL Up$( [ -n "$NOTUP" ] && echo " — NOT Up: $NOTUP" ) |"
  [ -n "$PROCS" ] && echo "| Target processes | $PROCS|"
  if [ -n "$MD5" ]; then
    echo "| Binary audit | $(echo "$MD5" | tr '\n' ';' ) |"
  fi
  echo "| Redis (sonic-db-cli PING) | $DB|"
  echo "| CLI smoke (show version/vlan) | $CLI |"
  [ -n "$LOGSCAN" ] && echo "| Log scan ($CONTAINER, post-restart tail) | $LOGSCAN fatal/crash/segv lines |"
  echo
  if [ -n "$NOTE" ]; then
    echo "### Behavioral verification (targeted)"
    echo
    echo "$NOTE"
    echo
  fi
  if [ -f /tmp/vs-fail ]; then
    echo "**RESULT: FAIL**"
    sed 's/^/- /' /tmp/vs-fail
    exit 3
  else
    echo "**RESULT: PASS**"
  fi
} | tee "$REPORT"
RC=${PIPESTATUS[0]}
log "report written to $REPORT"
exit "$RC"
