# NGP45HT（Xifan NGP45H / RK3562）GammaOSNext 移植

把 GammaOS Next（LineageOS 21 / Android 14 GSI）移植到 **Xifan NGP45H** 掌机的全部改动。
基础镜像为 RG52mini 版（`GammaOSCore-RG52Mini-20261008-2036.img`），交付镜像
`GammaOSCore-NGP45HT-20261015-v3.img`（5,451,564,032 B，md5 `03951a3bb01135aa057b306c2e6f281b`）。

## 1. 硬件档案（SSH 实测取证）

| 项目 | NGP45HT | RG52mini（基线） |
|---|---|---|
| SoC | RK3562（4×A55 + Mali-G52 + NPU），2GB RAM | 同 |
| 底板 | Rockchip RK3562 EVB1 LP4X V10 参考设计，UDT 掌机化 DTS | 同 |
| 屏 | **DSI 1024×768@60**（51.6MHz，4 lane RGB888），simple-panel-dsi，init-sequence 在 DTB 内 | 640×480 竖屏 |
| 输入 | **micro-gamepad**（双摇杆 ADC + 4 ADC 键 + 17 GPIO 键 + 震动马达）+ adc-keys（音量±/静音/返回）+ rk805-pwrkey，**无触摸** | 同左 |
| 音频 | rk817 codec/battery/charger；背光 pwm 256 级；HDMI；uboot-charge 动画 | 同 |
| WiFi | **AIC8800DC，USB 接口**（usb 3-1）。DT 里 `wifi_chip_type="ap6275s"` 是 EVB 遗留，不生效 | AIC8800D80（SDIO） |
| USB | DWC3 dr_mode=otg（dArkOS 基础 DTB） | host |

DTB 基础取自用户自建 `dArkOS_ngp45ht_trixie_20261013` 镜像内的 `rk3562-ngp45ht.dtb`
（内核同为 5.10.226、手柄驱动同为 mamaich 树内置 play_joystick、面板 init-sequence 与
EmuELEC 档逐字节一致、rk817 齐全），无需移植 micro-gamepad 驱动。

## 2. 目录内容

```
device/ngp45ht/
├── README.md                      本文
├── boot/
│   ├── rk3562-ngp45ht.dtb         预编译 DTB（149,224 B，md5 3c5f6fe2…，与镜像 FAT 分区内一致）
│   └── extlinux.conf              dArkOS u-boot 启动项（FAT 分区 /extlinux/extlinux.conf）
├── kernel-patches/                内核改动（基于 mamaich/kernel_rk3562_rg52mini @ 225c0ee0e）
│   ├── rk3562-ngp45ht.dts         新 DTS 完整源码（718 行，直接拷入内核树即可）
│   ├── 0001-rk3562-ngp45ht-build.patch   Makefile +1 行、rk3562-darkos.dtsi +2 label
│   ├── 0002-rk3562-joystick-ngp45ht.patch  rk3562-joystick.c +98/-26（dArkOS 仓库补丁 0001）
│   └── 0003-rk3562-ngp45ht-dts.patch      新 DTS 的 git 格式补丁（与上面 .dts 二选一）
├── keylayout/                     system 分区 /system/usr/keylayout/ 覆盖（3 个，字节级已验证）
│   ├── adc-keys.kl
│   ├── retrogame_joypad.kl
│   └── rk3562-joystick.kl
├── system/
│   └── build.prop.patch           横屏修正：ORIENTATION_90→0、fixed_rotation 1→0
├── wifi/                          AIC8800DC USB WiFi 修复（详见 §5）
│   ├── aic_load_fw_usb.ko         493,488 B
│   ├── aic8800_fdrv_usb.ko        2,898,192 B
│   ├── wifi_pick.sh.patch         vendor/bin/wifi_pick.sh 两行 insmod 改动
│   ├── firmware-aic8800/          21 个固件文件 → /vendor/etc/firmware/aic8800/
│   ├── rg52-wifi-fix.rc           开机部署声明（v4，详见 §8）
│   ├── rg52-wifi-fix.sh           一次性加固：WiFi 设置 + 输入法 + USB 电源管理（0755）
│   └── rg52-wifi-watchdog.sh      常驻看门狗：驱动假死自动重载（0755）
├── retroarch-zh/                  RetroArch 简体中文预置（详见 §6）
│   ├── retroarch.cfg              114,828 B（设备端验证配置，含四项字体键 + user_language=12）
│   ├── zh-CN.ttf                  CarroisGothicSC，40,356 B
│   ├── rg52-retroarch.rc          /vendor/etc/init/ 开机部署触发
│   └── rg52-retroarch-zh.sh       /vendor/bin/ 幂等部署脚本（0755）
└── scripts/
    ├── build_kernel.sh            内核+DTB 一键构建（aarch64 交叉工具链）
    └── patch_system.sh            ext4 分区离线注入（keylayout，免 root/loop）
```

