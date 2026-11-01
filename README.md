# OnePlus 13 (PJZ110) · ColorOS 15.0.0.305 · Linux 6.6.30 容器内核（Tier A + Droidspaces）

在一加 13（PJZ110，ColorOS 15.0.0.305，Android 15）上，用官方 OSS 内核源码
构建一个**能与原厂 vendor 模块完全兼容**、同时能稳定运行
[Droidspaces](https://www.droidspaces.org/) 容器的内核。

- 源码：`OnePlusOSS/android_kernel_common_oneplus_sm8750` @ `03734e3049cb`
- 内核版本：`6.6.30`（刻意去掉 `android15-8`，`uname -r` 是纯主线版本号）
- 构建产物：`Image`、`dist/AK3-*.zip`（AnyKernel3 刷机包）
- `main`：原始 Tier A 基线，保持不动
- `droidspaces`：本分支，增加 ghost patch 与 Droidspaces 所需选项
- 建议标签：`droidspaces-6.6.30-v1`

## 关键设计：只做 ABI 中立的改动

原厂 624 个 `.ko`（`vendor_dlkm` / `system_dlkm` / `vendor_boot` ramdisk）
全部依赖内核导出符号的 **CRC 校验和**。任何改变结构体布局的改动都会让
`insmod` 直接失败，进而导致 WiFi / 蓝牙 / 相机整片不可用。

所以本仓库只增加**不改变任何结构体字节**的选项：

| 选项 | 作用 | 为什么安全 |
| --- | --- | --- |
| `SYSVIPC` `IPC_NS` | System V 共享内存/信号量 | `task_struct` 里 `sysvsem`/`sysvshm` 被移到 KABI 保留槽 6/7/8（`patches/0001`），布局不变 |
| `PID_NS` | 沙箱 PID 命名空间 | 无导出符号变化 |
| `SECURITY_LANDLOCK` | bubblewrap 降级路径 | 仅新增 LSM 钩子 |
| `NETFILTER_XT_MATCH_ADDRTYPE` | NAT 规则常用匹配 | 纯新增模块代码 |
| `POSIX_MQUEUE` `POSIX_MQUEUE_SYSCTL` | Droidspaces 文档 must-have | `ipc_namespace` 的 `mq_queues` 等字段本来就无条件存在 |
| `DEVTMPFS` | 容器 /dev 硬件节点 | 纯文件系统代码，不改核心结构体 |
| `MACVLAN` | 容器独立 LAN IP | 只新增 netdev 类型；**wlan0 驱动是否支持是另一回事** |
| `IP6_NF_NAT` `IP6_NF_TARGET_MASQUERADE` | IPv6 NAT | 纯新增 netfilter 代码 |
| `TMPFS_POSIX_ACL` `TMPFS_XATTR` | 容器 rootfs 权限/xattr | `FS_POSIX_ACL` 原厂已 `=y`，`struct inode` 布局不变 |
| UFW/Fail2ban 组 | `XT_TARGET_REJECT/LOG`、`XT_MATCH_RECENT`、`IP_SET/HASH_IP/HASH_NET`、`XT_SET` | 纯新增 netfilter/ipset 代码 |

下面这些**没有**打开，原因是会动布局或 CRC：

| 选项 | 影响 |
| --- | --- |
| `CGROUP_PIDS` / `CGROUP_DEVICE` | 改变 `CGROUP_SUBSYS_COUNT`、`css_set` / `cgroup` 布局，cgroup 符号 CRC 变 |
| `CFS_BANDWIDTH` | 改变 `task_group` / `cfs_rq` 布局 |
| `NF_TABLES` / `NFT_*` | 改变 `struct net` 布局，`init_net` CRC 变，引用它的模块全挂 |
| `BRIDGE_NETFILTER` | 改变 `sk_buff` 布局 |
| `USER_NS` | ABI 中立，但默认关闭：非 root user namespace 会扩大内核攻击面；Droidspaces 以 root 建容器不需要它 |
| `BBRv3` | `icsk_ca_priv` 104→144、`struct tcp_sock` 每 socket +40B；导出 CRC 可能过，但布局已经变了，不属于“零 ABI 变化” |

`USER_NS` 是这里唯一“ABI 安全但默认不开”的选项。要用 rootless bwrap /
rootless Podman / Flatpak，再单独打开；只用 root 跑 Droidspaces 不需要。

## 四个补丁

1. `0001-sched-kabi-sysvipc-reserve.patch`
   把 `sysv_sem`/`sysv_shm` 从 `task_struct` 中部移到 `ANDROID_KABI_RESERVE(6..8)`，
   使 `CONFIG_SYSVIPC` 开关不再影响结构体大小。
2. `0002-compiler-attributes-counted-by-guard.patch`
   给 `__counted_by` 加一个 `KBUILD_DISABLE_COUNTED_BY` 开关。
3. `0003-genksyms-strip-counted-by.patch`
   **只在 genksyms 预处理时**加上该开关。原厂模块是用 clang 18.0 生成的 CRC，
   它不认识 `__counted_by`；用较新的 clang 重建会把这 5 个 `icc_*` 符号的
   CRC 算成另一个值，导致 WiFi 驱动加载失败。此补丁让 CRC 与原厂一致，
   同时不改变真正的编译选项。
4. `0004-pid-ghost-task-oplus-midas.patch`
   Droidspaces 崩溃的根因修复。OnePlus 的 `oplus_bsp_midas` 在 PID namespace
   里调用 `find_task_by_vpid()`，新 namespace 查不到 PID 时返回 `NULL`，
   模块未检查继续解引用；`PANIC_ON_OOPS=y` + `PANIC_TIMEOUT=-1` 会立刻硬复位。
   补丁在 `kernel/pid.c` 里只对该模块返回一个静态 ghost task（`pid=-1`，
   `comm="ghost-task-sentinel"`），不改结构体、不改导出符号、不改 CRC。

## Droidspaces 支持

在真机 Droidspaces v7.1.0 上实测：

| 检查项 | 状态 |
| --- | --- |
| root、Linux version、PID/mount/UTS/IPC namespace、pivot_root、/proc、/sys、seccomp | ✓ |
| devtmpfs | ✓ |
| macvlan（配置） | ✓（仅内核支持；wlan0 驱动实际返回 EBUSY） |
| IPv6 NAT | ✓ |
| tmpfs POSIX ACL / xattr | ✓ |
| UFW / Fail2ban 组 | ✓ |
| Memory / Swap limit | ✓ |
| CPU limit（`CFS_BANDWIDTH`） | ✗（会动 `task_group` 布局，故意不开） |
| Process limit（`CGROUP_PIDS`） | ✗（会动 cgroup 布局，故意不开） |
| Sandboxing / user namespaces（`USER_NS`） | ✗（ABI 安全，但默认关闭） |

### macvlan 的边界

macvlan 在**有线**接口上才能正常工作，例如 USB-C 以太网适配器的
`eth0` / `usb0`：容器会拿到独立 MAC，向路由器 DHCP 申请独立 LAN IP，
端口直接开在那个 IP 上。

在 `wlan0` 上实测失败：

```text
ip link add link wlan0 name mvtest type macvlan mode bridge
RTNETLINK answers: Device or resource busy
```

`wlan0` 是 `cnss_pci` 的 managed 客户端接口，已关联 AP；驱动不接受额外的
MAC，`EBUSY` 不是内核配置能修的。Droidspaces 界面里的 “Macvlan（有线局域网）”
和“通常是 USB 以太网适配器”就是这个意思。

- 需要独立 LAN IP：用 USB 以太网。
- 只需要容器能被局域网访问：用“主机”模式（端口直接绑手机 `wlan0` IP）
  或 NAT + 端口映射。
- 不要在 `wlan0` 上试 `passthrough`：整个接口给容器，手机自己会断网。

## 原厂模块签名

原厂 `system_dlkm` 的 94 个模块带 PKCS#7 签名，内核用自己的临时密钥签名，
所以默认情况下我们的内核**验不过原厂签名**，模块会被降级成「未验证模块」并
按 `CONFIG_MODULE_SIG_PROTECT` 的白名单规则拒绝加载。

解决办法：把原厂签名证书 `certs/vendor-module-signing.x509` 通过
`CONFIG_SYSTEM_TRUSTED_KEYS` 塞进内核钥匙串。这是原厂公钥，不是私钥。

## 构建

```bash
bash build.sh                   # 全部：下载源码 → 打补丁 → 编译 → 校验 → 打包
JOBS=16 bash build.sh           # 指定并行度
SKIP_AK3=1 bash build.sh        # 只编译内核，不打包 zip
```

### 必须用大小写敏感的文件系统

内核树里 `net/netfilter/xt_DSCP.c`（target）和 `xt_dscp.c`（match）只差大小写。
在 f2fs casefold / exFAT 上解压源码会丢掉其中一个，构建时报：

```text
make[5]: *** 没有规则可制作目标“net/netfilter/xt_DSCP.o”
```

`build.sh` 现在会在开编前检查 `WORK_DIR` / `OUT_DIR` 是否大小写敏感，不敏感
会直接报错。把工作目录放到 ext4 / tmpfs，或先 `chattr -F <dir>`：

```bash
cd /path/to/oneplus13-pjz110-kernel
TOOLCHAIN=/path/to/toolchain \
WORK_DIR=/path/to/case-sensitive/work \
OUT_DIR=/path/to/case-sensitive/out \
SKIP_AK3=1 bash build.sh
```

首次运行会下载约 1.2GB 源码到 `$WORK_DIR/src`（已在 `.gitignore` 中）。

依赖：`clang-18` / `lld-18` / `llvm-18`、`bc` `bison` `flex` `libelf` `libssl`、
`pahole`（dwarves ≥ 1.23）、`python3`、`zip` `patch` `curl` `git`。

`pahole` 不是可选项。缺了它 `olddefconfig` 会把 `CONFIG_DEBUG_INFO_BTF` 关掉，
而该选项同时把 `__user`/`__rcu` 定义成 `btf_type_tag` 属性
（`include/linux/compiler_types.h`），关掉后大量导出符号的 CRC 会变，
原厂模块随即拒绝加载。`build.sh` 在 `olddefconfig` 之后会硬性检查这一项。

如果不想用系统工具链，可以指向一个自己解包的 LLVM + pahole 目录：

```bash
TOOLCHAIN=/path/to/toolchain bash build.sh
```

### ABI 校验

`scripts/verify-abi.py` 会拿编译出的 `Module.symvers` 与
`abi/stock-module-crcs.tsv`（从真机 624 个 `.ko` 反解出来的 5718 个符号 CRC）
逐条比对。

本分支实测：

```text
stock symbols: 5718  built exports: 8129  shared: 3944
  not exported by this build: 1774 (module-to-module only)
ABI OK: every shared symbol CRC matches the stock .305 modules
```

- 3944 个 stock 模块向内核要的符号：CRC **0 mismatch**；
- 1774 个“未导出”符号是模块间符号，已用真机 stock `.ko` 的 `__ksymtab`
  逐个核对：1200 个由 `vendor_dlkm`/`system_dlkm` 提供，574 个由
  `vendor_boot` ramdisk 提供，**0 缺失**。

脚本本身对 1774 个未导出符号只打印、不失败；上面的 0 缺失是额外用
`readelf -sW` 解析 932 个 stock `.ko` 的导出符号得到的，不是脚本的结论。

## 云编译

`.github/workflows/build.yml` 只支持**手动触发**（Actions → Build Tier A kernel
→ Run workflow），不会在 push / PR 时自动跑。

Runner 是 `ubuntu-24.04`，脚本会安装 `clang-18` / `lld-18` / `pahole` 等依赖，
交叉编译出 arm64 的 `Image`，并把 `Image`、`.config`、`Module.symvers`、
AK3 zip 作为 artifact 上传。

## 刷入

1. 从 artifact（或本地 `out/`）取 `Image`。
2. 用 [APatch](https://github.com/bmax121/APatch) 打补丁：App 内“修补 boot 镜像”
   选择原厂 `boot.img`（或本仓库生成的未打补丁 boot），得到 `new-boot.img`。
3. `fastboot flash boot new-boot.img`，或先 `fastboot boot` 试运行。

**注意**：本项目不生成、也不签名 boot 镜像，只提供内核 `Image`。
改动内核后 APatch 的补丁会失效（它打在 boot 内核里），需要重新打补丁。
`boot.img` 通常没有 ramdisk（`RAMDISK_SZ 0`），ramdisk 在 `init_boot`；
只换 `boot` 里的 kernel，不要动 `init_boot`。

## 已验证

- 624 个原厂模块：5718 个被引用符号，3944 个共享 CRC **0 不匹配**；
- 1774 个模块间符号：全部由 stock `.ko` 提供，**0 缺失**；
- 真机启动：`uname -r` = `6.6.30`，原厂模块正常加载；
- Droidspaces v7.1.0：容器创建、启动、终端、systemd 正常，**不再 panic**；
- WiFi / 蓝牙 / 相机等原厂模块正常加载（未逐一做功能回归）；
- `macvlan` 在 `wlan0` 上返回 `EBUSY`，这是 Wi-Fi 驱动限制，不是内核/ABI 问题。

## 不要做的事

- 不要开启 `CONFIG_CGROUP_PIDS` / `CONFIG_CFS_BANDWIDTH` /
  `CONFIG_NF_TABLES` / `CONFIG_BRIDGE_NETFILTER` / `CONFIG_CGROUP_DEVICE`
  —— 会改 cgroup / net / sk_buff 布局，原厂模块 CRC 会失效。
- 不要为了 macvlan 去改内核：`CONFIG_MACVLAN=y` 已经够了；`wlan0` 的
  `EBUSY` 是驱动/固件限制，改配置不会好。
- 不要开 `BBRv3` 还声称“零 ABI 变化”：它会改 `tcp_sock` 布局。要用 BBR，
  保持 mainline BBRv1，运行时 `sysctl` 切：
  `net.core.default_qdisc=fq`、`net.ipv4.tcp_congestion_control=bbr`。
- 不要在 f2fs casefold / exFAT 上直接跑 `build.sh`；用大小写敏感目录。
- 不要用 GCC 构建：`build.sh` 只支持 clang，换成 GCC 的 `.config` 会把
  `CFI_CLANG` 等安全选项悄悄关掉，产出的内核与原厂 ABI 也不再可比。
- 不要在 `LOCALVERSION` 里加 `android15-8` —— 版本号被刻意做成主线风格。

## 分支与版本

| ref | 内容 |
| --- | --- |
| `main` | 原始 Tier A（SYSVIPC/IPC_NS/PID_NS/LANDLOCK/ADDRTYPE），保持不动 |
| `droidspaces` | 本分支：Tier A + ghost patch + Droidspaces 选项 + README |
| `droidspaces-6.6.30-v1` | 建议标签，指向该分支的验证提交 |

## 许可

GPL-2.0（见 `LICENSE`）。内核源码版权归原作者所有。
