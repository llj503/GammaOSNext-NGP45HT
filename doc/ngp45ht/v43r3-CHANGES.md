# v43r3 —— 彻底修掉「刷机后没有 RetroArch 等模拟器」（2026-11-13）

基线：`GammaOSCore-NGP45HT-20261111-v43r2.img`（5,451,564,032 B）
输出：`GammaOSCore-NGP45HT-20261113-v43r3.img`（同尺寸，GPT 分区表逐字不变）

## 一、用户看到的问题

刷 v43 / v43r2 后，系统里**没有 RetroArch、MiXplorer、Aurora Store、PPSSPP、
DraStic、Flycast、M64Plus FZ 这 7 个 apps.list 应用**。v42 及更早版本没有此问题。

11-13 已定位第一层根因，见 `RetroArch-首启缺失-20261113.md`：
v43 引入的 `ngp-fixup.sh` ⓪a-1 在 `sys.boot_completed=1` 后抢先写
`device_provisioned=1` / `user_setup_complete=1`，LineageOS SetupWizard 判定
「已完成」直接退出，`persist.gammaos.setupwizard_run` 永远是 0，init 里的
`gammaossetupwizard` 服务（跑 `/system/bin/setup.sh`）从不启动，7 个 app 一个都不装。
镜像里 APK 与数据包其实一个没少。

**本次重出镜像时又挖出第二层更致命的根因**：`setup.sh` 的 8 个
`extract_archive()` 全部是 `zstd -dc "$archive" | tar -x -P -C /`，而 v42 / v43 /
v43r2 镜像的 `/system/bin`、`/vendor/bin`、两个 toybox 里**根本没有 zstd 二进制**
（离线 `debugfs ls -lR` 等价逐目录核对 + `strings toybox` 均无 zstd）。
也就是说：就算把 `setup.sh` 补跑起来，7 个 APK 会装上，但
`retroarch.tar.zst`（357 MB）、`roms.tar.zst`（175 MB）以及其余 6 个 app 的数据包
**全部解不开** —— RetroArch 仍是个没有核心、没有配置、没有中文字体的空壳。
此前所有"补跑 setup.sh 就行了"的方案（含 11-13 的 rafix OTA 包）都只修了第一层。

更糟的是 `setup.sh` 第 599 行**无条件** `mkdir -p /data/setupcompleted`，
而 `retry_step` 解包失败只 warning 不 abort —— 于是解包全失败也会写下
"完成"标记，开机自愈脚本看到标记就永久跳过，永远不会重试。这是一个会
自动固化失败的陷阱。

## 二、v43r3 的改动（只动 2 个文件）

### 1. p4 新增 `/system/bin/zstd`（1,178,456 B，0755 uid0 gid2000）

- 源码 zstd 1.5.7 官方 tarball（2,434,947 B，从 GitHub release 下载）；
- NDK r27c `aarch64-linux-android29-clang` 静态交叉编译，`HAVE_THREAD=0
  HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0`，`llvm-strip --strip-all`；
- `file` 确认 `ELF 64-bit ARM aarch64, statically linked, for Android 29`，
  `llvm-readelf -l` 无 INTERP（不依赖 bionic 动态加载器）；
- **功能实测**：用 qemu-aarch64-static 7.2.0 跑这个 ARM 二进制，解镜像内的
  `flycast.tar.zst`、`drastic.tar.zst`，输出 tar 的 md5 与宿主 x86 zstd 1.5.7
  逐字节一致；再从**构建好的新镜像**里 `debugfs dump` 出 zstd 重复该测试，
  结果同样一致；
- 不改 `setup.sh` 一个字节、不动 8 个 `.zst`，避免重压缩 530 MB 与 p4 空间风险。

### 2. p5 覆盖 `/bin/ngp-fixup.sh`（959 → 995 行，50,927 B）

- **顺序调整**：⓪a-1（provisioning flags）移到 ⓪a-0 之前。flags 先写好，
  SetupWizard 就不会再启动 `gammaossetupwizard` 服务，⓪a-0 的前台 `setup.sh`
  独占执行，避免两个 `setup.sh` 并发 `pm install` / 同时解同一批 tar；
  旧版把 ⓪a-0 放在 ⓪a-1 之前，恰好留出了这个并发窗口。
