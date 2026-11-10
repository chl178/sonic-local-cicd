# 踩坑记录（症状 → 根因 → 修复）

2026-10-25 搭建本流水线时逐个踩过并验证的坑。诊断构建/测试失败时先在这里按症状检索。

---

## 1. CRLF 行尾（Windows 检出污染）

**症状**：容器内 `exec ./build-env/build.sh: no such file or directory`（文件明明存在）；
autotools/automake 各种离奇解析失败。

**根因**：Windows 上 `core.autocrlf=true` 检出的工作副本全部 CRLF，rsync 原样带入 WSL。
shebang 变成 `#!/bin/bash\r`，内核找不到 `/bin/bash\r` 解释器，报 "no such file or directory"
（不是权限问题！）。

**修复**：`normalize_repo`（lib.sh）：`git config core.autocrlf false` + `git checkout -- .`。
仓库里少数文件在对象库中本来就是 CRLF（如 swss 的 7 个文件）——checkout 后仍是 CRLF 是正常的，
CI 也用这些字节。

## 2. 杂散执行位（drvfs 权限语义）

**症状**：`dh_installdirs: error: debian/syncd-vs.dirs (executable config) returned exit code 127`
——debhelper 把带执行位的配置文件当脚本执行。

**根因**：从 /mnt/c（drvfs）拷贝的文件部分带 +x；debhelper 对可执行配置文件的行为是
"执行并读取 stdout"。

**修复**：先全树去执行位，再按 git 索引恢复 100755 的文件（`normalize_repo`）。
注意：**SAI 子模块也要做**（`parse.pl`/`attrversion.sh` 等都是 755）。
反向坑：修复脚本若把 `build-env/build.sh`、`debian/rules`、`autogen.sh` 的执行位漏掉，
则报 `permission denied`（dpkg-buildpackage 执行 debian/rules 需要 +x）。

## 3. git dubious ownership → 属性版本表静默清零（最隐蔽）

**症状**：构建"成功"，但 `AttrVersionChecker.isSufficientVersion` 单测失败
（`isSufficientVersion` 该返回 false 却返回 true）；deb 里 `SAI_METADATA_HAVE_ATTR_VERSION` 为 0。

**根因**：compose 容器以 root 运行，源码树属 liu → 容器内 git 报
`fatal: detected dubious ownership` → `SAI/meta/attrversion.sh` 的
`if ! git rev-parse --git-dir` 走"非 git 仓库"分支，**只打个 WARNING 就静默退出**，
生成空的 saiattrversion.h → 5825 条属性版本变成 0 → 版本检查逻辑整体禁用。
日志里 grep `this is not git repository` 出现 4 次即是此坑。

**修复**：注入信任配置 `-e GIT_CONFIG_GLOBAL=/workspace/.gitconfig-container`
（内容 `[safe] directory = *`）。**不能用** `-c safe.directory=*` 或 `GIT_CONFIG_KEY_*`
注入——git 明确拒绝命令级配置设置 safe.directory。

## 4. 上游 `debian/syncd-vs.install` 自引用（上游疑似 bug）

**症状**：`dh_install: warning: Cannot find (any matches for) "syncd.install" ...`
`dh_install: error: missing files, aborting`，打包最后一步失败。

**根因**：`debian/syncd-vs.install` 与 `syncd-rpc.install` 的内容是字面字符串
`syncd.install`（2017 年 d22bffb 引入，至今未改）。当前镜像的 debhelper 13.11.4
把每行当源文件 glob，无 include 语义；而上游 CI（同 commit 1eb0703、同镜像 tag）
却能成功且 syncd-vs.deb 含全部 16 个文件——机制未查明（当日镜像 digest 不可考）。
已排除：dh-exec、执行位触发 dh-exec、debian/rules 生成、commit 差异。

**修复**：`apply_install_shim`（lib.sh）——把 `debian/syncd.install` 的清单复制给两个
变体文件。已用 CI 产物（run 1256515）`dpkg -c` 逐文件核对一致。
**注意顺序坑：`git checkout -- .` 会还原此 shim，必须重打。** 值得给上游提 issue。

## 5. Azure 产物 CDN 下载不稳（Read timeout / InvalidChunkLength）

**症状**：swss 镜像构建中 buildenv_setup 层反复失败：
`HTTPSConnectionPool(host='artprodcus3.artifacts.visualstudio.com', port=443): Read timed out`
或 `Connection broken: InvalidChunkLength`。代理和直连都遇到过。