## 3. 内核构建

工具链：`aarch64--glibc--stable-2024.02-1`（bootlin），主机侧依赖用 hostdeb。

```bash
# 1. 打补丁（在 mamaich/kernel_rk3562_rg52mini 树内）
cp kernel-patches/rk3562-ngp45ht.dts arch/arm64/boot/dts/rockchip/
patch -p1 < kernel-patches/0001-rk3562-ngp45ht-build.patch
patch -p1 < kernel-patches/0002-rk3562-joystick-ngp45ht.patch
# 2. 构建（见 scripts/build_kernel.sh）
make rg52mini_defconfig && make -j16 Image dtbs
# 产物：arch/arm64/boot/Image、arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb
```

LOCALVERSION=`-ngp45ht`。构建产物 Image 30,136,328 B、DTB 149,224 B。

## 4. 镜像组装演进（基线 RG52Mini-20261008-2036）

| 版本 | 改动 | 分区 |
|---|---|---|
| v1 | Image/DTB/extlinux.conf 替换 + 3 个 keylayout | Fat、system |
| v2 | + WiFi USB 模块对 + wifi_pick.sh + 固件 + build.prop 横屏 | vendor、system |
| v3 | + RetroArch 中文字体四件套（vendor 暂存 + 开机部署） | vendor |
| v4 | + WiFi 防假死三件套（USB 电源管理 + 看门狗 + 输入法固化） | vendor |
| v5 | + 关机 panic 修复（`mmc_sd_shutdown` 空指针） | Fat |
| v6 | 底座换上游 v1.10，全量重做 | 全部 |
| v7 | + 方向键修补 + 软键盘启用 | system、vendor |
| v8 | + nano 画面翻转修正 + su + 联网验证国内化 | vendor |
| v9 | + 性能悬浮窗（statd + APK） | vendor |
| v10 | + ABXY swap 只换 A/B（gammapad 表补丁） | vendor |
| v11 | + 悬浮窗电池功率、帧率修复 | vendor |
| v12 | + 悬浮窗 CPU 占用率、内存占比 | vendor |
| v13 | + 悬浮窗前台服务、桌面开关图标 | vendor |
| v14 | + nano 方向 `rev_landscape` | vendor |
| v15 | + 方向键四向 HAT 化（内核）、鼠标落点分辨率同步 | Fat、system、vendor |
| v16 | + 全新刷机方向修正：logo.bmp 改横版、删 fbcon=rotate、build.prop 给死 nano 方向、gammapad 重启去竞态 | Fat、system、vendor |
| v17 | 以 v13 卡 1:1 为底座重建（v16 开机重启翻车后回退），唯一改动是脚本去掉常驻看门狗 | vendor |
| v19 | + 三项 build.prop 出厂默认值：`drm_flip_v=0` / `rotate.enabled=0` / `abxy_swap=1` | system |
| v20 | + 脚本末尾加 `wm set-ignore-orientation-request`（界面转 180° 的真正解法） | vendor |
| v21 | 把上面那条 `wm` 从脚本末尾（`sleep 70` 之后）移到开头，翻转窗口 75s → 58s | vendor |
| v22 | + 性能悬浮窗开机不自启（`pm disable .BootReceiver`）、statd 改按需采样 | vendor |
| v23 | + 方向锁改用 `wm fixed-to-user-rotation enabled`（修好 nano 正常但进游戏翻转） | vendor |
| **v24** | **+ fstab 补上第二个 TF 卡槽的 `voldmanaged=sd:auto`（此前插卡完全不识别）** | **vendor** |
| v25 | + HDMI 出图（RK628D：`&rgb` 的 vo-pins + 禁 `&i2c4` 控制器本身）、DTB 去掉上游遗留的 rg52mini | Fat |
| v26 | + Nintendo 3DS：`azahar-nano`/`AzaharSf` 进 system，38 MB core 与 4 个 AdrenoTools hook 放 `/azahar`（p3）开机复制到 `/data`；nano 外壳升到 RG52mini v1.14；HDMI 音频 CPU DAI `&sai1`→`&sai2` | Fat、system |
| v27 | + 内置手柄拼音 IME（`com.llj.ngpime`）与 LANGOS 前端（`com.retrofront`）到 `/system/app`，默认 IME 与默认桌面都改过去；`ngp-fixup.sh` 输入法段从讯飞改为这个 | system、vendor |
| **v28** | **+ vendor 分区 254→575 MiB（cache 384→64 MiB），3DS 的 38 MB core 与 4 个 hook 从 p3 搬进 `/vendor/azahar`，p3 腾出 36 MB。setup 脚本改为按大小判断，升级时会换掉 /data 里的旧 core** | **GPT、cache、vendor、system** |

