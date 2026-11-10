# SONiC VS 虚拟机实验环境（QEMU，WSL2 内）

> Chinese lab notes — English overview in [README.md](../README.md).
> 脚本在本仓库 `vs/`；运行位置约定 `~/SONiC/vs/`（`mkdir -p ~/SONiC/vs && cp vs/* ~/SONiC/vs/`）。

调出于官方 master nightly 镜像（实测版本 `SONiC.master.1269891-b351f8036`，
2026-11-07 构建，Debian 13.7 / 内核 6.12.41），在 WSL2 Ubuntu-24.04 内以 QEMU TCG
软模拟运行。日常入口：WSL 内 `~/SONiC/vs/run-vs.sh`。

## 布局

| 文件（`~/SONiC/vs/`） | 说明 |
|---|---|
| `sonic-vs.img` | 系统盘（**QCOW2**，`.img` 后缀有欺骗性；虚拟 16G，实际 ~8G） |
| `sonic-vs.img.gz` / `.source` | 下载留档 + 构建来源（buildId/日期/URL） |
| `run-vs.sh` | 生命周期管理：start/stop/status/console/wait-ssh/monitor |
| `download-vs.sh` | 重新下载最新 master nightly（覆盖换版本） |
| `console.log` | 串口全程日志（排障第一现场） |
| `ppm2png.py` | QEMU screendump 的 PPM→PNG 转换器（无 PIL/ImageMagick 时用） |

## 日常命令

```bash
# WSL 内
~/SONiC/vs/run-vs.sh start|stop|status|wait-ssh|console
~/SONiC/vs/run-vs.sh monitor "info blockstats"   # QEMU monitor 直达

# 登录（默认 admin / YourPaSsWoRd）
ssh -p 10022 admin@127.0.0.1          # WSL 内
ssh -p 10022 admin@127.0.0.1          # Windows 侧（localhost 中继，已验证）
ssh -p 10022 admin@<WSL eth0 IP>      # Windows 侧直连 WSL IP（IP 会变）
```

- 串口交互：`run-vs.sh console`（Ctrl-] 退出）；纯看日志 `tail -f console.log`。
- 扩展参数：`IMG= MEM_MB= SMP= SSH_PORT= SSH_BIND=` 环境变量可覆盖
  （多节点实验时复制一份镜像、改 SSH_PORT 即可）。
- WSL 重启后 VM **不会自动拉起**，需手工 `start`。

## 性能预期（TCG）

- 启动到 sshd：~1-2 分钟；容器全部拉起：~5 分钟。
- `show`/`config` 可用但偏慢；config save 数秒。属正常，不是故障。
- 如未来 KVM 可用（见下），脚本会自动切换并起飞。

## 已定结论与坑（勿重蹈）

1. **KVM 不可用，勿再折腾**：`.wslconfig` 已设 `nestedVirtualization=true`
   且 WSL 已最新，但 Hyper-V 不向 WSL2 暴露嵌套虚拟化（dmesg
   `Hyper-V: Nested features: 0x0`；kvm 内建但 KVM_CREATE_VM=ENODEV；kvm_amd
   无法加载）。上游追踪：
   <https://github.com/microsoft/WSL/issues/13262>。脚本每次 start 都会
   实测 KVM（真建一台一次性 VM，而非只看 /dev/kvm），通了自动用。
2. **sonic-vs.img 是 QCOW2 不是 raw**：`-drive format=raw` 指着它会引导到
   "No bootable device"（MBR 处无 0x55AA、SeaBIOS 只读 1 扇区）。症状对照：
   blockstats `rd_bytes=512`。脚本用 `qemu-img info` 自动探测格式。
3. **hostfwd 必须绑 0.0.0.0**：WSL 的 localhostForwarding 与本机 Clash 代理
   相互干扰（启动横幅「localhost 代理配置…NAT 模式不支持」），实测
   Windows→127.0.0.1:10022 中继会连而不通；绑 0.0.0.0 后 WSL IP 直连与
   localhost 中继均验证可用。机器在 NAT 路由器后，无暴露风险。
4. **wait-ssh 必须真登录探测**：`/dev/tcp` 连 QEMU hostfwd 会立刻成功
   （host 侧先接受），sshd 远未就绪是假阳性；脚本用 sshpass 循环真连。
5. **stop 的 powerdown 等 90s**：TCG 下 guest 关容器慢；等不到再走 monitor
   `quit`（ext4 日志保护，实测配置无损）。勿直接 kill -9。
6. 镜像下载：官方索引
   `https://sonic-net.github.io/SONiC/sonic_latest_images.html` →
   `sonic_image_links.json`（raw.githubusercontent 可能需代理）→ Azure
   Artifacts 直链**只支持整文件 GET**（Range→400，断点续传勿指望），~2.4GB
   直连可跑满。GitHub Releases 已清空、旧 `sonic-build.azureedge.net` 域名已死，
   别再走。下载不动时可用本仓库 Release 的 `sonic-vs.img.gz.part-*` 还原。
7. 经 UNC 写 WSL 文件的工具落盘属主为 root 且丢执行位：编辑 `~/SONiC/vs/` 下
   脚本后需 `sudo chown liu:liu <file> && chmod +x <file>`。

## 作为开发验证平台（vs-verify，工作流 D）

开发验证的双层模型第二层：组件级 CI 全绿后、发 PR 前，把本地构建的组件
**部署进这台 VS 做整系统验证**，产出的英文报告直接作为 PR 评论素材
（见 [usage.md](usage.md) 工作流 D）。

```bash
# 在 WSL 内（先跑对应 build-* 脚本出产物）
bash cicd/vs-verify.sh sonic-swss --note "behavioral findings ..."
# 机制：scp 产物 → docker cp 进目标容器 → dpkg -i → docker restart →
#       冒烟（容器健康/进程/md5 对账/redis/CLI/日志扫描）
# 目标映射：utilities wheel→VS host（✅ 可用）；
#           swss→swss 容器、syncd-vs→syncd 容器（⏸ bookworm/trixie 迁移
#           窗口期结构性暂停，见 pitfalls #29）
# 报告：~/SONiC/vs/last-vs-report.md
```

- 部署会**污染 VS 状态**（deb 覆盖官方 nightly 组件）。重置出厂：
  `cd ~/SONiC/vs && ./run-vs.sh stop && rm sonic-vs.img* && ./download-vs.sh && ./run-vs.sh start`
- VS 镜像与本地仓相差数天时 deb 依赖可能错位（dpkg -i 失败）：
  `--force-depends` 逃生并在报告注明；或换新镜像/重下。
- **重型构建期间停掉 VM**（`run-vs.sh stop`）：VM 常驻 4GB + `-j16` 全量
  编译超出 WSL 15GB 内存上限 → swap 抖动 → WSL 服务超时假死（两次实测，
  第二次仅构建+常驻 VM 也崩）。构建完再 `run-vs.sh start` 验证。

## 后续扩展提示

- **接 sonic-mgmt**：VS mgmt IP 在 user-net（10.0.2.15），经 hostfwd 只有
  ssh 可达；跑 vtest 需把 sonic-mgmt 检出到 WSL，inventory 指向
  `127.0.0.1:10022`（WSL 内）。多节点拓扑用 containerlab + `vrnetlab/sonic_sonic-vs`
  镜像（见本仓库 Release）。
- **换版本**：`rm sonic-vs.img* && ./download-vs.sh`（会拉最新 master）。
