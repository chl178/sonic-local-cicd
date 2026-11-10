# sonic-local-cicd（中文说明）

在 **Windows + WSL2 + Docker** 上可重复复现的 **SONiC 全仓群本地 CI/CD 流水线**，外加一台跑
官方 nightly 镜像的 **SONiC VS（虚拟交换机）整系统验证虚拟机**（QEMU，WSL2 内）。

它把 sonic-net 各仓库在 Azure Pipelines 上跑的东西搬到你自己的开发机：C++ 仓走与上游完全
相同的 `build-env/build.sh` 打包、Python 仓用上游同款 slave 容器 + 同一套依赖 deb/wheels 跑
pytest、Go 仓用同版工具链跑各自 make test 目标。在此之上叠加了上游 CI 给不了的第二层验证：
把本地构建的组件**部署进运行中的 SONiC VS**，重启目标容器，产出可直接贴进 PR 的英文验证
报告。

本仓库全部经验均来自实战：**25 类流水线坑**（CRLF/执行位损坏、git dubious-ownership 静默
清零 SAI 属性版本表、Azure CDN 拒绝 Range、tmpfs 遮挡 docker cp、上游 2 核 CI 永远看不到的
16 核数据竞争……）逐条以「症状 → 根因 → 修复」记录在
[docs/pitfalls.md](docs/pitfalls.md)。

## 动机

- **不等 CI 队列的 CI 等效验证**：发 PR 前用与上游相同的构建/测试脚本验证分支。
- **快速 TDD 内循环**：过滤式跑测（Rust `cargo test`、pytest `-k`、gtest 单目标、
  `go test -run`），分钟级。
- **整系统收尾关卡**：真实的 SONiC 系统（VS）里部署 deb/wheel、重启容器、捕获健康/行为报告。
- **弱网友好**：上游产物用可断点续传的 curl 经本地代理预取；SONiC wheels（上游 48.6 GB
  单体 zip 且 CDN 拒 Range，根本下不动）改为**本地按依赖序重建**。

## 目录

```
cicd/     15+ 个 sonic-net 仓的构建/测试流水线（bash，可从零复现）
vs/       SONiC VS 实验环境：QEMU 生命周期（run-vs.sh）、nightly 下载器、串口控制台工具
tools/    镜像导出/还原（docker save | zstd | split 及其逆操作）
docs/     用法、流水线设计、VS 实验记录、25 类坑（中文）、镜像来源说明
```

