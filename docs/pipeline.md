# 流水线设计说明（本地如何镜像官方 CI）

> Chinese design notes — English overview in [README.md](../README.md).
> 操作层面（工作流/硬性规则）见 [usage.md](usage.md)；全部踩坑记录见 [pitfalls.md](pitfalls.md)。

## 背景与布局

本机（Windows + WSL2 Ubuntu-24.04 + Docker）复刻官方 CI 的构建与单元测试：
C++ 仓走与 Azure Pipelines 完全相同的 `build-env/build.sh`（autogen +
dpkg-buildpackage，测试内嵌 dh）；Python 仓在上游同款 slave 容器 + 同一套
依赖 deb/wheels 里跑 pytest；Go 仓用本地 go1.25.9（同上游 trixie slave 版本）
跑各自的 make test 目标。

| 位置 | 内容 |
|------|------|
| `~/SONiC/{各仓}` | 构建用源码树（WSL ext4；已接入 15 仓 + buildimage） |
| Windows 侧工作副本 | 日常编辑用，勿直接构建（CRLF/执行位/symlink 由 `sync-from-windows.sh` + `normalize_repo` 归一化后进 WSL 树） |
| `~/staged/` | 上游 deb 产物（common-libs/swss-common/sairedis/dash-api/vpp）+ **本地构建的 SONiC wheels**（上游 vs 产物 48.6GB 不可下载）+ go1.25.9 工具链 |
| Docker | `swss-build`（+NET_RAW/NET_ADMIN）、`swsscommon-build`、`sonic-ci-py3:base`（Python 仓测试基础镜像） |

## 本地相对官方流程的关键适配

1. Windows 检出的 CRLF/执行位/**symlink**（platform-common 的 sonic_eeprom 等）按
   git 索引归一化（sync-from-windows.sh + normalize_repo）。
2. 上游 `debian/syncd-vs*.install` 自引用 → 本地 shim（checkout 后需重打）。
3. git dubious-ownership → `GIT_CONFIG_GLOBAL` 注入（否则 sairedis 属性版本表静默清零）。
4. slave 镜像统一对齐 CI 的 `:master-amd64` 标签；本地存在即不 pull（pull 会挂死）。
5. Azure CDN 不稳 → deb 产物 curl 预取；**vs 产物（python wheels）改为本地构建**
   （build-sonic-wheels.sh，依赖序边建边装）。
6. 测试前起 redis（unix socket 场景 start_redis_unix）；swss/swsscommon 用常驻容器。
7. pytest/grpc 测试不带 http_proxy（pip 装依赖带、跑测试 env -u 去掉）。
8. config-engine 测试需把 buildimage device/ 挂到 /sonic/device（读写）。
9. dhcp4relay 需容器 NET_RAW/NET_ADMIN（AF_PACKET 测试）。
10. gnmi 依赖 mgmt-common 先构建（ocbinds.go 生成后才 vendor）+ testdata 恢复。

## 与真实 CI/CD 的边界

仓库内 Azure Pipelines 的多架构、ASAN、docker 端到端在 sonic-net 自托管集群，
本地不复刻；gnmi/mgmt-common 上游用 trixie slave，本地 bookworm + 同版 go。
未接入：redfish、frr；不可行：sonic-mgmt（真机）、linux-kernel。

## 关联环境

- **SONiC VS 虚拟机**（整系统级调试/演示 + vs-verify 收尾关卡）：QEMU 跑官方
  master nightly，WSL 内 `~/SONiC/vs/`，见 [vs-lab.md](vs-lab.md)。与本流水线的
  组件级 CI 互补；其 KVM 不可用结论与镜像下载坑位记录在 vs-lab.md，勿重复踩。