- **⓪a-0 保留前台同步补跑** `setup.sh`（`ngp_fixup` 是 oneshot，绝不能放后台，
  v43r2 的固件不播种就是这么踩的），并新增三个兜底：
  1. 先探 `/system/bin/zstd`，缺失就往 `/data/ngp/setup-status.log` 落 `FATAL`；
  2. 跑完用 `pm path` 复查 7 个包，**没齐就删掉 `/data/setupcompleted`**，
     让下次开机以 `FRESH_SETUP=1` 整包重试，绕开 `setup.sh` 的无条件标记；
  3. 结果写 `/data/ngp/setup-status.log`（`OK: 7/7 apps installed` 或
     `INCOMPLETE: missing=...`）。
- **不侵入已完成首启的机器**：`/data/setupcompleted` 存在时一律跳过，只做
  观测日志；用户主动卸载的 app 不会被强行装回来，ROM / 存档不会被重解覆盖。

### 3. OTA 打包脚本同步（`scripts/make_ota_package.sh`）

新增逻辑载荷 `zstd` → `system/bin/zstd 0755 0 2000`，并把它加进 `ALL`。
全量包现在能完整复现 v43r3 的两个改动。

⚠️ 打包时踩过一次：`src_of ngp-fixup.sh` 的候选顺序是
`$NGP_PAYLOAD_DIR/ngp-fixup.sh` 优先于仓库模板，而 `v43-work/payload/` 里
还留着 11-13 上午的旧版（48,883 B / `00dfe140…`），第一次打出来的 OTA 包
manifest 仍是旧 sha。已把 payload 目录同步成仓库新版，重打后 manifest 为
`3deb9b87…6a73`（50,927 B）并逐项实测 sha256。**以后打 OTA 包务必先看
manifest 里的 sha256 是否与当前仓库模板一致**，不能只看"生成成功"。

## 三、构建与字节级验证

`build_v43r3.sh`（可用 `./build_v43r3.sh <base.img> <out.img>` 复现）：
按 GPT 分区名现读 offset → `cp --sparse=always` 基线 → 抽出 p4/p5 到独立镜像 →
`debugfs` 注入 → `e2fsck -fy` 收尾 → 按 offset 写回。
**没有**对 `img?offset=` 直接跑 `resize2fs`（会 ftruncate 掉 p5..p9）。

| 校验项 | 结果 |
|---|---|
| 镜像大小 | 5,451,564,032 B（与基线一致） |
| 裸镜像 md5 / sha256 | `6aec2dab788a47bb17bd08c953cb6737` / `4460c39ff1b9f3e5bb77f9f2dbfa30c8f6b17525a6d8819edc4fd6f9ea62b732` |
| 镜像内 `/system/bin/zstd` | md5 `03b40a0e639ab57e0b5cb285455c8923`，与载荷逐字节一致，0755/0/2000 |
| 镜像内 `/bin/ngp-fixup.sh` | md5 `0ee79847ef6328179ace72d8456a50c7` / sha256 `3deb9b87…6a73`，与仓库模板一致，0755/0/2000 |
| 4 MiB 分块硬比对 | **差异 10 块：p4=6、p5=4，范围外 0** |
| GPT | `sgdisk -v` → `No problems found`；`sgdisk -p` 与基线逐字一致 |
| 首启素材 | p4 `/system/etc` 17 项 `.zst` / `.apk` / `apps.list` 尺寸与基线一致 |
| 未改动文件 | `/system/bin/setup.sh`、`/bin/ngp-ota.sh` 与基线 `cmp` 完全一致 |
| 权限 | 两个注入文件均 `Mode: 0755 User: 0 Group: 2000` |

脚本自身验证：`sh -n` / `bash -n` 通过；⓪a 段沙盘跑了 4 个场景并全部符合预期：
A 首启成功 → 7/7、标记保留；B 解包失败但 setup.sh 仍建标记 → 识别为
INCOMPLETE、删标记待重试；C 已完成机器用户卸载 1 个 app → 不干预、不重解 ROM；
D 缺 zstd → 落 FATAL 告警。

## 四、刷机后的实际行为