各仓适配总表（脚本、CI 等效内容、基线结果）见 [README.md](README.md#supported-repositories--ci-equivalence)（英文）。

## 快速开始

前置：Windows 10/11 + WSL2（Ubuntu 24.04）+ WSL 内 Docker，~100 GB 空盘，内存 16 GB 推荐。

### 路线一：还原预构建镜像（快）

```bash
# WSL 内；需 gh 已登录、zstd、docker
./tools/load-images.sh v2026.11.10                    # ci-images + vrnetlab-sonic-vs
./tools/load-images.sh v2026.11.10 sonic-vs.img.gz    # 官方 VS nightly 压缩包
```

然后把 sonic-net 工作副本克隆到 `~/SONiC/<仓>`，直接用各仓构建/测试脚本。

### 路线二：从零构建

```bash
wsl -d Ubuntu-24.04 -u root -- bash cicd/wsl-setup.sh   # 建构建用户（uid 1000）
bash cicd/stage-upstream.sh                              # 预取上游 deb 产物
bash cicd/build-sonic-wheels.sh                          # 本地构建 SONiC python wheels
bash cicd/build-swss-image.sh                            # 三张 CI 镜像
bash cicd/build-swsscommon-image.sh
bash cicd/build-pybase-image.sh
bash cicd/build-sairedis.sh && bash cicd/test-sairedis.sh   # 跑任意仓
```

### VS 虚拟机

```bash
mkdir -p ~/SONiC/vs && cp vs/* ~/SONiC/vs/ && cd ~/SONiC/vs
./download-vs.sh && ./run-vs.sh start && ./run-vs.sh wait-ssh
ssh -p 10022 admin@127.0.0.1        # 默认口令 YourPaSsWoRd
```

完整生命周期/串口/monitor 用法与 WSL2 上 QEMU 的坑：[docs/vs-lab.md](docs/vs-lab.md)。

### VS 整系统验证（发 PR 前的收尾关卡）

```bash
bash cicd/build-swss.sh                        # 先出产物
bash cicd/vs-verify.sh sonic-swss --note "针对性验证结论..."
# 报告：~/SONiC/vs/last-vs-report.md，直接贴 PR
```

冒烟内容：14 容器健康、目标进程 supervisorctl、部署二进制 md5 对账、redis 三库 PING、
CLI smoke、目标容器日志致命错误扫描；exit 非零 = 硬失败。本地 bookworm 构建 vs nightly
trixie 容器的 ABI 差异自动处理（配套 staged 库 + so 捆绑 + `dpkg -i --force-depends`）。

## 机器假设（脚本按本机实战原样发布，未做未测试的泛化）

| 项 | 值 | 适配点 |
|---|---|---|
| WSL / 构建用户 | Ubuntu-24.04，`liu`（uid 1000，免密 sudo，docker 组） | `wsl-setup.sh`；或全仓 sed 替换 `/home/liu` |
| 构建树 | `~/SONiC/<仓>`（WSL ext4） | `SONIC_WS` / `lib.sh` |
| Windows 副本 | `/mnt/c/Users/liu/Documents/SONiC` | `lib.sh` 的 `WIN_WS` |
| 代理（可选） | Clash `http://172.17.0.1:7890` | `lib.sh` / `check-ci-status.sh` / `download-vs.sh` |

## 预构建镜像（Release 资产）

zstd 压缩、≤2 GiB 分卷，`tools/load-images.sh` 一键还原（或手动 `cat 分片 | zstd -d | docker load`）：

| 资产 | 内容 | 用途 |
|---|---|---|
| `ci-images.tar.zst.part-*` | `swss-bookworm-master` + `swsscommon-bookworm` + `sonic-ci-py3:base` + `sonic-slave-bookworm:master-amd64`（共享层只存一份） | 完整 CI 环境，省数小时镜像构建（含本地构建的 SONiC wheels） |
| `vrnetlab-sonic-vs.tar.zst.part-*` | `vrnetlab/sonic_sonic-vs:master` | SONiC VS 容器形态（containerlab 组网） |
| `sonic-vs.img.gz.part-*` | 官方 master nightly 原样分卷（QEMU 用） | Azure 端点下不动时的 `download-vs.sh` 替代 |
| `SHA256SUMS` | 全部分片校验和 | 下载后 `sha256sum -c` |

镜像来源与再分发说明：[NOTICE](NOTICE)。

## 与真实 CI 的边界

等价于 Azure Pipelines 的 **Build + 单测阶段**（同脚本同依赖序列）；多架构、ASAN 矩阵、
docker 端到端在上游自托管集群，本地不复刻。上游 CI 本身有红绿波动——先 `check-ci-status.sh`
对照再定位自己的问题。详见 [docs/pipeline.md](docs/pipeline.md)。

## 文档索引

- [docs/usage.md](docs/usage.md) — 工作流 A/B/C/D、容器布局、硬性规则
- [docs/pipeline.md](docs/pipeline.md) — 流水线设计说明
- [docs/vs-lab.md](docs/vs-lab.md) — VS 实验环境（性能、KVM 现状、重置流程）
- [docs/pitfalls.md](docs/pitfalls.md) — 25 类坑：症状 → 根因 → 修复

## 许可

本仓库脚本与文档：[MIT](LICENSE) © 2026 chl178。Release 镜像包派生自 sonic-net 构建产物，
见 [NOTICE](NOTICE)。
