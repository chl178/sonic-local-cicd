#!/bin/bash
# CI-equivalent build + unit tests for the Go repos, inside the swss-build
# container (toolchain + libswsscommon-dev + libyang3 already there).
#   test-gorepo.sh sonic-mgmt-common : dpkg-buildpackage (INCLUDE_TEST_MODELS=y)
#                                    + cvl/translib test binaries vs live redis
#   test-gorepo.sh sonic-gnmi        : build mgmt-common (NO_TEST_BINS) if needed,
#                                    make all + make check_gotest
#   test-gorepo.sh sonic-restapi     : build + go unit tests (integration needs a
#                                    live image; skipped - see SKILL.md boundary)
# Upstream runs these on sonic-slave-TRIXIE (go 1.25); we run bookworm + the
# staged go 1.25.9 — same compiler, older glibc/libyang. FILTER=... narrows
# the go test -run pattern.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

REPO="${1:-}"
FILTER="${FILTER:-}"
case "$REPO" in
  sonic-mgmt-common|sonic-gnmi|sonic-restapi|sonic-mgmt-framework) ;;
  *) die "usage: $0 <sonic-mgmt-common|sonic-gnmi|sonic-restapi|sonic-mgmt-framework>" ;;
esac

ensure_swss_container
ensure_go125 swss-build
ensure_git_trust
start_redis_unix swss-build

GOCMD="/usr/local/go125/bin/go"
RUNF='cd /home/liu/SONiC'   # exec helper prefix

# env shared by all go builds: proxy for module downloads, go bin on PATH.
# NOTE: fixed container PATH — never interpolate $PATH here (WSL interop adds
# Windows paths with spaces/parens that break the inner bash -c parsing).
GOENV="PATH=/usr/local/go125/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin http_proxy=$PROXY https_proxy=$PROXY GOPROXY=https://proxy.golang.org,direct GIT_CONFIG_GLOBAL=/home/liu/SONiC/sonic-sairedis/.gitconfig-container"

ensure_gnmi_deps() {
  # gnmi CI: protobuf-compiler, pytest, jsonpatch, sonic_yang_models wheel
  docker exec -u root swss-build bash -c '
    which protoc >/dev/null 2>&1 || apt-get install -y -qq protobuf-compiler >/dev/null 2>&1 || true
    pip3 show sonic-yang-models >/dev/null 2>&1 || \
      pip3 install -q /home/liu/staged/sonic-buildimage-vs/target/python-wheels/bookworm/sonic_yang_models-*.whl
    pip3 show jsonpatch >/dev/null 2>&1 || pip3 install -q jsonpatch || true
    protoc --version | head -1'
}

build_mgmt_common_no_test_bins() {  # gnmi needs mgmt-common build/yang codegen
  # ALSO regenerate translib/ocbinds/ocbinds.go in-tree (ygot): gnmi vendors
  # ../sonic-mgmt-common wholesale, and ocbinds.go is a BUILD artifact —
  # missing it => "ocbinds/schema.go: undefined: Device" (pitfalls #21).
  log "mgmt-common: ensure built (NO_TEST_BINS) + ocbinds generated"
  docker exec -u liu swss-build bash -c "
    set -e; cd /home/liu/SONiC/sonic-mgmt-common
    env $GOENV make translib >/dev/null
    [ -f translib/ocbinds/ocbinds.go ] || { echo 'ocbinds.go not generated'; exit 1; }
    if ! ls sonic-mgmt-common_*.deb >/dev/null 2>&1; then
      env $GOENV NO_TEST_BINS=1 dpkg-buildpackage -rfakeroot -b -us -uc -j\$(nproc) 2>&1 | tail -2
    fi"
}