**直接刷 v43r3 镜像（推荐）**：第一次开机 `ngp_fixup` 的 ⓪0 段没有 OTA 包直接跳过，
⓪a-1 写 provisioning flags，⓪a-0 检测 `/data/setupcompleted` 缺失 → 前台跑
`setup.sh`，装 7 个 APK + 解包约 530 MB，**开机过程约 3~8 分钟**（屏幕常亮，
不要断电、不要拔卡），之后继续输入法 / 桌面 / RetroArch 简体中文与字体等收尾段。
**只重启一次**（就是这次开机），不需要连重启两次。

**已刷 v43 / v43r2 不想重刷整卡**：用 `OTA/v43r3-upgrade-OTA.zip`
（541,108 B，包名 `update-20261113-v43r3`，含新版 `ngp-fixup.sh` + `zstd`）。
它会重启**两次**：第 1 次应用 OTA 并自动重启，第 2 次新脚本才补跑 `setup.sh`。
安装前务必把 `/sdcard/OTA/` 下所有旧的 `update-*` 目录移走 —— 应用器每次只取
第一个待处理包。包内 README 有完整步骤。
⚠️ 11-13 早些时候的 `v43-seedfix-OTA.zip` / `v43r2-rafix-OTA.zip` **不含 zstd**，
只能修第一层根因，不要再用来修这个问题；它们保留在原处不删不改。

## 五、验证命令（真机）

```bash
adb shell pm path com.retroarch.aarch64          # package:/data/app/.../base.apk
adb shell cat /data/ngp/setup-status.log         # OK: 7/7 apps installed
adb shell tail -30 /data/data/org.lineageos.setupwizard/files/gammaos_setup.log
adb shell ls /sdcard/Android/data/com.retroarch.aarch64/files/retroarch.cfg
adb shell cat /sdcard/Android/data/com.retroarch.aarch64/files/retroarch.cfg | grep user_language
```

`setup.log` 里不应再出现 `zstd: not found` 或 `extracting ... failed`。

## 六、已知限制 / 待真机复核

1. 构建时 `adb devices` 为 `no devices`，**真机刷机验证尚未做**。所有结论来自
   离线 debugfs 取证、qemu 端到端解压、脚本沙盘与字节级镜像比对。
2. `/system/bin/zstd` 没有 `security.selinux` xattr：`debugfs ea_set` 不会补
   SELinux label 要求的结尾 NUL（26 字节），留 25 字节的坏 label 不如不留，
   构建脚本已自动 `ea_rm`。这与 v43 已验证可执行的 `/bin/ngp-ota.sh` 一致，
   本机 `userdebug` + SELinux permissive 下可执行；若真机是 enforcing 且报权限
   错误，需要补 label 或把 zstd 改放到 `/vendor/bin`。
3. `setup.sh` 由 `ngp_fixup`（`u:r:shell:s0`）前台调用，而非 init 原本的
   `u:r:gammaossetupwizard:s0`。permissive 下 `pm install` / `chown` / `pm grant`
   应无碍，仍建议真机复核一次。
4. 首次开机会前台占用 `ngp_fixup` 数分钟，期间默认桌面 / 输入法 / 显示方向等
   收尾段尚未执行，属预期（上游 SetupWizard 本来也要这几分钟）。
5. GitHub Release / 百度盘上传**未执行**，等用户确认；相关脚本尚未生成。

## 七、离线素材与复现

| 文件 | 位置 |
|---|---|
| 构建脚本 | `/home/liang/rainject/build_v43r3.sh` |
| zstd 载荷 | `/home/liang/rainject/v43-work/payload/zstd-aarch64-static` |
| 首启脚本模板 | `device/ngp45ht/ime/ngp-fixup.sh` |
| OTA 打包脚本 | `device/ngp45ht/scripts/make_ota_package.sh` |
| 升级 OTA 包 | `gammaosnext-port-analysis/OTA/v43r3-upgrade-OTA.zip` |
| 构建日志 | `/home/liang/rainject/v43-work/build-v43r3.log` |

zstd 载荷的编译命令（如需重编）：

```bash
curl -fLO https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
tar xf zstd-1.5.7.tar.gz && cd zstd-1.5.7
CC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang \
  make -j8 -C programs zstd CC="$CC" HAVE_THREAD=0 HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 \
  CFLAGS="-O2 -static" LDFLAGS="-static"
$NDK/.../llvm-strip --strip-all programs/zstd -o zstd-aarch64-static
```
