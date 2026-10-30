# Android 11 / 5.4（ACK android11-5.4）适配说明

本文记录 `tmp/boot.img`（5.4.281-qgki / Android 11）的适配内容与构建方法。

> 说明：KO 是按**内核版本**（major.minor）选择的，不是按 Android 版本。
> 如果设备系统是 Android 14、但内核仍是 5.4（boot.img 里 `os_version`
> 可能还是旧的 11.0.0），`read_device_versions()` 会得到 `(14, 5, 4)`，
> `select_ko_image()` 的 fallback 仍会选中 `{11, 5, 4}` 这一项，所以 5.4
> 的 KO 依然需要。minSdk=32 对 Android 14（API 34）没有影响。

## 1. 目标镜像

| 项目 | 值 |
|---|---|
| boot header | v3（`ANDROID!`，header_size=1580） |
| kernel | 偏移 `0x1000`，44,661,248 字节，未压缩 ARM64 Image |
| ramdisk | 偏移 `0x2A98A00`，821,088 字节（`init`、`fstab.qcom`、q/r/s GSI AVB key） |
| 内核 | `5.4.281-qgki-g4273d6fd2de9`，clang 11.0.2 (r383902b)，`#1 SMP PREEMPT Mon Mar 2 11:59:24 CST 2026` |
| Android | 11.0.0（`os_version=0x16000182`） |
| 关键配置 | `CONFIG_XFRM=y`、`CONFIG_INET_ESP=y`、`CONFIG_MODVERSIONS=y`、`CONFIG_MODULE_SIG` 未启用、`CONFIG_STATIC_USERMODEHELPER=y`（路径 `/system/bin/vivo_coredump`）、`CONFIG_CFI_CLANG=y`、`CONFIG_LTO_CLANG=y`、`CONFIG_SHADOW_CALL_STACK=y`、`CONFIG_KALLSYMS_ALL=y` |

## 2. 已从 boot.img 验证的内核事实

- **DirtyFrag 原语仍在**：`esp_input` 保留 5.4 的 `skip_cow` 快速路径（非 cloned、无 frag_list 时跳过 `skb_cow_data`），AEAD 请求 `src == dst`，原地解密到 skb 的 frag；`udp_sendpage → ip_append_page` 的零拷贝路径也在。
- **KO 需要的符号都存在**（kallsyms）：`kallsyms_lookup_name`、`module_kallsyms_lookup_name`、`aarch64_insn_patch_text`、`selinux_state`、`avc_has_perm`、`avc_has_perm_noaudit`、`kern_path`、`invalidate_inode_pages2`、`path_put`、`call_usermodehelper_setup/exec`。
- `selinux_state` 在 5.4 是 `struct selinux_state`；本内核 `CONFIG_SECURITY_SELINUX_DEVELOP=y`、`CONFIG_SECURITY_SELINUX_DISABLE` 未启用，所以首字节就是 `enforcing`，KO 里 `WRITE_ONCE(*selinux_state, false)` 仍然有效。
- `CONFIG_STATIC_USERMODEHELPER` 的路径覆盖发生在 `call_usermodehelper_setup()` 内部；`lkm/dfroot.c` 在 setup 之后改写 `sub_info->path`，因此仍然能执行 `/system/bin/sh`（不是 `/system/bin/vivo_coredump`）。
- `CONFIG_MODULE_SIG` 未启用 → 未签名模块可以加载；但 `CONFIG_MODVERSIONS=y` → 模块必须带**与设备内核一致**的符号 CRC。

## 3. 代码改动

| 文件 | 改动 |
|---|---|
| `app/src/main/jni/exp.c` | 新增 `DFROOT_KO_5_4` 条件编译：`ko/dfroot-android11-5.4.ko` 的 `.incbin`、`dfroot_ko_11_5_4_start/end` 声明、`select_ko_image()` 里的 `{11, 5, 4, ...}` 表项 |
| `app/src/main/jni/CMakeLists.txt` | 检测 `ko/dfroot-android11-5.4.ko` 是否存在；存在时加入 `KO_FILES` 并给 `dfroot` 定义 `DFROOT_KO_5_4=1` |
| `Makefile` | 新增 `KMI_5_4`/`KO_5_4` 与 `ko-5.4` 目标（`KDIR` 指向内核树） |
| `lkm/Makefile` | `DFROOT_KO_5_4=1` 时改用 `--strip-debug`（`--strip-unneeded` 会剥掉没人引用的 `__cfi_check` 符号），并打印符号表 |
| `lkm/build-5.4.sh` | 独立的 5.4 KO 构建脚本（检查 `.config`/`Module.symvers`/`UTS_RELEASE`，构建后校验 vermagic），同样用 `--strip-debug` |
| `.github/workflows/build-lkm-5.4.yml` | 配置步骤显式关闭 `CFI_CLANG`/`CFI_CLANG_SHADOW`/`LTO`；构建步骤传 `DFROOT_KO_5_4=1`，并校验 vermagic 与 `__cfi_check` 是否存在 |