**根因**：到 Azure artifacts CDN 的大文件传输在本网络不稳定；docker 内 python 下载无断点
续传，一次失败整个层重来（每次 ~12 分钟）。

**修复**：`stage-upstream.sh` 用 `curl --retry 5 --retry-all-errors -C -`（可续传）预取
5 套产物到 `~/staged/`；`build-swss-image.sh`（配合 `Dockerfile.swss-local`）以
`--upstream-staged-dir /staged --required-staged-upstream <每个名字>` 完全离线构建。
sairedis 的 bundle 必须附带其 `build-env/`（级联安装 vpp/swss-common 依赖用）。

## 6. slave 镜像标签不一致

**症状**：与 CI 行为莫名不一致（见 #4 的排查过程）。

**根因**：CI 用 `sonic-slave-bookworm:master-amd64`；sairedis Dockerfile 写死 `:latest`，
swss Dockerfile 用 `:master`（无架构后缀）。registry 的 `:latest` 与 `:master-amd64`
**内容不同**（dh-exec 有无等差异）。

**修复**：`ensure_slave_tags`——pull `:master-amd64` 并 retag 成 `:latest` 和 `:master`。
不要从 registry 重新 pull `:latest` 覆盖。

## 7. 测试需要 redis（临时容器里没起）

**症状**：sairedis `vslib` 套件 `Unable to connect to redis (unix-socket) - ... Cannot
assign requested address` 后 core dump；swss cargo test `countersyncd` 15 个用例
`SWSSDBConnector_new_unix` 连接失败。

**根因**：CI 的容器里 redis 由 buildenv_setup 配置并常驻；compose run 起的临时容器只有
镜像里烤好的配置，服务没起。

**修复**：跑测试前 `start_redis_in_container`（lib.sh）。build-swss.sh / test-*.sh 已内置。

## 8. compose 项目名与子网冲突

**症状**：`docker compose up` 报 `invalid pool request: Pool overlaps with other one
on this address space`，容器创建失败；随后 `docker exec` 报
`No such container: swss-bookworm-master`。

**根因**：sairedis 与 swss 的 compose 文件都在 `build-env/` 目录 → 项目名都是
`build-env`；sairedis 项目的默认网络占了 172.19.0.0/16，swss compose 声明的
172.19.0.0/24 与之重叠。

**修复**：swss 不用 compose，直接 `docker run -d --name swss-build ... sleep infinity`
（见 #9）。若必须用 compose：`docker compose -p <独立项目名>` + 先 `docker network rm`
空闲网络。

## 9. swss compose 容器自行退出

**症状**：`docker compose up -d` "成功"但容器很快 Exited；`Error response from daemon:
container ... is not running`。

**根因**：镜像 CMD 是 `sudo service ssh start -D`（前台 sshd），sshd 因缺 host key 等
原因退出 → 容器跟着退。

**修复**：本地镜像（Dockerfile.swss-local）CMD 改为 `sleep infinity`；用常驻容器
`swss-build` + `docker exec`。

## 10. compose run 的命令覆盖陷阱

**症状**：`docker compose run --rm shell -c "cd /workspace && make check"` 报
`exec: "-c": executable file not found`。

**根因**：compose run 后面的参数**整体替换** service 的 `command: ["/bin/bash"]`，
于是容器试图执行字面量 `-c`。

**修复**：写全 `bash -c "..."`。

## 11. Git Bash ↔ wsl.exe 的引号/路径破坏

**症状与修复**（调用约定见 SKILL.md）：
- `/mnt/c/...` 参数被 MSYS 改写 → 前缀 `MSYS_NO_PATHCONV=1`；
- 未加单引号的 `~/...` 被 Git Bash 展开成 `/c/Users/liu/...` → 一律单引号包给 WSL 侧展开；
- 多行 `bash -c '...'` 脚本经 wsl.exe 传递会损坏 → 复杂逻辑写成 .sh 文件执行；
- wsl.exe 中文输出是 UTF-16LE 乱码 → `iconv -f UTF-16LE -t UTF-8`。

## 12. SAI 子模块在 Windows 副本里未初始化

**症状**：sairedis 构建报 `./attrversion.sh: Permission denied`（Error 127）或元数据
生成异常。

