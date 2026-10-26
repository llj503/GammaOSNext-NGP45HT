# GammaOS Next 掌机移植（XiFan NGP45H / RK3562）

本仓库是 **XiFan NGP45H**（Rockchip RK3562）的 GammaOS Next（LineageOS 21 / Android 14）
移植工程。源码树 fork 自
[mamaich/GammaOSNext-RG52mini](https://github.com/mamaich/GammaOSNext-RG52mini)（上游目标机是
AISLPC RG52 Mini，同为 RK3562），本仓库已改为只服务于 NGP45HT，
设备代号记作 **`ngp45ht`**。

> 完整移植说明、镜像版本演进与校验记录：[doc/ngp45ht/README.md](doc/ngp45ht/README.md)

## 设备档案

| 项目 | 规格 |
|---|---|
| SoC | RK3562：4×A55、Mali-G52、NPU，2GB RAM |
| 底板 | Rockchip RK3562 EVB1 LP4X V10 参考板，厂商在其上做掌机化 DTS |
| 屏幕 | DSI 1024×768@60，4 lane RGB888，`simple-panel-dsi`，init-sequence 写在 DTB 内 |
| 输入 | `micro-gamepad`（双摇杆 ADC + 4 个 ADC 键 + 17 个 GPIO 键 + 震动马达）+ `adc-keys`（音量±/静音/返回）+ `rk805-pwrkey`，**没有触摸屏** |
| 音频 / 电源 | `rk817` codec / battery / charger，背光 PWM 256 级，HDMI，u-boot 充电动画 |
| Wi-Fi + 蓝牙 | **AIC8800DC，USB 接口**（`usb 3-1`，VID:PID `a69c:88dc`）。DT 里 `wifi_chip_type="ap6275s"` 是 EVB 遗留，不生效 |
| USB | DWC3，基础 DTB 里 `dr_mode="otg"` |
| 原厂系统 | EmuELEC 4.7-Nexus（Linux 6.1.118），仍在 eMMC 上，与本镜像双系统 |

## NGP45HT 做了什么

设备相关的一切都在 `device/ngp45ht/`：

| 部分 | 内容 |
|---|---|
| 内核、DTB | `kernel-patches/`：`0001` 手柄 per-axis invert / 通道可选 / GPIO 驱动 L2·R2，`0002` rk3562-joystick 适配，`0003`+`rk3562-ngp45ht.dts` 设备树，`0004` 关机 panic 修复（`mmc_sd_shutdown` 空指针） |
| 按键布局 | `keylayout/` → `/system/usr/keylayout/`：`adc-keys.kl`、`retrogame_joypad.kl`、`rk3562-joystick.kl`（17 键全映射） |
| 横屏修正 | `system/build.prop.patch`：`ORIENTATION_90` → `0`、`fixed_rotation` `1` → `0`；vendor `build.prop` 的 `ro.minui.default_rotation` 同理 |
| Wi-Fi | `wifi/`：USB 模块 `aic_load_fw_usb.ko` + `aic8800_fdrv_usb.ko`、21 个 DC 固件、`wifi_pick.sh` 的 insmod 改动、`rg52-wifi-fix.{rc,sh}` + `rg52-wifi-watchdog.sh`（USB 防挂起 + 5 分钟自愈看门狗） |
| RetroArch 简体中文 | `retroarch-zh/`：`retroarch.cfg`、CarroisGothicSC 字体 `zh-CN.ttf`、`rg52-retroarch.rc` 与开机幂等部署脚本 |
| 蓝牙（实验） | `bt/`：mamaich `btvendor_aic.c` HCI 中继（含 8 条伪造响应）、编译产物 `.so`、shim 模块与部署脚本 |
| 启动配置 | `boot/`：`extlinux.conf`（`FDT /rk3562-ngp45ht.dtb`，去掉 `fbcon=rotate:1`）+ `rk3562-ngp45ht.dtb` |
| 工具脚本 | `scripts/`：`build_kernel.sh`（内核 + DTB 一键构建）、`patch_system.sh`（免 root / 免 loop 的 ext4 离线注入） |

成品 SD 卡镜像由 `~/rainject/build-v6.sh`（本地脚本）在官方 v1.10 镜像基础上合成，
只替换 Fat / system / vendor 三个分区中的少量文件，其余字节级不动。

## 自行构建

```bash
bash buildtv.sh nosync      # GammaOS Core（Android TV 版），产出 system.img
```

根目录上方另有 served upstream：`buildtv_cc.sh`（无 userfaultfd 内核配套的 ART boot 镜像）、
`build.sh`（Lite 界面）。NGP45HT 用 **`buildtv.sh`**：
设备内核已开 `CONFIG_USERFAULTFD`，ART 走整理式 GC，`buildtv_cc` 的 boot 镜像与之不匹配会导致
`OatHeader` 校验失败、zygote 冷启动重新 dex2oat。

完整构建流程（SD 卡镜像怎么拼、内核与 Wi-Fi 模块从哪来）见
[doc/ngp45ht/README.md](doc/ngp45ht/README.md)。

## 移植状态

| 项目 | 状态 |
|---|---|
| 屏幕 / 手柄 DTB | 已就绪，随内核树一起构建 |
| 内核与模块 | `Image`（5.10.226-rg52mini-ngp45ht）+ `rk3562-ngp45ht.dtb` 已构建 |
| SD 卡镜像 | 已组装并三重校验，5.45 GB（当前 **v24**，xz 压缩后 1.69 GB，底座为上游 v1.10） |
| 启动、显示、输入、音频、RetroArch | 实机验证通过 |
| 方向键 | 四向均正常（v15 改为统一走 HAT 轴，此前下/左/右被内核丢弃） |
| 鼠标模式 | 改分辨率后落点自动跟随（v15）；重启 gammapad 改为等状态机，不再出现双光标（v16） |
| 屏幕方向（全新刷机） | v16 修好 LOGO 与控制台旋转；v23 起改用 `wm fixed-to-user-rotation enabled` 锁死显示方向，nano 和游戏都不再翻转 |
| 性能悬浮窗 | v22 起开机不自启，点桌面「NGP 悬浮窗开关」打开；没打开时 statd 空转（0.1% CPU），不再每秒 fork 一次 dumpsys |
| 第二个 TF 卡槽 | v24 起可识别（fstab 补 `voldmanaged=sd:auto`）。挂载点是 vold 给的占位 UUID，读写正常 |
| Wi-Fi（AIC8800DC / USB） | 可用：连网并访问外网，含防假死看门狗 |
| RetroArch 简体中文 | 首次开机自动部署 |
| 关机 / 断电 | 正常：修复了 `mmc_sd_shutdown` 空指针 panic（此前会导致关机失败、整夜耗光电） |
| AIC8800DC 蓝牙通路 | 未验证：BootROM 层拒绝扫描类 HCI 命令 |
| density / UI 缩放 | 沿用 RG52 的 213，未针对 1024×768 微调 |
