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
│   └── firmware-aic8800/          21 个固件文件 → /vendor/etc/firmware/aic8800/
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

注入方法：免特权 `dd` 抽分区 → `debugfs -w -f` 命令文件注入 → `e2fsck -fn` → `dd` 写回 →
区域级 `cmp` 比对（除目标分区外零改动，GPT 未动）。v3 三重验证：重抽 dump md5 一致、
e2fsck 干净（1431 文件）、v2↔v3 非 vendor 区域逐字节相同。

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
- **未验证**：mamaich u-boot 的 DDR init 与 NGP45H 兼容性（不兼容则用备份 loader 替换镜像前 16MB）、
  AIC8800DC 的 BT 通路、v3 镜像实机启动（TF 卡当前仍为旧版）