**根因**：Windows 工作副本从未 `git submodule update --init`；rsync 只搬来空目录。
子模块在 fix-modes 类脚本处理范围之外时还会叠加 #2 的执行位问题。

**修复**：`sync-from-windows.sh` 内置 `git submodule update --init SAI` +
对 SAI 单独 normalize。（SAI 是完整克隆含 88 个 tag，attrversion.sh 依赖 git tag
历史构建属性版本表——**不要浅化它**。）

## 13. `.artifactignore` 的伪修改

**症状**：git status 恒有 ` M .artifactignore`。

**根因**：纯行尾差异（LF blob vs CRLF 工作区）。无意义，normalize 后消失；
sync 脚本 rsync 时已 exclude。

## 14. 正常基线（用于判断"是否符合预期"）

- sairedis 构建产物：**13 个 .deb**（libsaimetadata/libsairedis/libsaivs 各 3 + dev 2 +
  python3-pysairedis 2 + syncd-vs 2 含 dbgsym）；syncd-vs 内 15 个 usr/bin 二进制。
- sairedis `make check`：23 个套件 PASS / 0 FAIL（syncd 套件 196 用例）。
- swss 构建产物：`swss_1.0.0_amd64.deb`（~5MB）+ `swss-dbg_1.0.0_amd64.deb`（~160MB）。
- swss cargo test：178+188+2+12+4… 全过 0 失败（countersyncd 套件 178）。
- linkmgrd：`make test` 190/190 gtest 全过（ASan + gcovr，~8 分钟），deb `sonic-linkmgrd_1.0.0-1_amd64.deb`。
- dhcpmon：无上游单测，`dpkg-buildpackage` 出 deb 即 CI 等效（~1 分钟）。
- 镜像体积：build-env-build / swss-bookworm-master ≈ 14.5GB；磁盘需留 ~60GB。
- 首次全链路 ~2 小时（含镜像拉取）；日常增量：sairedis 构建 3-10 分钟、
  make check 20-30 分钟、swss 构建 25-40 分钟、swss cargo test 2-4 分钟。

---

以下为 2026-10-25 扩仓适配（swss-common + Python/C++/Go 仓群）新增：

## 15. 容器构建残留 root 属主 → rsync --delete 失败（exit 23）

**症状**：sync-from-windows.sh 在 rsync 阶段报 `delete_file: unlink(...) failed:
Permission denied`，随后 `cannot delete non-empty directory: debian/.debhelper`。

**根因**：sairedis 的 compose 构建以 root 运行，autotools/`.debhelper` 残留为 root
属主；用户 liu 的 rsync 删不掉。config/、autom4te.cache/、debian/.debhelper/ 都会中招。

**修复**：sync 脚本对每仓先 `sudo -n chown -R liu:liu`（已内置）。

## 16. 多 GB Azure 产物下载：-m 600 必死 + 续传会被拒

**症状**：sonic-buildimage.vs 产物（~6GB）每次都在 600 秒被 curl `-m` 掐断
（`Operation timed out ... with N bytes received`）；加 `-C -` 续传反而收到
HTTP 400（签名 URL 对 Range 请求不稳定）。

**修复**：stage-upstream.sh 的 get() 超时改为 `CURL_MAX_TIME` 环境变量，取 vs
产物时用 `CURL_MAX_TIME=2700` 一次拉完（速度 ~4MB/s，约 25 分钟）。不要依赖续传。

## 17. Go 仓构建：go 1.19 读不懂 go.mod "go 1.25.9"

**症状**：mgmt-common `dpkg-buildpackage` 报
`invalid go version '1.25.9': must match format 1.23`。

**根因**：slave 镜像自带 go 1.19.8，且 mgmt-common Makefile 硬编码
`/usr/local/go/bin/go`——光把新 go 放别的目录、改 PATH 没用。

**修复**：`ensure_go125`（lib.sh）——staged 的 go1.25.9 装到 /usr/local/go125 并把
`/usr/local/go` 符号链接指过去（旧 1.19 备份在 /usr/local/go1.19-backup）。
工具链预取在 `~/staged/tools/go`（go.dev 经代理下载）。

## 18. WSL 互操作 PATH 污染容器命令（括号炸 bash -c）

**症状**：docker exec 的 bash -c 报 `syntax error near unexpected token '('`，
错误信息里出现 `Program Files (x86)` 等 Windows 路径。

