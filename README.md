# OnePlus 13 (PJZ110) · ColorOS 15.0.0.305 · Linux 6.6.30 容器内核

在一加 13（PJZ110，ColorOS 15.0.0.305，Android 15）上，用官方 OSS 内核源码
构建一个**能与原厂 vendor 模块完全兼容**、同时具备容器/命名空间能力的内核。

- 源码：`OnePlusOSS/android_kernel_common_oneplus_sm8750` @ `03734e3049cb`
- 内核版本：`6.6.30`（刻意去掉 `android15-8`，`uname -r` 看起来是纯主线版本号）
- 构建产物：`Image`、`dist/AK3-*.zip`（AnyKernel3 刷机包）

## 关键设计：只做 ABI 中立的改动

原厂 624 个 `.ko`（`vendor_dlkm` / `system_dlkm` / `vendor_boot` ramdisk）
全部依赖内核导出符号的 **CRC 校验和**。任何改变结构体布局的改动都会让
`insmod` 直接失败，进而导致 WiFi / 蓝牙 / 相机整片不可用。

所以「Tier A」配置只增加**不改变任何结构体字节**的选项：

| 选项 | 作用 | 为什么安全 |
| --- | --- | --- |
| `SYSVIPC` `IPC_NS` | System V 共享内存/信号量 | `task_struct` 里 `sysvsem`/`sysvshm` 被移到 KABI 保留槽 6/7/8（`patches/0001`），布局不变 |
| `PID_NS` | 沙箱 PID 命名空间 | 无导出符号变化 |
| `SECURITY_LANDLOCK` | bubblewrap 降级路径 | 仅新增 LSM 钩子 |
| `NETFILTER_XT_MATCH_ADDRTYPE` | NAT 规则常用匹配 | 纯新增模块代码 |

「Tier B」（`CGROUP_PIDS` / `CGROUP_DEVICE` / `USER_NS`）会让 `css_set`、
`cgroup` 等结构体膨胀，实测改动 **12 个导出符号的 CRC**，原厂模块会拒绝加载。
本仓库刻意**不做**这些改动 —— 这也是 Docker 在这台机器上跑不起来的原因。

## 三个补丁

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

首次运行会下载约 1.2GB 源码到 `.cache/`（已在 `.gitignore` 中）。

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

`scripts/verify-abi.py` 会拿编译出的 `Module.symvers` 与
`abi/stock-module-crcs.tsv`（从真机 624 个 `.ko` 反解出来的 5718 个符号 CRC）
逐条比对，任何一条不一致都会让构建失败。这一步是防止「编出来了但刷上去没 WiFi」。

## 云编译

`.github/workflows/build.yml` 只支持**手动触发**（Actions → Build Tier A kernel
→ Run workflow），不会在 push / PR 时自动跑。

Runner 是 `ubuntu-24.04`，脚本会安装 `clang-18` / `lld-18` / `pahole` 等依赖，
交叉编译出 arm64 的 `Image`，并把 `Image`、`.config`、`Module.symvers`、
AK3 zip 作为 artifact 上传。

## 刷入

1. 从 artifact（或本地 `dist/`）取 `Image`。
2. 用 [APatch](https://github.com/bmax121/APatch) 打补丁：App 内「修补 boot 镜像」
   选择原厂 `boot.img`（或本仓库生成的未打补丁 boot），得到 `new-boot.img`。
3. `fastboot flash boot new-boot.img`，或先 `fastboot boot` 试运行。

**注意**：本项目不生成、也不签名 boot 镜像，只提供内核 `Image`。
改动内核后 APatch 的补丁会失效（它打在 boot 内核里），需要重新打补丁。

## 已验证

- 624 个原厂模块：5718 个被引用符号，**0 CRC 不匹配，0 未解析**
- `uname -r` = `6.6.30`，`same_magic()` 在模块带 CRC 时跳过版本号首段，不影响加载
- 真机启动：WiFi / 蓝牙 / 传感器 / NFC / GPS 全部正常
- bubblewrap 沙箱可用（Landlock 部分生效，因为内核 ABI 版本低于 bwrap 期望）

## 不要做的事

- 不要开启 `CONFIG_CGROUP_PIDS` / `CONFIG_CGROUP_DEVICE` / `CONFIG_USER_NS`
  或任何其它会改动 `css_set` / `cgroup` / `task_struct` 布局的选项 —— 会让原厂模块 CRC 失效。
- 不要用 GCC 构建：`build.sh` 只支持 clang，换成 GCC 的 `.config` 会把
  `CFI_CLANG` 等安全选项悄悄关掉，产出的内核与原厂 ABI 也不再可比。
- 不要在 `LOCALVERSION` 里加 `android15-8` —— 版本号被刻意做成主线风格。

## 许可

GPL-2.0（见 `LICENSE`）。内核源码版权归原作者所有。