`lkm/dfroot.c` 需要两处 5.4 专属改动，原因见下节。

## 3.1 5.4 内核的强制 CFI（必须处理）

设备内核是 ACK `android11-5.4` 血统，**开启且强制** CFI：

```
CONFIG_CFI_CLANG=y
CONFIG_CFI_CLANG_SHADOW=y
# CONFIG_CFI_PERMISSIVE is not set      ← 不是宽容模式，失败即 panic
CONFIG_LTO_CLANG=y / CONFIG_THINLTO=y
```

内核侧的加载路径（`kernel/module.c` + `kernel/cfi.c`，与 ACK android11-5.4 一致，
符号与反汇编均已核对）：

```c
/* kernel/module.c: cfi_init() —— 加载时执行 */
mod->cfi_check = (cfi_check_fn)find_kallsyms_symbol_value(mod, "__cfi_check");
cfi_module_add(mod, module_addr_min, module_addr_max);

/* kernel/cfi.c: cfi_slowpath_handler() —— 每次 CFI 检查失败后执行 */
check = find_module_cfi_check(ptr);      /* 命中模块 -> mod->cfi_check */
if (likely(check))
    check(id, ptr, diag);
else
    handle_cfi_failure(ptr);             /* panic("CFI failure (target: %pS)") */
```

而 `do_one_initcall()`（真正调用 `mod->init` 的地方）在调用前会做 CFI 检查：
目标地址不在内核 `.cfi_jt` 跳转表范围内就跳 `__cfi_slowpath`。模块的函数必然
落在模块地址空间，所以**每次进入模块的 CFI 检查都会走 slowpath**。

结论：**模块必须导出名为 `__cfi_check` 的符号**，否则 `mod->cfi_check` 为 NULL，
加载时（第一次调用 `mod->init`）就 panic：

```
CFI failure (target: %pS)
```

本模块**不用** `-fsanitize=cfi` 编译（原因：公开 5.4.281 树只能用现代 clang 构建，
而现代 clang 已移除老式 CFI sanitizer；且必须与设备那套 clang-11 的类型 ID 哈希
完全一致才有意义）。因此 `lkm/dfroot.c` 在 `DFROOT_KO_5_4` 下做两件事：

1. `#ifndef __nocfi` / `#define __nocfi`：mainline 5.4 没有 `include/linux/cfi.h`，
   `__nocfi` 未定义（5.10+ 才定义为 `__attribute__((no_sanitize("kcfi")))`）；
2. 提供一个**空实现**的 `void __cfi_check(uint64_t, void *, void *)`，占住内核按名字
   查找的符号位，让 slowpath 放过这个未插桩的模块而不是 panic。

> 注意：因为该符号无人引用，`objcopy --strip-unneeded` 会把它剥掉，所以 5.4 的
> 构建路径改用 `--strip-debug`（保留符号表）。

## 4. 构建 KO

前提：

1. **内核树**：与设备一致的 5.4 源码（vivo/Qualcomm BSP，或 ACK `android11-5.4` 对应 commit `4273d6fd2de9`）。
2. **配置**：用 boot.img 里 IKCONFIG 解出的 `.config` 配置该树（`tmp/kernel.config`）。
3. **Module.symvers**：必须是同一棵树构建产生的（`CONFIG_MODVERSIONS=y` 必需）；没有它，模块加载会报 `disagrees about version of symbol`。
4. **工具链**：clang-r383902b（11.0.2）+ LLD，`LLVM=1`；与设备内核一致，避免 CFI/SCS 不兼容。

```sh
# 在 Linux 构建机（或 podman/容器）里：
KDIR=/path/to/android11-5.4 ./lkm/build-5.4.sh
# 等价于：
make ko-5.4 KDIR=/path/to/android11-5.4
```

脚本会：

- 校验 `$KDIR/.config`、`include/generated/utsrelease.h`、`Module.symvers`；
- 打印内核 release，并警告是否 5.4；
- `make -C $KDIR M=lkm ARCH=arm64 LLVM=1 modules`；
- 用 objcopy 去掉 `.BTF`/`.comment` 等段；
- 校验模块 vermagic 是否包含 `$REL`；
- 拷贝到 `app/src/main/jni/ko/dfroot-android11-5.4.ko`。

之后重新 `make` 构建 APK，CMake 会自动嵌入该 blob 并定义 `DFROOT_KO_5_4`。

## 5. 预期 vermagic

设备内核的 vermagic 形如：

```
5.4.281-qgki-g4273d6fd2de9 SMP preempt mod_unload modversions aarch64
```

模块的 `UTS_RELEASE` 必须完全一致。若内核树用 `CONFIG_LOCALVERSION_AUTO=y`，git 状态会再追加 `-g<sha>`；构建前建议：

```
CONFIG_LOCALVERSION="-qgki"
CONFIG_LOCALVERSION_AUTO=n
```

并保证源码 commit 是 `4273d6fd2de9`（或手工把 `CONFIG_LOCALVERSION` 设为 `-qgki-g4273d6fd2de9`）。