**根因**：脚本里 `env PATH=...:$PATH` 双引号展开时把 WSL 的 Windows 互操作 PATH
（含空格+括号）拼进了容器内命令行。

**修复**：容器命令永远用**固定 PATH 字面量**（如
`PATH=/usr/local/go125/bin:/usr/local/bin:/usr/bin:/sbin:/bin`），不要插值 $PATH。

## 19. wsl.exe 复杂内联命令的变量吞噬 → normalize_repo 在 `/` 上跑飞

**症状**：`wsl.exe -- bash -c 'for r in A B; do ... "$r" ...; done'` 里 `$r`、`$SONIC_WS`
等**全部展开为空**；`normalize_repo "/"` 于是 `cd /` 成功，git 报
"not in a git directory"，随后 `find /`+`chmod a-x` 以用户权限扫全盘（连带剥掉
~/.local/bin、go 构建缓存、刚编译产物的执行位）。

**根因**：wsl.exe 对 `bash -c '<长脚本>'` 的参数重组不可靠（不同于简单命令）。
本坑与 #11 同源但后果严重得多。

**修复**：**任何带变量/循环/多语句的逻辑一律写成 .sh 文件再 `bash <脚本>` 执行**。
善后：`renormalize-all.sh` 修 git 树执行位；`chmod -R u+x ~/.local/bin`；
`find ~/.cache/go-build -type f -exec chmod a+x {} +`（否则报
`fork/exec ... generator: permission denied`）。

## 20. 编辑正在后台运行的 skill 脚本 → 自读损坏

**症状**：后台任务以怪异方式失败，日志出现
`build-cpp.sh: error reading input file: No data available`。

**根因**：bash 逐块读取脚本文件；对正在执行的脚本做就地编辑会使解释器读到位移
错乱的内容。

**修复**：后台任务运行期间不要编辑它正在执行的脚本；确需改，先等任务结束或复制
成新文件再改。

## 21. sonic-gnmi 的 testdata 69 个删除态 + vendor 需先构建 mgmt-common

**症状 A**：gnmi 测试 `TestGnmiGet` 报
`open ../testdata/COUNTERS:Ethernet68.txt: no such file or directory`。
**根因 A**：Windows 副本 git 暂存区里 69 个 testdata/COUNTERS* 文件处于删除态
（工作区状态基线即如此）；rsync --delete 忠实镜像了删除。
**修复 A**：`scripts/restore-deleted.sh sonic-gnmi`（git checkout HEAD -- 逐个恢复；
注意文件名带冒号，不能手工引号传参）。

**症状 B**：`make all` 报 `ocbinds/schema.go: undefined: Device`。
**根因 B**：gnmi 的 vendor/ 从同级 `../sonic-mgmt-common` 拷贝（go.mod replace），
其中 ocbinds.go 是 mgmt-common **构建期生成**的（translib/ocbinds/ocbinds.go，
ygot 生成器产物）；mgmt-common 没构建过或 vendor 陈旧都会缺符号。
**修复 B**：先跑 `test-gorepo.sh sonic-mgmt-common`（构建+装 deb），gnmi 路径里
`build_mgmt_common_no_test_bins` 之后再 `rm -rf vendor && make all` 强制重 vendor。

**症状 C**：`TestGnoiFileServer/Remove_Success` 报
`remove /mnt/host/tmp/gnoi-remove-success-*.txt: no such file` 且 stat 到文件仍在。
**根因 C**：gNOI 路径翻译（pkg/hostfs.Translate）**只在 /mnt/host 目录存在时**给绝对
路径加 /mnt/host 前缀；上游测试容器没有该目录（翻译为恒等），而本机 swss 构建镜像
带 /mnt/host → 服务端删错路径。（不要试图创建 /mnt/host/tmp 来"修"——方向恰好相反。）
**修复 C**：gnmi 测试前删掉容器里的 /mnt/host（test-gorepo.sh 已内置）。

另：`TestGnmiSubscribeTranslibXfmrIntf` 在本机（16 核）**稳定失败**（3/3 复现），
是产品代码的真实数据竞争，非环境问题：
`gnmi_server/client_subscribe.go:140`（Client.Run 的 defer 写）与 `:272`
（Client.Close 读）对同一字段无同步。上游 2 核 agent 不易触发故 CI 绿。
可择期给上游报 issue/PR。单跑 gnmi 用例需 env.sh 的 DB_CONFIG_PATH 环境
（用 make check_gotest 跑，别裸 go test，否则 redis 连接拒绝假失败）。