| 版本 | 交付镜像 | md5 |
|---|---|---|
| v3 | `GammaOSCore-NGP45HT-20261015-v3.img` | `03951a3bb01135aa057b306c2e6f281b` |
| v4 | `GammaOSCore-NGP45HT-20261015-v4.img` | `512f62df34c1e45d5f79245b447cf489` |
| v15 | `GammaOSCore-NGP45HT-20261021-v15.img` | `00bc41eaccab1fb241687e610a4dbcbd` |
| v16 | `GammaOSCore-NGP45HT-20261022-v16.img` | `2013ad003524ebd35ca39e6cb08262ba`（**开机重启，已废弃**） |
| v17 | `GammaOSCore-NGP45HT-20261022-v17.img` | `911f104e1da550448b3c15005423d415` |
| v19 | `GammaOSCore-NGP45HT-20261022-v19.img` | `25da8797aadf1f35fb971c30865e7ab7` |
| v20 | `GammaOSCore-NGP45HT-20261022-v20.img` | `22e2aa796e70b3681672d6ee975a4b50` |
| v21 | `GammaOSCore-NGP45HT-20261022-v21.img` | `f66622e7ce241b8b1a0c8fec75950350` |
| v22 | `GammaOSCore-NGP45HT-20261022-v22.img` | `66431dec1d6955c0bbf6f3fef3576778` |
| v23 | `GammaOSCore-NGP45HT-20261022-v23.img` | `df01804797d4ada146c4e05789cce7f1` |
| **v24** | `GammaOSCore-NGP45HT-20261026-v24.img` | `d31cb3477536585811e8c964672ec6b7` |
| v25 | `GammaOSCore-NGP45HT-20261028-v25.img` | `5448ed938e32c7dee3bbf73741c06b7f` |
| v26 | `GammaOSCore-NGP45HT-20261028-v26.img` | `9c77ed60e1add63c6f5fda217ebab777` |
| v27 | `GammaOSCore-NGP45HT-20261029-v27.img` | `91dc1bb12ab6644bf49046b632f1f24a` |
| **v28** | `GammaOSCore-NGP45HT-20261029-v28.img` | 见镜像目录 `SHA256SUMS-v28.txt` |

均为 5,451,564,032 B。注入方法：免特权 `dd` 抽分区 → `debugfs -w -f` 命令文件注入 →
`e2fsck -fn` → `dd` 写回 → 区域级 `cmp` 比对（除目标分区外零改动，GPT 未动）。
v4 三重验证：重抽 vendor 与注入源 `cmp` 一致、e2fsck 干净（1434 文件 = v3 的 1431 + 3）、
v3↔v4 非 vendor 区域（含 userdata 全量）md5 相同 `515bc9a0…`。
v15 三重验证：三个分区回读 md5 与源镜像全一致、FAT 内 Image/DTB/conf 回读命中、
`fsck.fat` 与 `e2fsck -fn` 全通过、真机 `/proc/version` 命中新内核。

### v16：全新刷机才暴露的四条默认值错误

v15 在自己机器上一切正常，别人全新烧录后开机 LOGO 转 90°、进系统屏幕颠倒、
nano 里也颠倒、鼠标点击乱飞、改分辨率后出现两个点击点。