## 6. 常见失败与排查

| 现象（dmesg / insmod） | 原因 | 处理 |
|---|---|---|
| `disagrees about version of symbol X` | 模块 CRC 与设备内核不一致 | 用设备同源内核树的 `Module.symvers` 重新构建 |
| `version magic '...' should be '...'` | vermagic/`UTS_RELEASE` 不一致 | 对齐 `CONFIG_LOCALVERSION`/commit/编译器 |
| `CFI failure (target: %pS)` → 内核 panic | 模块没有导出 `__cfi_check`，`mod->cfi_check` 为 NULL | 见 3.1：确认用 `DFROOT_KO_5_4=1` 构建、`--strip-debug` 保留符号 |
| `invalid module format` | 架构/ABI/CFI 不匹配 | 用 clang-r383902b、`LLVM=1`、`ARCH=arm64` |
| 加载成功但 dmesg 无 `dfroot: selinux_state permissive` | 符号解析失败或布局不一致 | 检查 `kallsyms_lookup_name` 是否可用、`selinux_state` 偏移 |
| `dfroot: usermodehelper symbols missing` | 符号未导出/名字变化 | 检查 `call_usermodehelper_setup/exec` |

## 7. 风险与未验证项

- 没有 vivo 官方内核源码时，用 ACK `android11-5.4` + 设备 `.config` 构建的模块，struct 布局与 CRC 可能仍有差异；需要真机 `insmod` 验证。
- CFI 是被**显式绕过**的：模块未插桩，只提供一个空的 `__cfi_check` 让内核不 panic。
  这是刻意的取舍（本工具本身就在改内核代码），但若换用 clang ≤16 且能对齐类型 ID
  哈希，更「正确」的做法是带 `-fsanitize=cfi -flto=thin` 编译，让 clang 生成真正的
  `__cfi_check` 与 `.cfi_jt`。
- 该设备有 `CONFIG_STATIC_USERMODEHELPER`（vivo 加固），KO 通过 setup 后改写 `path` 绕过；若厂商后续把覆盖点移到 `call_usermodehelper_exec`，此绕过会失效。
- 设备可能还有额外的 LSM/DEFEX 类保护；KO 目前只处理 Samsung DEFEX 与 OPPO/OnePlus 的钩子。
- 本次适配在 Windows 工作区完成，环境没有 ARM64 内核工具链，因此**没有实际编译出 .ko**；需要用上面的 Linux 构建流程产出。

## 8. 无厂商源码时构建 KO（vivo PD2141 / V2141A）

实测设备：vivo **PD2141 / V2141A**，系统 Android 14（`UP1A.231005.007`、`PD2141_A_9.10.2`），vendor 分区 Android 11（所以 `ro.vendor.build.version.release=11`），内核 `5.4.281-qgki-g4273d6fd2de9`，bootloader 锁定、SELinux Enforcing、`CONFIG_MODVERSIONS=y`、`CONFIG_MODULE_SIG` 未启用。

boot.img 的 IKCONFIG 与设备 `/proc/config.gz` 逐行一致，可以直接用 boot.img 的配置。没有 vivo 源码时，用公开的 `linux-5.4.281` + 设备配置构建，并把**设备内核自己的导出符号 CRC** 作为 `Module.symvers`：

| 文件 | 说明 |
|---|---|
| `lkm/configs/v2141a-5.4.config` | boot.img 里解出的设备配置 |
| `lkm/symvers/v2141a-5.4.symvers` | 从 boot.img 内核镜像提取的 13,543 个导出符号 CRC（含 `module_layout=0xb7b3a75c`、`register_kprobe`、`printk`、`__stack_chk_fail`） |
| `.github/workflows/build-lkm-5.4.yml` | 下载 `linux-5.4.281` + `clang-r383902b`，用设备配置 + 设备 CRC 构建 KO 并上传 artifact |

CRC 提取方法（`__ksymtab` 在文件里是 0，启动时由 `.rela.dyn` 重定位；`__kcrctab` 是并行的 u32 表）：

1. 在镜像里找 24 字节步长的 `R_AARCH64_RELATIVE` 重定位表；
2. 用 `r_offset - 0xffffffc010080000` 把 `__ksymtab` 每个 entry 的 name 指针（+8 槽）还原成文件偏移；
3. 按 entry 索引与 `__kcrctab` / `__kcrctab_gpl` 配对，得到 name → CRC。

用法：fork → Actions → **Build 5.4 LKM (vivo PD2141)** → Run workflow；下载 `dfroot-android11-5.4` artifact，把 `dfroot.ko` 放到 `app/src/main/jni/ko/dfroot-android11-5.4.ko`，再跑正常的 Build 工作流出 APK。

风险：公开 5.4.281 的 struct 布局与 vivo/Qualcomm 内核可能有差异；CRC 已对齐，但 `struct module` 等布局仍需真机 `insmod` 验证（预期 dmesg 出现 `dfroot: selinux_state permissive`、`dfroot: usermodehelper_exec returned 0`）。