## 22. `docker pull` 经代理挂死（ensure_slave_tags 卡数小时）

**症状**：任何调用 ensure_slave_tags 的脚本在开头静默卡住（无输出、无失败）；
`ps` 可见 `docker pull ...master-amd64` 进程挂了几十分钟以上。

**根因**：本机已有该镜像，仅为"刷新"的 pull 经 Clash 到 ACR 会无限挂起；
脚本 `|| true` 只兜失败不兜挂起。

**修复**：ensure_slave_tags（lib.sh）现在**本地存在即跳过 pull**；要强制刷新
`docker rmi` 后再跑（pull 带 300s 超时兜底）。

## 23. 容器重建后 redis 不在 / redis 配置丢失

**症状**：swss-build 重建/重启后，gnmi telemetry 测试 panic
（`Logger_linkToDbNative` cgo panic）、或各种 `Unable to connect to redis`。

**根因**：redis 是容器内服务，容器重建即消失；测试脚本若不显式起 redis 就直接
跑测试即触发。

**修复**：test-gorepo.sh / build-cpp.sh 每次执行都先 `start_redis_unix`（lib.sh）。

## 24. dhcp4relay 的 gtest：AF_PACKET 需要容器能力 + "假死"是 30 秒 join

**症状 A**：`sock.sock_open` 失败（`sock_open` 返回 -1）。
**根因 A**：测试开 AF_PACKET socket，docker 默认无 CAP_NET_RAW（上游 CI agent
特权运行）。
**修复 A**：swss-build 容器带 `--cap-add NET_RAW --cap-add NET_ADMIN`（lib.sh 已内置；
已有容器需 `docker commit` 后重建，见 SKILL.md 环境重建）。

**症状 B**：dhcp4relay-test 看似"死循环"（dpkg-buildpackage 内 R 状态几十分钟）。
**根因 B**：`DHCPCounter_table_test.Start_stop_db_updates` 停线程要等
`DHCP_RELAY_DB_UPDATE_TIMER_VAL`(30s) 的 sleep 结束才 join；整个 68 用例套件
约 2-3 分钟，比直觉慢得多；stdio 重定向时 gtest 输出全缓冲，中途看日志误判为
零输出死循环。
**修复 B**：耐心（或单测 `--gtest_filter=-DHCPCounter_table_test.*`）；
诊断挂点用 skill 的 `diag` 思路：timeout + `--gtest_print_time=0` + 事后 grep。

## 25. 测试容器里的代理与 /sonic/device（Python 仓两类"全军覆没"假象）

**症状 A**：grpc 类测试成片失败
`StatusCode.UNAVAILABLE ... ipv4:172.17.0.1:7890: recvmsg: Connection reset by peer`
（sonic-py-common 的 gnoi_testing 18 败、config-engine 部分、凡起本地 grpc 测试服务器的套件）。

**根因 A**：容器带着 `http_proxy` 跑测试，grpc 客户端遵守该变量，把发往**本地测试
服务器**的连接也路由进 Clash → 被重置。

**修复 A**：pip 装（测试）依赖时带代理，跑 pytest 前去代理：
`env -u http_proxy -u https_proxy pytest ...`（test-pyrepo.sh / test-buildimage-src.sh
已内置）。

**症状 B**：sonic-config-engine 77 败：subprocess sonic-cfggen 退出码 1，或
`os.path.join(...) NoneType`。

**根因 B**：config-engine 的测试设 `CFGGEN_UNIT_TESTING=2`，cfggen 会遍历
`/sonic/device` 并把 MMU profile 文件 `sudo cp` **写进去**（select_mmu_profiles）。
上游环境把 buildimage 的 device/ 挂在 /sonic/device；本地容器没有该路径（只读挂载
也不行——cp 失败）。

**修复 B**：test-buildimage-src.sh 对 config-engine 额外挂载
`-v ~/SONiC/sonic-buildimage/device:/sonic/device`（读写；拷入物 git checkout 可还原）。
修复后 374/374 全过。

## 26. VS 部署：docker cp 成功但容器里看不见文件

**症状**：`docker cp <file> swss:/tmp/...` 退出码 0，但 `docker exec swss ls /tmp/...`
报 No such file；随后 `dpkg -i '/tmp/.../*.deb'`（glob 未展开的原样路径）报
cannot access archive。