根因不是新代码引入的，而是**方向一直靠 `/data` 里手工 setprop 的 persist 属性撑着**。
全新刷机 `/data` 为空，属性回落到 `build.prop` 默认值，而默认值是照搬 RG52 Mini
（720×1280 竖屏）的。本机设备与 build.prop 逐项比对 76 项 persist 属性，
只有 `persist.gammaos.nano.drm_flip_v` 一项不一致：设备 `0`，默认 `1`。

四处改动：

| # | 问题 | 改动 |
|---|---|---|
| ① | 开机 LOGO 转 90° | `dArkOS_Fat::/logo.bmp` 是 720×1280 竖图（印着 "RG52 MINI"），换成 1024×768 横版，只保留泼墨图形，8bit 256 色不变 |
| ② | 内核控制台竖排 | `extlinux.conf` 删掉残留的 `fbcon=rotate:1`（仓库模板早改了，镜像里那份没同步） |
| ③ | nano 上下颠倒 | `build.prop` 写死 `drm_flip_v=0` / `drm_flip_h=0` / `nano.orientation=rev_landscape`；`ngp-fixup.sh` 的 flip 判断从「为空才补 0」改成「不是 0 就纠回 0」 |
| ④ | 改分辨率后两个点击点 | 重启 gammapad 时等 `init.svc.gammapad` 走到 `stopped` 再 `start` 并等回 `running`，中途残留就 `killall -9`；服务未运行时不重启；两次重启至少隔 5 秒 |

③ 还解释了「重启一次就好」的假象：`ngp-fixup.sh` 挂在 `sys.boot_completed=1`，
实测约 56 秒才跑，而 `gammaos-nano` 是 `class core animation`，早就接管屏幕了。
首次开机读到空 orientation 就走未初始化矩阵分支；脚本补上 `rev_landscape` 后，
下一次进 nano 才正常。

已刷 v15 的机器不重刷也能救系统内颠倒与双光标：

```sh
adb root
adb shell setprop persist.gammaos.nano.drm_flip_v 0
adb shell setprop persist.gammaos.nano.drm_flip_h 0
adb shell setprop persist.gammaos.nano.orientation rev_landscape
adb reboot
```

（FAT 分区里的 `logo.bmp` 和 `fbcon` 只能改卡或刷 v16。）

### v15 的两处修复

**方向键下/左/右无响应**（nano 模式尤其明显，只有上键能用）

`rk3562_gpio_work_func()` 原来只把 `BTN_DPAD_UP` 转成 `ABS_HAT0Y`，下/左/右仍走
`input_report_key(BTN_DPAD_*)`。但设备 KEY 能力位图最大键码只到 318：

```
# cat /sys/class/input/input3/capabilities/key
f00000000 0 0 0 7fdb000000000000 0 0 0 0   →  [32,33,34,35, 304..318]
```

`BTN_DPAD_*`（544~547）没有注册，内核 `input_event()` 里 `test_bit()` 为假即丢弃，
所以下/左/右从未进过事件队列。改成四个方向统一由 `ABS_HAT0X/ABS_HAT0Y` 承载，
并在 GPIO 中断里当场 `input_report_abs`（不等 30 ms 的 poll tick），
`poll` 侧加 `last_hat_x/y` 边沿检测避免重复上报。

**改分辨率后鼠标点击落点错位**

`wm size` 只改 SurfaceFlinger 的 override `DisplayInfo`，不改 `fb0`；而 gammapad 的
`MouseMode` 只在 `loadConfig()` / `setActive(true)` 时探测一次尺寸，
`VirtualMouse` 的 `absinfo` max 又在创建时绑死。于是指针坐标系恒为物理分辨率
1024×768，与 app 坐标系按比例错位。`ngp-fixup.sh` 改为解析 `wm size`
（优先 `Override size`）写入 `persist.gammaos.gamepad.screen_w/screen_h`
并重启 gammapad，另起 2 秒轮询看门狗跟进后续变化。


## 5. WiFi：AIC8800DC（USB）替换 AIC8800D80（SDIO）

vendor 来自 DOOGEE U10（AIC8800D80，SDIO）。NGP45HT 是 USB 接口，需换模块对：

```diff
 # vendor/bin/wifi_pick.sh 第 60-61 行
-insmod /vendor/lib/modules/aic8800_bsp.ko
-insmod /vendor/lib/modules/aic8800_fdrv.ko
+insmod /vendor/lib/modules/aic_load_fw_usb.ko aic_fw_path=/vendor/etc/firmware/aic8800
+insmod /vendor/lib/modules/aic8800_fdrv_usb.ko
```