case "$REPO" in
  sonic-mgmt-common)
    [ -d "$SONIC_WS/sonic-mgmt-common" ] || die "run sync-from-windows.sh sonic-mgmt-common"
    ensure_gnmi_deps
    log "mgmt-common: dpkg-buildpackage (INCLUDE_TEST_MODELS=y)"
    docker exec -u liu swss-build bash -c \
      "cd /home/liu/SONiC/sonic-mgmt-common && env $GOENV INCLUDE_TEST_MODELS=y dpkg-buildpackage -rfakeroot -us -uc -b -j\$(nproc) 2>&1 | tail -4"
    log "mgmt-common: sanity tests (cvl + translib vs redis unix socket)"
    docker exec -u liu swss-build bash -c "
      set -e; cd /home/liu/SONiC/sonic-mgmt-common
      STATUS=0
      DEBDIR=\$(realpath debian/sonic-mgmt-common)
      tools/test/dbconfig.py -o build/tests/database_config.json
      export DB_CONFIG_PATH=\$PWD/build/tests/database_config.json
      (cd build/tests/cvl && CVL_SCHEMA_PATH=testdata/schema ./cvl.test -test.v -logtostderr ${FILTER:+-test.run $FILTER}) || STATUS=1
      tools/test/dbinit.py --overwrite
      (cd build/tests/translib && \
        export CVL_SCHEMA_PATH=\$DEBDIR/usr/sbin/schema YANG_MODELS_PATH=\$DEBDIR/usr/models/yang && \
        ./db.test -test.v -logtostderr ${FILTER:+-test.run $FILTER} && \
        ./translib.test -test.v -logtostderr ${FILTER:+-test.run $FILTER} && \
        ./transformer.test -test.v -logtostderr ${FILTER:+-test.run $FILTER} && \
        ./testapp.test -test.v -logtostderr ${FILTER:+-test.run $FILTER}) || STATUS=1
      exit \$STATUS" | tail -30
    rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] && log "OK: sonic-mgmt-common build + sanity tests green" || die "mgmt-common sanity failed (exit $rc)"
    ;;

  sonic-gnmi)
    [ -d "$SONIC_WS/sonic-gnmi" ] || die "run sync-from-windows.sh sonic-gnmi"
    ensure_gnmi_deps
    # gNOI path translation (pkg/hostfs.Translate) prepends /mnt/host ONLY when
    # that dir exists; upstream test containers don't have it, and its presence
    # breaks TestGnoiFileServer/Remove_Success (removes a wrong path). Remove it.
    docker exec -u root swss-build bash -c 'rm -rf /mnt/host 2>/dev/null || true'
    # syncs from Windows delete the 69 staged testdata files (gnmi tests need them)
    bash "$(dirname "$0")/restore-deleted.sh" sonic-gnmi >/dev/null 2>&1 || true
    build_mgmt_common_no_test_bins
    log "gnmi: make all (force re-vendor after mgmt-common build)"
    docker exec -u liu swss-build bash -c \
      "cd /home/liu/SONiC/sonic-gnmi && rm -rf vendor && env $GOENV GO=$GOCMD make all" | tail -4
    log "gnmi: make check_gotest (race + gomonkey flags)"
    if docker exec -u liu swss-build bash -c \
      "cd /home/liu/SONiC/sonic-gnmi && env $GOENV GO=$GOCMD make check_gotest" \
      > /tmp/gnmi-gotest.log 2>&1; then
      tail -3 /tmp/gnmi-gotest.log
      log "OK: sonic-gnmi gotest green"
    else
      rc=$?
      tail -20 /tmp/gnmi-gotest.log
      die "gnmi check_gotest failed (exit $rc; full log at /tmp/gnmi-gotest.log in WSL)"
    fi
    ;;

  sonic-restapi)
    [ -d "$SONIC_WS/sonic-restapi" ] || die "run sync-from-windows.sh sonic-restapi"
    log "restapi: build + deb (upstream CI is package-build only; unit tests are"
    log "        a local bonus with -vet=off — go1.24+ vet flags this legacy code)"
    docker exec -u liu swss-build bash -c '
      set -e -o pipefail
      export PATH=/usr/local/go125/bin:/usr/local/bin:/usr/bin:/sbin:/bin
      export GO=/usr/local/go/bin/go GOPATH=$HOME/go
      export http_proxy='"$PROXY"' https_proxy='"$PROXY"'
      cd /home/liu/SONiC/sonic-restapi
      make all
      make clean >/dev/null 2>&1 || true
      dpkg-buildpackage -us -uc -b -j"$(nproc)" 2>&1 | tail -3
      ls -1 ../*.deb | tail -2'
    log "OK: sonic-restapi built (deb in ~/SONiC/)"
    ;;

  sonic-mgmt-framework)
    [ -d "$SONIC_WS/sonic-mgmt-framework" ] || die "run sync-from-windows.sh sonic-mgmt-framework"
    ensure_gnmi_deps
    build_mgmt_common_no_test_bins
    log "mgmt-framework: make all (rest + cli)"
    docker exec -u liu swss-build bash -c \
      "cd /home/liu/SONiC/sonic-mgmt-framework && env $GOENV GO=$GOCMD make -j\$(nproc) all" | tail -5
    log "mgmt-framework: rest-gotest + rest-tls + cli smoke"
    docker exec -u liu swss-build bash -c '
      set -e
      export PATH=/usr/local/go125/bin:/usr/local/bin:/usr/bin:/sbin:/bin
      export GO=/usr/local/go/bin/go
      export http_proxy='"$PROXY"' https_proxy='"$PROXY"'
      cd /home/liu/SONiC/sonic-mgmt-framework
      tools/test/rest-gotest.sh -bin | tail -6
      tools/test/rest-tls.sh | tail -3
      tools/test/cli.sh -c exit | tail -3'
    log "OK: sonic-mgmt-framework build + rest/cli tests green"
    ;;
esac