**根因**：SONiC 容器的 `/tmp` 是 **tmpfs** 挂载；docker cp 写的是 overlay 可写层
（tmpfs 之下），运行中的容器看不到。另注意：`$(cmd | tail -N)` 的退出码是 tail
的（恒 0），会把这类静默失败整个吞掉——dpkg 实际失败照样走完 restart+冒烟，
只有 md5 对账才暴露「二进制根本没换」。

**修复**：容器内暂存路径用 overlay 层（如 `/vs-verify/`，脚本已内置）；部署命令
的退出码检查**绝不接管道**（`if ! out=$(vssh ...); then`）；scp/docker cp 后各加
一次落位检查（`ls | grep -q .`，注意空目录的 ls 也返回 0）。

## 27. VS 部署：dpkg -i 报依赖错（libhiredis0.14 等）≠ 装不上

**症状**：本地构建的 swss/syncd-vs deb 在 VS 容器里 `dpkg -i` 报
`depends on libhiredis0.14 (>= 0.14.0); however: Package libhiredis0.14 is not installed`。

**根因**：本地构建链是 bookworm slave，VS nightly 镜像是 trixie 基（结构性差异，
非环境错误）。包名跨发行版变了（trixie 只有 libhiredis1.1.0 / so.1），deb 元数据
里的 Depends 按构建环境写成 bookworm 包名。

**修复**：`dpkg -i --force-depends` + **从 swss-build 容器捆绑缺失 so**
（`docker cp swss-build:/usr/lib/x86_64-linux-gnu/libhiredis.so.0.14` 随部署集
放进容器同路径 + ldconfig）。真实 ABI 满足（trixie 其余库更新、向后兼容）。
vs-verify.sh 已自动处理（EXTRA_LIBS 机制），报告注明 bundled so。

## 28. WSL 服务超时假死：VS VM 常驻 + 重型构建 = 内存超卖

**症状**：wsl.exe 报 `Wsl/Service/WSAETIMEDOUT`，WSL 内一切命令超时；重启后
容器全部 "Up 1 second"、dmesg 清零（VM 已重启）。

**根因**：VS VM 常驻 4GB（WSL 上限 15GB）+ build-swss/build-sairedis 的
`-j16` 编译（mock_tests 阶段各 g++ 可达 1GB+）→ swap 抖动 → WSL 服务无响应。
2026-11-09 两次实测：三方并行必崩；仅构建+常驻 VM 也崩。

**修复**：**重型构建前 `run-vs.sh stop`**，构建完再 start 验证（工作流 D 已固化）。
崩了只能 `wsl --shutdown` 硬重置（构建进度丢失，重启后 unless-stopped 容器自回）。

## 29. VS 部署：bookworm 构建链 vs trixie nightly 镜像 = 迁移窗口期结构性边界

**症状**（三组合实验，2026-11-09）：
1. 本地 swss deb 装入 trixie 容器（只捆 libhiredis.so.0.14）→ 冷启动全部
   守护进程统一 `segfault at 0 in libc`（同一偏移，NULL 解引用）。
2. 配套部署 staged libswsscommon/sai 库 → segfault 消失、orchagent 能
   spawn RUNNING（C++ 层兼容），但 orchagent.sh → sonic-cfggen 抛
   `UnicodeDecodeError`（nightly python3-swsscommon 绑定 vs 被换的 C++ 库）。
3. 再配套 staged python3-swsscommon → `ImportError: libpython3.11.so.1.0
   not found`——staged 绑定是 bookworm(3.11) 构建，trixie 容器是 3.13，死路。

**根因**：上游正处 bookworm→trixie 迁移窗口：本地构建链（slave/头文件/
python 绑定/staged 产物）全 bookworm，而 master nightly VS 镜像容器已 trixie。
C++ so 可以捆绑跨发行版搬运，python C 扩展绑定不能跨解释器大版本。

**修复/边界**：无（结构性）。C++ 仓（swss/sairedis）的 VS 整系统验证
**暂停至本地构建链转 trixie**；vs-verify.sh 的 swss/sairedis 路径保留
（机制完整、失败检测真实有效——md5 对账两次抓住假绿），届时只需把
EXTRA_DEBS/EXTRA_LIBS 换成 trixie 配套。host/纯 py 路径（utilities 等）
不受影响，已验证可用。验证尝试污染的 VS 用重置恢复（VS-LAB.md）。