- `/vendor/lib/modules/` 删 `aic8800_bsp.ko`、`aic8800_fdrv.ko`，放入本目录两个 USB .ko
- 固件 21 个文件放 `/vendor/etc/firmware/aic8800/`（与镜像内逐字节一致）
- 内核侧 `CONFIG_AIC8800_WLAN_SUPPORT=y`（rg52mini_defconfig 已含）

## 6. RetroArch 简体中文

设备端验证方案：CarroisGothicSC 字体 + cfg 四项字体键 + `user_language=12`。
镜像 userdata 零填充无法预置，采用 **vendor 暂存 + 开机幂等部署**：

- `/vendor/etc/init/rg52-retroarch.rc`：`on property:sys.boot_completed=1` → `start rg52_retroarch_zh`（oneshot）
- `/vendor/bin/rg52-retroarch-zh.sh`：等 RetroArch app 目录出现（≤2min 轮询）→ cp 字体 →
  cfg 缺 `zh-CN.ttf` 才覆盖 → chmod 666/644 → log 记录
- userdebug 构建 SELinux 默认 permissive，init 域可写 /data/media/0

## 7. 烧录与未验证项

- Rufus DD 模式写入 TF 卡；u-boot 从 SD 优先（eMMC 内原版 loader 16MB 已提取备份）
- 首启 userdata 自动扩展；EEROMS roms 在 SD FAT32 分区
- 刷机会清空 `/data`；第三方 app（如影视仓）需刷后自行 `adb install`
- **未验证**：mamaich u-boot 的 DDR init 与 NGP45H 兼容性（不兼容则用备份 loader 替换镜像前 16MB）、
  AIC8800DC 的 BT 通路

## 8. v4：WiFi 防假死与输入法固化（实机排障闭环）

办公室 WiFi 上暴露两个会复发的问题，线上修过但重启即丢，故固化进 v4。

| # | 故障 | 根因 | 症状 |
|---|---|---|---|
| 1 | 驱动假死 | AIC8800DC 驱动在 USB 链路挂起后把自己 latch 成 `usb disconnected` 且**不复位** | 所有扫描返回 `busy`，界面上 WiFi 整个消失（`lsmod` 里模块其实还在） |
| 2 | 密码框输不进字 | 默认输入法 `com.liskovsoft.leankeyboard` 在 WiFi 密码框崩溃（IME 窗口 `invalid token`，按键事件全被丢弃） | 点连接后"转圈失败"，实际**连接从未发起** |

对策（vendor 分区新增 3 个文件）：

| 文件 | 权限 | 作用 |
|---|---|---|
| `etc/init/rg52-wifi-fix.rc` | 0644 | 声明 `rg52_wifi_fix`（oneshot）+ `rg52_wifi_watchdog`（常驻），`on property:sys.boot_completed=1` 拉起 |
| `bin/rg52-wifi-fix.sh` | 0755 | ① `wifi_sleep_policy=2`、`wifi_scan_always_enabled=1`、`wifi_country_code=CN`；② 默认输入法切到 `com.android.inputmethod.leanback`；③ 找到 USB `a69c:88dc` 设备写 `power/control=on`、`power/wakeup=disabled` |
| `bin/rg52-wifi-watchdog.sh` | 0755 | 每 5 分钟探测；WiFi 开启却连续两次 `iw dev wlan0 scan` 拿不到 BSS → `svc wifi disable` → 重启 `vendor.wifi_hal_legacy` → `rmmod`/`insmod` 重载 → `svc wifi enable`。**用户主动关 WiFi 时不干预** |

日志：`/data/local/tmp/rg52-wifi-fix.log`、`/data/local/tmp/rg52-wifi-watchdog.log`

### 实机连接记录（供排查参考）

- 办公室 AP `360JDCWiFi-E378`（2.4G ch1，-29dBm，WPA2/WPA3 混合）连上后 IP `192.168.0.176`，
  ping `223.5.5.5` 零丢包 ~22ms
- `cmd wifi` 无强制指定安全类型的子命令；UI 注入路径脆弱（TV 设置会传不存在的 `networkId`），
  可靠做法是改 `/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml`（**改完必须重启**，
  框架内存态会覆盖运行中替换的文件；`RandomizedMacAddress` 不能填 `null`，否则 NPE 整条网络被跳过）

