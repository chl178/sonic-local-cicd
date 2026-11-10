# 流水线使用手册（工作流 / 容器布局 / 硬性规则）

> Chinese operational core — English overview in [README.md](../README.md).
> 脚本目录：仓库 `cicd/`。失败诊断先查 [pitfalls.md](pitfalls.md)（#1–#25，症状→根因→修复）。

## 环境事实（假设布局，见 README「Machine assumptions」）

| 项 | 值 |
|---|---|
| WSL 发行版 / 构建用户 | `Ubuntu-24.04` / `liu`（uid 1000，免密 sudo，docker 组） |
| WSL 构建树 | `~/SONiC/{各仓}`（ext4，**构建用这份**） |
| Windows 工作副本 | `/mnt/c/Users/liu/Documents/SONiC/...`（编辑用，勿直接构建） |
| 代理 | Clash `http://172.17.0.1:7890`（WSL 网关）。**pip 装依赖带代理；跑 pytest/grpc 测试前必须去掉代理**（grpc 会把本地测试连接路由进代理，pitfalls #25） |
| 基础镜像 | `sonic-slave-bookworm:master-amd64`（CI 同款，retag :latest/:master） |
| 上游 deb 产物缓存 | `~/staged/{common-libs,sonic-swss-common,sonic-sairedis,sonic-dash-api,vpp}` |
| SONiC python wheels | `~/staged/sonic-wheels-local/`（**本地构建**：上游 vs 产物是 48.6GB 单体 zip 且 CDN 拒 Range，不可下载，pitfalls #16） |
| Go 工具链 | `~/staged/tools/go`（1.25.9；`ensure_go125` 装进容器并接管 /usr/local/go，旧 1.19 备份） |
| SONiC VS 虚拟机 | `~/SONiC/vs/`（本仓库 `vs/` 脚本的部署位置；见 [vs-lab.md](vs-lab.md)），ssh `-p 10022 admin@127.0.0.1` |

## 容器/镜像布局

| 容器/镜像 | 用途 |
|---|---|
| `swss-build`（swss-bookworm-master:latest；**--cap-add NET_RAW --cap-add NET_ADMIN**） | swss + C++/Go 仓构建测试（dhcp4relay 的 AF_PACKET 测试需要能力；redis/工具链常驻） |
| `swsscommon-build`（swsscommon-bookworm:latest） | swss-common 构建 + 全套测试（独立容器保 go 1.19 环境与 swss 区隔） |
| `sonic-ci-py3:base` | Python 仓测试基础镜像（debs + 8 个本地 wheels + dotnet8）；每次测试 `docker run --rm` 起新容器（与上游一 job 一容器同构） |

## 工作流 A：发 PR 前的完整 CI 等效验证

按目标仓选脚本（各仓适配总表见 README）。失败先查 [pitfalls.md](pitfalls.md)。
首次使用顺序：

1. `sync-from-windows.sh [仓...]`（无参=全部已接入仓；**会 revert WSL 树未同步改动**）
2. 首次环境：`stage-upstream.sh` → `build-sonic-wheels.sh` → 按需 `build-*-image.sh`
   （或直接用 Release 预构建镜像 + `tools/load-images.sh`）
3. 目标仓脚本

## 工作流 B：TDD 内循环

- swss Rust：`FILTER=<片段> test-swss.sh`（~2-4 分钟）
- Python 仓：`FILTER=<测试名> test-pyrepo.sh <repo>`（pytest -k）
- C++ 仓：全量走 `build-cpp.sh <repo>`；聚焦可进容器 make 单目标
- Go 仓：`FILTER=<Test名> test-gorepo.sh sonic-mgmt-common`；gnmi vendor 就绪后可进容器 `go test <包> -run <名>`
- sairedis 全量 make check（~25 分钟）：`test-sairedis.sh`

改代码位置约定：改 WSL 树跑测试最快，验证通过后回 Windows 副本同步改（或反向）。

## 工作流 C：环境重建（罕见）

- WSL 初始化：`wsl -d Ubuntu-24.04 -u root -- bash cicd/wsl-setup.sh`
- 上游 deb 产物刷新：`rm -rf ~/staged/<name> && stage-upstream.sh`（vs 除外，不可下载）
- SONiC wheels 重建：`build-sonic-wheels.sh`（依赖序：yang-models→redis-dump-load→py-common→
  py-swsssdk→yang-mgmt→config-engine→platform-common→utilities；各包 setup.py 会 import
  前序依赖，必须边建边装）
- Go 工具链预取：go.dev 下载 go1.25.9 解压到 `~/staged/tools/go`（ensure_go125 自动装容器）
- 镜像：`build-swss-image.sh` / `build-swsscommon-image.sh` / `build-pybase-image.sh`
- 容器重建保留状态：`docker commit swss-build swss-bookworm-master:withstate &&
  docker rm -f swss-build && docker run -d --name swss-build --restart unless-stopped
  --cap-add NET_RAW --cap-add NET_ADMIN -v /home/liu:/home/liu
  swss-bookworm-master:withstate sleep infinity`

## 工作流 D：VS 整系统验证（发 PR 前的收尾关卡）

**双层验证模型**：TDD 红绿循环用组件级测试（工作流 B，快）；每个需求/bugfix 完成、发 PR
前跑一次 VS 整系统验证——把本地构建的组件部署进运行中的 SONiC VS 虚拟机，重启目标容器，
冒烟检查后产出英文 markdown 报告，直接作为 PR 评论素材。

```bash
# 前置：先跑对应构建出产物，再验证（脚本不自动触发构建）
bash cicd/build-swss.sh        # 出 ~/SONiC/sonic-swss/swss_*.deb
bash cicd/vs-verify.sh sonic-swss --note "behavioral findings ..."
# 报告：~/SONiC/vs/last-vs-report.md（--report 可改路径；--note 追加针对性验证结论）
```

