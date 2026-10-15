# GammaOS Next 掌机移植（XiFan NGP45H / RK3562）

本仓库是 [TheGammaSqueeze/GammaOSNextDistribution-14](https://github.com/TheGammaSqueeze/GammaOSNextDistribution-14)
—— GammaOS Next（LineageOS 21 / Android 14）源码树 —— 的分支。上游目标机是
**AISLPC RG52 Mini**（Rockchip RK3562），本分支已改造成 **XiFan NGP45H**：同一块
Rockchip RK3562 EVB1 LP4X V10 参考板，但屏幕换成 1024×768 横屏 DSI、手柄是
`micro-gamepad`、Wi-Fi 是 USB 接口的 AIC8800DC。路径里设备代号记作 **`ngp45ht`**。

> 完整移植说明（中文）：[doc/ngp45ht/README.md](doc/ngp45ht/README.md)

## 设备档案

| 项目 | XiFan NGP45H（`ngp45ht`） | RG52 Mini（上游基线） |
|---|---|---|
| SoC | RK3562：4×A55、Mali-G52、NPU，2GB RAM | 相同 |
| 底板 | Rockchip RK3562 EVB1 LP4X V10，厂商在其上做掌机化 DTS | 相同 |
| 屏幕 | **DSI 1024×768@60**，4 lane RGB888，`simple-panel-dsi`，init-sequence 写在 DTB 内 | 640×480 竖屏 |
| 输入 | **`micro-gamepad`**（双摇杆 ADC + 4 个 ADC 键 + 17 个 GPIO 键 + 震动马达）+ `adc-keys`（音量±/静音/返回）+ `rk805-pwrkey`，**没有触摸屏** | 另一套手柄 |
| 音频/电源 | `rk817` codec/battery/charger，背光 PWM 256 级，HDMI，u-boot 充电动画 | 相同 |
| Wi-Fi | **AIC8800DC，USB 接口**（`usb 3-1`）。DT 里 `wifi_chip_type="ap6275s"` 是 EVB 遗留，不生效 | AIC8800D80（SDIO） |
| USB | DWC3，基础 DTB 里 `dr_mode="otg"` | host |

## NGP45HT 做了什么

设备相关的一切都在 `device/ngp45ht/`：

| 部分 | 内容 / 来源 |
|---|---|
| 内核、DTB | [mamaich/kernel_rk3562_rg52mini](https://github.com/mamaich/kernel_rk3562_rg52mini)（Linux 5.10.226）+ `device/ngp45ht/kernel-patches/`：新增 `rk3562-ngp45ht.dts`、`Makefile` 加一行、`rk3562-darkos.dtsi` 补两个 label、`rk3562-joystick.c` 适配手柄 |
| 按键布局 | `keylayout/` → `/system/usr/keylayout/`：`adc-keys.kl`、`retrogame_joypad.kl`、`rk3562-joystick.kl` |
| 横屏修正 | `system/build.prop.patch`：`ORIENTATION_90` → `0`，`fixed_rotation` `1` → `0` |
| Wi-Fi | `wifi/`：USB 模块对 `aic_load_fw_usb.ko` + `aic8800_fdrv_usb.ko`、21 个固件、对 `vendor/bin/wifi_pick.sh` 的两行 insmod 改动 |
| RetroArch 简体中文 | `retroarch-zh/`：`retroarch.cfg`、CarroisGothicSC 字体 `zh-CN.ttf`、`rg52-retroarch.rc` 与开机幂等部署脚本 |
| 工具脚本 | `scripts/`：`build_kernel.sh`（内核 + DTB 一键构建）、`patch_system.sh`（免 root / 免 loop 的 ext4 离线注入） |

`system.img` 的构建方式与上游完全相同，走同一个目标：

```bash
bash buildtv.sh nosync      # GammaOS Core（Android TV 版），适用于 5.7 以上内核
```

最终的可烧录 SD 卡镜像是在上游镜像基础上替换 Fat / vendor / system 三个分区得到的，
做法、版本演进（v1 → v3）与校验记录见 [doc/ngp45ht/README.md](doc/ngp45ht/README.md)。

## 移植状态

| 项目 | 状态 |
|---|---|
| 屏幕 / 手柄 DTB | 已就绪，随内核树一起构建 |
| 内核与模块 | `Image` 与 `rk3562-ngp45ht.dtb` 已构建 |
| SD 卡镜像 | 已组装并校验，5.45 GB |
| 启动、显示、输入、音频、RetroArch | 实机已验证 |
| Wi-Fi（AIC8800DC / USB） | 可用：能连接网络并访问外网 |
| RetroArch 简体中文 | 首次开机自动部署 |
| AIC8800DC 蓝牙通路 | 未验证 |
| 引导器 DDR init 与本板的兼容性 | 未验证（已备份原厂 loader 作兜底） |

---

# 上游基线说明（RG52 Mini）

以下内容说明这棵源码树本身从上游继承的部分。NGP45HT 用的就是这棵树，
只是换掉了设备相关的附件，所以这部分依然适用。

## 这棵树解决什么问题

设备原本跑的是厂商的 Android 13（SyachOS），但作者只按许可证公开了内核源码，
Android 部分没有源码、无从继续改进，因此系统是从源码重新构建的。

这棵树只构建 **GSI**，也就是 `system` 分区；其余部分取自既有构建和可运行的镜像：

| 镜像分区 | 来源 |
|---|---|
| `system` | **本仓库构建** —— GammaOS Core，Android 14 |
| `vendor` | 取自可运行的 SyachOS 镜像：Wi-Fi/蓝牙 AIC8800D80、Rockchip HAL。SyachOS 自己也没构建它，该分区来自同 SoC 的 DOOGEE U10 平板。镜像里厂商的 `rgp2pad` 已移除，手柄交给系统自带的 gammapad |
| 内核、DTB | [mamaich/kernel_rk3562_rg52mini](https://github.com/mamaich/kernel_rk3562_rg52mini) —— Linux 5.10.226 |
| 引导器 | [mamaich/u-boot-rk3562-rg52mini](https://github.com/mamaich/u-boot-rk3562-rg52mini) |

之所以能这样拼接，是因为这台设备上的 Android 13 满足 Treble
（`ro.treble.enabled=true`、`ro.vndk.version=33`），而树里带了供 Android 13
vendor 库使用的 VNDK v33 快照。

## 为什么选 GammaOS Next

这类掌机**没有触摸屏**，只有手柄、方向键和几个按键。基于 Android TV 的
GammaOS Core 正是为此设计：界面完全可以用手柄走通，镜像里已内置 RetroArch、
PPSSPP、Flycast、DraStic、mupen64plus、Daijishō，并去掉了没有 modem 的设备上
用不到的电话功能。

## 下载

成品 SD 卡镜像在上游的 [Releases](https://github.com/mamaich/GammaOSNext-RG52mini/releases)
页面。无需自行构建：写卡、插入、开机即可。首次启动时 `userdata` 会自动扩展到整张卡。

想在同一张卡上同时放 GammaOS 和 dArkOS，可以用带开机选系统菜单的成品双系统卡：
[RG52mini-dualboot](https://github.com/mamaich/RG52mini-dualboot/releases/tag/v1.0)。
里面的 GammaOS 与这里的发布版一致，同样支持 OTA 升级。

NGP45HT 的成品镜像与发布说明在 [doc/ngp45ht/README.md](doc/ngp45ht/README.md)。

## 目录指南

| | |
|---|---|
| 设备拆解、vendor 与启动链、各部分如何拼接 | `doc/rg52mini/01-разбор.md` |
| 工作计划、技术决策与遗留问题 | `doc/rg52mini/02-план.md` |
| 自行构建 | `doc/rg52mini/03-сборка.md` |
| 内存超频到 928 MHz（可选，风险自负） | `doc/rg52mini/04-частота-памяти.md` |
| HDMI：模式、镜像、「底座」模式、排查 | `doc/rg52mini/05-hdmi.md` |
| EmuELEC / RGBox 与 GammaOS Next 共存：双系统切换、共享 rom 目录 | `doc/rg52mini/06-emuelec-на-emmc.md` |
| 系统设置：电源菜单、GammaOS Toolbox、Android TV 设置 | `doc/rg52mini/07-настройки.md` |
| 性能与内存：已做的、可自行调整的、已验证或已否决的 | `doc/rg52mini/08-производительность.md` |

> 注：`doc/rg52mini/` 下的文档沿用上游原文（俄文），本分支未改写。

## 构建状态

系统已构建并在设备上运行。SD 卡镜像由一条命令组装，交付前会挂载核验。

| 阶段 | 状态 |
|---|---|
| 设备、vendor、启动链拆解 | 完成 |
| Treble 兼容性核验 | 完成 |
| 源码树展开 | 完成 |
| 独立构建目标 | **不需要** —— 标准目标即可产出所需分区布局 |
| 设备相关附件（`device/rg52mini/`、`device/ngp45ht/`） | 完成，已接入构建目标 |
| `system.img` 构建 | 通过：首次 3 小时 24 分，增量 8 分钟 |
| 供 Android 13 vendor 使用的 VNDK 33 快照 | 镜像内已含 `/system_ext/apex/com.android.vndk.v33.apex` |
| SD 卡镜像 | 已组装并核验，5.45 GB —— 体积固定：自 v1.2 起分区布局固定，与内容无关 |
| **系统上机** | **可运行** |

实机已验证项：

| | |
|---|---|
| 启动 | 完整走到 `BOOT_COMPLETED`，GammaOS 启动器与设置向导 |
| 图形 | `surfaceflinger` 一次成功，1280×720，密度 213，`ORIENTATION_90` |
| Wi-Fi | AIC8800 正常起来，可连网 |
| 音频 | 正常，模拟器内也有声 |
| 输入 | 摇杆、方向键、按键、Select/Start、音量、机身 HOME/BACK、长按电源菜单 |
| 扳机键 | LT/RT 硬件上接反，通过 `remap_axis` 对调 |
| 鼠标模式 | 已验证：两个摇杆都能开关、L3/R3 点击、无多余事件透传给应用。切换时屏幕会短暂闪烁，其余按键正常 |
| 手柄设置 | 界面只保留鼠标模式开关：其余按硬件固定，盲改会破坏操作 |
| 蓝牙 | 手柄与耳机均验证；A2DP 默认 SBC 而非 AAC，延迟更低 |
| Google 账号登录 | microG：已通过 Google 账号在 Aurora Store 完成授权 |
| 浏览器与 WebView | 页面可正常渲染 |
| GammaOS Nano 桌面 | 屏幕旋转、Wi-Fi、启动应用、浏览器内软键盘 |
| 调试串口 | COM4，1500000 8n1：启动日志，启动后进入交互 shell |
| USB host | 鼠标可接入使用 |
| adb | 可用 |
| Root | 内核内 KernelSU-Next，管理器 `v3.3.0` 已被内核接受 |
| `userdata` 扩展 | 两次启动，960 MB → 53 GB，无需干预 |
| 模拟器 | 可启动 |
| OTA 升级 | 系统更新应用自行发现、下载并安装，写入进度在屏幕上可见 |
| 旧版游戏安装 | DuckTales Remastered（`targetSdk` 22）可用系统安装器直接安装，不需要 `adb` |

## 上游构建方式

GammaOS Next 本身未做改动，按作者的方式使用：

```bash
bash buildtv.sh nosync      # GammaOS Core（Android TV），5.7 以上内核
bash buildtv_cc.sh nosync   # 同上，但为无 userfaultfd 的内核准备 ART boot 镜像
bash build.sh nosync        # GammaOS Next Lite（普通界面）
```

RG52 Mini 与 NGP45HT 都用 **`buildtv.sh`**。早前用 `buildtv_cc.sh`：当时设备内核关闭了
`CONFIG_USERFAULTFD`，ART 走复制式 GC，boot 镜像必须与之匹配；现在内核已开启该选项，
ART 改为整理式 GC，boot 镜像也要相应更换。两者必须成对：否则 `OatHeader` 校验不通过，
zygote 每次冷启动都要用 dex2oat 重新构建 `boot classpath`。

完整构建流程（含 SD 卡镜像、内核与 Wi-Fi 模块的来源）见
`doc/rg52mini/03-сборка.md`，决策与踩坑记录见 `doc/rg52mini/02-план.md`。