## 9. v5：关机掉电 BUG 修复（内核补丁 0004）

**现象**：晚上关机，第二天早上一点电都没有、必须插充电器才能开机。

**根因**：pstore / ramoops 取证到关机流程中的内核崩溃 ——

```
sys.powerctl=shutdown → __do_sys_reboot → kernel_restart → kernel_restart_prepare
  → device_shutdown(reboot.c:79) → mmc_bus_shutdown → mmc_sd_shutdown
```

第二个 TF 卡槽（`ff890000` / sdmmc1，插着 50GB ROMs 卡，DTB 为 `broken-cd` 轮询）在关机瞬间
被轮询判定为「卡已移除」（`host->card = NULL`）；`_mmc_sd_shutdown()` 里的
`WARN_ON(!host->card)` 发现了却只返回 0，外层照样解引用 `host->card->dev`（NULL+0xec）
→ **Kernel panic → 关机失败、设备不断电** → 电池整夜放光。
（主机编号：mmc0=eMMC，mmc1=启动 TF 卡 `ff880000`，mmc2=第二卡槽，panic 只在 mmc2。）
另一次关机是干净的，说明这是**竞态**而非必现。

**修复**：`drivers/mmc/core/sd.c` 的 `mmc_sd_shutdown` / `mmc_sd_suspend` 两处加 NULL 保护
（补丁 `device/ngp45ht/kernel-patches/0004-mmc-sd-shutdown-null-card-fix.patch`），
内核版本号不变，WiFi/BT 模块 vermagic 仍兼容。

```c
-	if (!err) {
+	if (!err && host->card) {
 		pm_runtime_disable(&host->card->dev);
 		pm_runtime_set_suspended(&host->card->dev);
 	}
```

**实测**：`setprop sys.powerctl shutdown`（电源菜单同一条路径）→ 设备真正断电
（adb / ping 均无响应）；开机后 `/sys/fs/pstore/` 为空 —— 真断电后 DDR 掉电，ramoops 被清空；
此前 panic 时记录能存活，恰恰是设备没断过电的证据。

rk817 的断电链路在 `rk8xx_syscore_shutdown()`（rk808.c），**只有命令是 POWER_OFF 时才写
DEV_OFF 真断电**，RESTART 只重启不断电。

## 10. v6：底座换到上游 v1.10（2026-10-16）

上游 `mamaich/GammaOSNext-RG52mini` 在 2026-10-14 发布了 **v1.10**
（`GammaOSCore-RG52Mini-20261014-2235.img.zip`，与 v1.9 **同内核 5.10.226、同 u-boot `rg52mini-1.4`、
同 Android 13 vendor**），另有 v1.11 在 develop 上起草（未打包）。v6 即把底座换成 v1.10。

**分区布局与 v1.9 逐字节一致**（uboot / resource / dArkOS_Fat / system / vendor / cache /
metadata / misc / userdata 九个分区的偏移与大小全部相同），因此只需重放改动，DTB 与内核不受影响。

改动重放（`~/rainject/build-v6.sh`，幂等：每次从原始 v1.10 重新合成）：

| 分区 | 文件 | 改动 |
|---|---|---|
| dArkOS_Fat | `Image` | 自编内核（含 0004 关机修复），md5 `a23c0e74…` |
| dArkOS_Fat | `rk3562-ngp45ht.dtb` | 新增，md5 `3c5f6fe2…` |
| dArkOS_Fat | `extlinux/extlinux.conf` | 基于 v1.10 官方版：`FDT /rk3562-ngp45ht.dtb` + 去 `fbcon=rotate:1` |
| system | `system/build.prop` | `ORIENTATION_90→0`、`fixed_rotation 1→0` |
| system | `system/usr/keylayout/` | 3 个 .kl（`adc-keys`、`rk3562-joystick`、`retrogame_joypad`） |
| vendor | `lib/modules/` | 删 SDIO `aic8800_bsp.ko`+`aic8800_fdrv.ko`，装 USB `aic_load_fw_usb.ko`+`aic8800_fdrv_usb.ko` |
| vendor | `etc/firmware/aic8800/` | 删 15 个 D80 固件，装 21 个 DC 固件 |
| vendor | `bin/wifi_pick.sh` | 尾部 insmod 换成 USB 模块（`aic_fw_path` 参数属于 **load_fw** 模块，给 fdrv 无效） |
| vendor | `bin/` `etc/init/` `etc/retroarch-zh/` | WiFi 防假死三件套 + RetroArch 中文字体与部署脚本 |
| vendor | `build.prop` | `ro.minui.default_rotation=ROTATION_RIGHT→ROTATION_0` |