| 仓 | 产物 | 部署目标 |
|---|---|---|
| sonic-utilities（✅ 可用） | `~/staged/sonic-wheels-local/sonic_utilities-*.whl` | VS host（pip3 --force-reinstall --no-deps） |
| sonic-swss（⏸ 迁移窗口期暂停，pitfalls #29） | `swss_*.deb`（仓根） | `swss` 容器（dpkg -i --force-depends + 配套 staged 库） |
| sonic-sairedis（⏸ 同上） | `syncd-vs_* / libsairedis_* / libsaivs_* / libsaimetadata_*` | `syncd` 容器 |

**⏸ 边界**：本地构建链全 bookworm、master nightly VS 容器已 trixie——C++ so 可捆绑搬运，
但 python C 扩展绑定（python3-swsscommon）不能跨 3.11/3.13 解释器，swss/sairedis 的 VS
验证需待本地构建链转 trixie 后启用（届时 vs-verify.sh 的 EXTRA_DEBS 换 trixie 配套即可，
部署/审计/报告机制已验证有效——md5 对账两次抓住假绿）。host/纯 py 组件（utilities 及后续
py 仓）现即可用。

- 脚本自动确保 VM 在跑（停机则 run-vs.sh start + wait-ssh）；冒烟含容器健康 14/14、
  目标进程 supervisorctl、部署二进制 md5 对账、redis 三库 PING、CLI smoke、目标容器日志
  致命错误扫描；exit 非零 = 硬失败。
- **bookworm 构建 vs trixie nightly 镜像的结构性差异自动处理**：dpkg -i 走
  `--force-depends`（跨发行版包名不同），并自动从 `swss-build` 容器捆绑缺失 so（如
  `libhiredis.so.0.14`，trixie 只带 so.1）随 deb 部署。
- **适用性标准**：改动影响控制面行为且 VS 可观察（show / redis / 日志 / CLI 行为）→ 应跑
  并把结果贴 PR；硬件/平台特定（platform-common eeprom/sfp、pmon 传感器等 VS 无硬件）→
  可豁免，但 PR 描述注明「VS 不适用 + 原因」。针对性行为验证（构造触发条件、观察期望行为）
  由开发者 ssh 进 VS 执行，结论经 `--note` 入报告。
- 已知限制：VS 为 TCG 软模拟（无 KVM，见 vs-lab.md），部署+重启一轮 ~5-10 分钟；
  **重型构建（build-swss/build-sairedis 等 -j16 编译）期间必须先 `run-vs.sh stop` 停掉
  VS VM**——VM 常驻 4GB + 全量构建超出 WSL 15GB 上限会导致 swap 抖动、WSL 服务超时假死
  （两次实测），构建完再拉起 VM 做验证。容器内暂存路径勿用 /tmp（tmpfs 遮挡 docker cp）。
  部署会污染 VS 状态：重置 = `rm ~/SONiC/vs/sonic-vs.img* && download-vs.sh && run-vs.sh start`。

## 硬性规则（违反会产生静默错误结果）

1. **`git checkout -- .` 之后必须重打 sairedis install shim**（sync 脚本已内置）。
2. **sairedis 构建必须注入 `GIT_CONFIG_GLOBAL`**（缺它属性版本表静默清零）。
3. **跑测试前起 redis**；unix socket 场景用 `start_redis_unix`（脚本已内置）。
4. **不要 pull 覆盖本地 slave 标签**；ensure_slave_tags 本地存在即跳过（pull 会挂死）。
5. swss/swsscommon 用常驻容器（sleep infinity），不用 compose。
6. Windows 侧调用走脚本文件，勿拼 wsl.exe 复杂内联命令（变量吞噬，#19）；
   Git Bash 调用需 `MSYS_NO_PATHCONV=1` 前缀。
7. **别编辑正在后台运行的脚本**（#20）。
8. **pytest/grpc 测试不带 http_proxy**（#25）：pip 带代理装依赖、`env -u` 去代理跑测试。
9. gnmi 构建前 mgmt-common 必须重建（vendor 拷贝其生成代码 ocbinds.go，#21）；
   gnmi 的 69 个 testdata 删除态用 `restore-deleted.sh sonic-gnmi` 恢复。
10. CRLF/执行位/symlink 由 sync+normalize 自动处理（含 platform-common 的
    sonic_eeprom/sonic_sfp 符号链接、utilities 的 scripts/warm-reboot 等）。
11. docker build 的 apt 步骤慢：swsscommon/pybase 镜像构建的 apt 直连 deb.debian.org
    慢属正常（10-20 分钟量级）；不要中途杀。

## 失败诊断

按症状查 [pitfalls.md](pitfalls.md)。上游 CI 对照：`check-ci-status.sh [pipeline名]
[commit前缀]`（判断"上游是否也红"）。仓库树健康：`check-repos.sh`。

## 与真实 CI 的边界

- 等价于各仓 Azure Pipelines 的 Build + unit test 阶段（同脚本同依赖序列）；
  gnmi/mgmt-common 上游用 trixie slave，本地 bookworm + 同版 go1.25.9，差异仅
  glibc/libyang 小版本。
- 多架构、ASAN 矩阵、docker 端到端（restapi/redfish 集成、docker-sonic-vs）在上游
  自托管集群，本地不复刻。
- 未接入：sonic-redfish（trixie+bmcweb 克隆，重）、sonic-frr（打包巨兽、无单测 CI）；
  不可行：sonic-mgmt（需真机 DUT）、sonic-linux-kernel。
- 上游 CI 本身有红绿波动；本地失败先 `check-ci-status.sh` 对照上游再定位。
