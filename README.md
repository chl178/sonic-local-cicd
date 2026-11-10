# sonic-local-cicd

A reproducible, **local CI/CD pipeline for [SONiC](https://github.com/sonic-net) repositories** on
Windows + WSL2 + Docker — plus a **SONiC VS (virtual switch) full-system verification lab** that
runs the official nightly image under QEMU inside WSL2.

It replicates, on one dev machine, what `sonic-net` repositories run on Azure Pipelines: the same
`build-env/build.sh` packaging for C++ repos, the same slave containers and dependency set for
Python repos, and the same make/test targets for Go repos. On top of that it adds a second
verification layer the upstream CI does not give you: deploying your locally built components
into a running SONiC VS instance and producing a health/behavior report suitable for PR comments.

Everything here was learned the hard way. **25 distinct pipeline pitfalls** (CRLF/exec-bit
corruption, git dubious-ownership silently zeroing SAI attribute versions, Azure CDN refusing
Range requests, tmpfs shadowing `docker cp`, a glibc-vs-CPU-count data race that upstream CI
never sees, …) are documented with symptom → root cause → fix in
[docs/pitfalls.md](docs/pitfalls.md) (Chinese; the code comments are English).

## Why

- **CI equivalence without the queue**: validate a branch *before* opening a PR, using the same
  build/test scripts the upstream pipelines run.
- **Fast TDD inner loops**: filtered test runs in minutes (Rust `cargo test`, pytest `-k`,
  single gtest targets, `go test -run`).
- **End-to-end gate**: a real SONiC system (VS) where you can deploy your `.deb`/wheel, restart
  the target container, and capture an English verification report for the PR.
- **Works from China-grade networks**: upstream artifacts are prefetched with resumable curl via
  a local proxy; the SONiC wheels (a 48.6 GB monolithic zip upstream that rejects Range
  requests) are **rebuilt locally** in dependency order instead of downloaded.

## Repository layout

```
cicd/     build/test pipeline for 15+ sonic-net repos (bash, from-scratch reproducible)
vs/       SONiC VS lab: QEMU lifecycle (run-vs.sh), nightly downloader, serial console helpers
tools/    release image export/restore (docker save | zstd | split, and the inverse)
docs/     usage, pipeline notes, VS lab notes, pitfalls (zh), image provenance
```

## Supported repositories & CI equivalence

Validated 2026-10-25 on one machine (16-core, WSL2 15 GB RAM cap):

| Repository | Script (`cicd/`) | CI-equivalent work | Baseline |
|---|---|---|---|
| sonic-sairedis | `build-sairedis.sh` / `test-sairedis.sh` | `build.sh` → 13 debs; `make check` 23 suites | all green |
| sonic-swss | `build-swss.sh` / `test-swss.sh` | `build.sh` → deb; `cargo test` | all green |
| sonic-swss-common | `build-swsscommon-image.sh` → `build-swsscommon.sh` → `test-swsscommon.sh` | debs; cargo ×2 + gtest + pytest-3 (158) + goext | all green |
| sonic-utilities | `test-pyrepo.sh` | pip install `.[testing]` + pytest (~5600, xdist) | 5287 pass / 365 fail — an **upstream breakage window** (`db_migrator` vs `version_202605_01` stamp), reproduced faithfully, not an env issue |
| sonic-snmpagent / sonic-host-services / sonic-dbsyncd / sonic-platform-common / sonic-platform-daemons | `test-pyrepo.sh` | each repo's pytest suite | all green |
| sonic-linkmgrd | `build-cpp.sh` | 190 gtests + ASan + gcovr; deb | all green |
| sonic-dhcp-relay / sonic-dhcpmon | `build-cpp.sh` | recursive submodules + `dpkg-buildpackage` (gtest inside dh) | green |
| sonic-mgmt-common | `test-gorepo.sh` | packaging + cvl/translib suites vs redis unix socket | all green |
| sonic-gnmi | `test-gorepo.sh` | mgmt-common rebuild (ocbinds) → re-vendor → `make all` → `check_gotest` (9 pkgs, race) | 1080+ tests, 1 failure = a **real product data race** (`client_subscribe.go:140` vs `:272`; reproduces on 16 cores, upstream's 2-core CI never triggers it) |
| sonic-restapi / sonic-mgmt-framework | `test-gorepo.sh` | `make all` (+deb) / rest+cli gtest & smoke | green |
| sonic-buildimage in-tree python | `test-buildimage-src.sh` | config-engine / yang-mgmt / yang-models / py-common / bgpcfgd pytest | all green |
| sonic-redfish, sonic-frr | — | out of scope (needs trixie+bmcweb clone / packaging monster, no unit-test CI) | — |
| sonic-mgmt, sonic-linux-kernel | — | not feasible locally (needs real DUT / kernel builds) | — |

Diagnostics: `check-ci-status.sh` compares your failure against the live upstream pipeline
("is upstream red today too?"), `check-repos.sh` audits tree health.

## Quick start

Prerequisites: Windows 10/11 + WSL2 (Ubuntu 24.04), Docker inside WSL2, ~100 GB free disk,
16 GB RAM recommended (a WSL memory cap of 15 GB is what the pipeline is tuned for).

### Path 1 — restore the prebuilt images (fast)

```bash
# inside WSL2; gh authenticated, zstd + docker present
./tools/load-images.sh v2026.11.10          # ci-images + vrnetlab-sonic-vs
./tools/load-images.sh v2026.11.10 sonic-vs.img.gz   # official VS nightly archive
```

Then clone your sonic-net working copies to `~/SONiC/<repo>` and jump straight to the per-repo
build/test scripts. See [Prebuilt images](#prebuilt-images).

### Path 2 — build everything from scratch

```bash
# 1. WSL: create the build user (uid 1000, docker group, passwordless sudo)
wsl -d Ubuntu-24.04 -u root -- bash cicd/wsl-setup.sh

# 2. clone/mirror your sonic-net working copies under ~/SONiC/ (see Machine assumptions)

# 3. prefetch upstream deb artifacts + build the SONiC python wheels locally
bash cicd/stage-upstream.sh
bash cicd/build-sonic-wheels.sh

# 4. build the three CI images (slave base is pulled from the upstream registry)
bash cicd/build-swss-image.sh
bash cicd/build-swsscommon-image.sh
bash cicd/build-pybase-image.sh

# 5. run any repo's pipeline, e.g.
bash cicd/build-sairedis.sh && bash cicd/test-sairedis.sh
```

### The VS lab (QEMU inside WSL2)

```bash
mkdir -p ~/SONiC/vs && cp vs/* ~/SONiC/vs/
cd ~/SONiC/vs
./download-vs.sh      # fetch the official master nightly (sonic-vs.img.gz ~2.4 GB)
./run-vs.sh start     # QEMU; auto-detects KVM, falls back to multi-threaded TCG
./run-vs.sh wait-ssh  # real-login probe (a /dev/tcp probe lies behind QEMU hostfwd)
ssh -p 10022 admin@127.0.0.1   # default password: YourPaSsWoRd
```

Full lifecycle, console, monitor access and the collected QEMU-on-WSL2 gotchas:
[docs/vs-lab.md](docs/vs-lab.md).

## Workflows

- **A — pre-PR full CI verification**: pick the per-repo script from the table above.
- **B — TDD inner loop**: filtered runs (`FILTER=... test-swss.sh`, `FILTER=<test> test-pyrepo.sh
  <repo>`, …). Details in [docs/usage.md](docs/usage.md).
- **C — environment rebuild**: image/container rebuild recipes ([docs/usage.md](docs/usage.md)).
- **D — VS end-to-end gate**: deploy locally built artifacts into the running VS, restart the
  target container, smoke-check (14-container health, supervisor processes, md5 audit of deployed
  binaries, redis PING ×3, CLI smoke, fatal-log scan) and emit an English markdown report:

  ```bash
  bash cicd/build-swss.sh     # produce artifacts first
  bash cicd/vs-verify.sh sonic-swss --note "behavioral findings ..."
  # report: ~/SONiC/vs/last-vs-report.md  (paste into the PR)
  ```

  `vs-verify.sh` handles the bookworm(build)→trixie(VS) ABI gap by co-deploying the exact staged
  libs, bundling missing shared objects and running `dpkg -i --force-depends`; its md5 audit has
  caught silent non-deploys ("fake greens") twice.

## Machine assumptions

The scripts encode one concrete, working machine and are published **as-is** (untested
generalizations are worse than honest specifics). They assume:

| Item | Value | Where to adapt |
|---|---|---|
| WSL distro / build user | Ubuntu-24.04, user `liu`, uid/gid 1000, passwordless sudo, docker group | `wsl-setup.sh`, or `grep -rl '/home/liu' cicd/ \| xargs sed -i "s|/home/liu|/home/YOU|g"` |
| Build trees | `~/SONiC/<repo>` (ext4, inside WSL) | `SONIC_WS` env / `lib.sh` |
| Windows working copies | `/mnt/c/Users/liu/Documents/SONiC` | `WIN_WS` in `cicd/lib.sh` |
| HTTP proxy (optional) | Clash at `http://172.17.0.1:7890` (Windows host via docker bridge) | `PROXY`/`PROXY_HOST` in `lib.sh`, `check-ci-status.sh`, `download-vs.sh` |

Everything is plain bash; overriding those three knobs adapts the pipeline to another host.

## Prebuilt images

The [releases](https://github.com/chl178/sonic-local-cicd/releases) carry ready-to-load image
bundles (zstd, split into ≤2 GiB parts; restore with `tools/load-images.sh`):

| Asset | Contents | Use |
|---|---|---|
| `ci-images.tar.zst.part-*` | `swss-bookworm-master:latest`, `swsscommon-bookworm:latest`, `sonic-ci-py3:base`, `sonic-slave-bookworm:master-amd64` (shared layers stored once) | the complete CI environment: skip hours of image builds incl. the locally built SONiC wheels |
| `vrnetlab-sonic-vs.tar.zst.part-*` | `vrnetlab/sonic_sonic-vs:master` (= `vrnetlab/vr-sonic:master`) | SONiC VS as a container (containerlab topologies) |
| `sonic-vs.img.gz.part-*` | official SONiC master nightly for QEMU, unmodified, split as-is | `vs/download-vs.sh` equivalent when the Azure endpoint is unreachable |
| `SHA256SUMS` | checksums of all parts | `sha256sum -c` after download |

Provenance and redistribution notes: [NOTICE](NOTICE).

## Boundaries vs upstream CI

Equivalent to the Azure Pipelines **build + unit-test stages** (same scripts, same dependency
sequence). Not replicated: multi-arch, ASAN matrix, docker end-to-end jobs (upstream
self-hosted); `gnmi`/`mgmt-common` run on a bookworm slave locally vs trixie upstream (same Go
1.25.x toolchain). Upstream CI itself fluctuates red/green — check with `check-ci-status.sh`
before debugging your own failure. Details: [docs/pipeline.md](docs/pipeline.md).

## Documentation

- [docs/usage.md](docs/usage.md) — per-workflow walkthrough, container layout, hard rules
- [docs/pipeline.md](docs/pipeline.md) — design notes: how the local pipeline mirrors upstream
- [docs/vs-lab.md](docs/vs-lab.md) — the SONiC VS QEMU lab: performance, KVM status, reset flows
- [docs/pitfalls.md](docs/pitfalls.md) — 25 pitfalls, symptom → root cause → fix (Chinese)

## License & notice

Scripts and docs in this repository: [MIT](LICENSE) © 2026 chl178.
The release image bundles are derived from sonic-net build artifacts — see [NOTICE](NOTICE).