**v6 三重验证**：① 成品镜像回抽三个分区，system / vendor 与注入后的分区逐字节 `cmp` 一致；
② `e2fsck -fn` 两个 ext4 均干净（system 8353/8448 文件，vendor 1434/1568 文件 62100/64148 块），
FAT 侧 `mtools mdir` + 80,994 簇零重叠；
③ `assert-v6.py` 25 项逐项断言（内核 md5、DTB、extlinux 两项、build.prop 两项、
3 个 keylayout 及其 SELinux 标签、WiFi 模块与固件、脚本 0755、rc 与字体）全部通过。

### 踩坑记录

- **debugfs 的 `write` 不会覆盖已存在的文件**：报 `Ext2 file already exists` 后**直接跳过不报错退出**，
  必须 `rm <目标>` 再 `write`。漏掉这一步时，build.prop / wifi_pick.sh 的改动会静默丢失。
- 新建的 inode 没有 SELinux 标签，必须补：system 下 `u:object_r:system_file:s0`，
  **vendor 下 `u:object_r:vendor_file:s0`**（此前记成"vendor 不必补"是错的 ——
  `/vendor/bin/ngp-fixup.sh`、`ngp-statd` 实测都是 `vendor_file:s0`）。
  值必须以 NUL 结尾，与镜像里原生一致（26 字节）。**`\000` 直接写进 debugfs 命令文件不管用**
  （它按行读，NUL 会被吃掉，落进去是 25 字节），要用 `ea_set -f <值文件>`，值文件用
  `printf 'u:object_r:system_file:s0\0'` 生成。
- 漏了标签的后果不是必然崩：实测 v26 里 `AzaharSf` 是 `unlabeled` 也能被 PackageManager
  扫到并正常运行，但那是踩对了不是保证，`ls -Z` 一看就能区分。
- `debugfs -R "ls -l <文件路径>"` 对**单文件**无效（`Ext2 inode is not a directory`），
  断言里要列目录再匹配。
- vendor 分区同样有标签，只是域不同（`vendor_file` / `vendor_configs_file`）。
- 非特权环境下第三方校验：FAT 用 **mtools**（`mdir` / `mcopy`），ext4 用 **debugfs** + `e2fsck -fn`；
  本机没有 7z。

### 改 GPT 分区大小（v28）

- **`sgdisk` 的 `-d` 和 `-n` 不能写在同一条命令里**：会报
  `Could not change partition N's type code to 8300` 然后整条回滚（`Error encountered; not saving changes.`）。
  必须分三步：`-d N` → `-n N:start:end` → `-t/-u/-c`。
- 重建分区前先用 `sgdisk -i N` 取原 UUID，重建后 `-u N:<UUID>` 写回。fstab 走
  by-name 不看 UUID，但刷机工具和某些脚本会看，丢了对不上号。
- 想让 p5 变大而 p6 缩小、p7 之后不动，两个尺寸必须严格配平：
  `新p5 + 新p6 = 原p5 + 原p6`。本例 1177600 + 131072 = 521576 + 786432 = 1308008。
  新 cache 起点选在 2048 边界（8378368 = 4091×2048）才能既对齐又不留空洞。
- **cache 是空的就别搬**（只有 lost+found）：直接 `dd` 清零 + `mke2fs -E offset=`
  重建，比 dd 搬 384 MB 快得多。UUID 用 `-U` 指定回原值。
- **`resize2fs` 不支持 `img?offset=N` 语法**（debugfs 支持，它不支持）。
  必须 `dd` 抽出分区 → `e2fsck -f` → `resize2fs` → `e2fsck -f` → `dd` 写回。
- **改完分区表，范围校验不能只用旧表**：v28 的 p5 比 v27 宽 320 MiB，
  拿 v27 的表去判差异范围，新增的那段会被误报成"分区外 344,064 B"。
  要取两版分区表的**并集**再判。
- GPT 记账区在镜像**最后 34 个扇区**（不是 33）：`[size-34*512, size)`。
