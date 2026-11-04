# v33 改动说明（2026-11-04）

针对你提的四个问题，以及后续追加的充电口 / 摇杆灯设置需求。

DTB 一切以原厂 EmuELEC 的 `ngp45ht.dts` 为准，不自创参数。

---

## 1. 摇杆灯不亮 —— 已解决

**根因**：摇杆圈的 WS2812 灯带挂在 **SPI0**，不是上游 RG52Mini 用的 UART1。
上游方案直接搬过来是错的，`&uart1` 还会和 PD2 按键抢引脚。

**做法**：

- `spi0m1` 功能：MOSI=`GPIO3_B5`、CLK=`GPIO3_B4`，`RK_FUNC_4`
- `&spi0 status = "okay"` + `spi_dev@0`（`rockchip,spidev`，8 MHz）
- **绝对不接 CS**：`GPIO3_B7` 同时是 i2c4 的 SDA（RK628D HDMI 桥），
  SPI 一抢这条线，HDMI 就废

**协议**：1 个 SPI 字节 = 1 个 WS2812 bit，`0xC0` = 0、`0xFC` = 1，GRB 顺序。

**验证**：`/dev/spidev0.0` 出现，实机「亮了，红色」→「先绿后蓝，都对」。

用户态工具在 `stickled/`，支持 `off` / `color RRGGBB` / `effect NAME`，
效果有 breath / rainbow / scroll / solid。`off` 发的是真正的全零帧，
不像 ROCKNIX 那样直接退出（那样灯会停在最后一帧）。

---

## 2. 电池显示不准 —— 已定位，主因是充电口被误判

**实测数据**：DC 口接充电器后，一切正常。

```
ac/online        = 1
battery/status   = Charging
battery/current_now = +1,882,000 uA   (+1.88 A)
0xEB  = 0xb3  ->  CHG_STS = 3 (CC/CV 充电中)
0xF0  = 0xc0  ->  PLUG_IN_STS = 1
```

之前「不准」的主因是 **OTG 口被当成了充电器**：那个口能供电、
能跑数据，但**不给电池充电**（`PLUG_IN_STS` 一直是 0），
而 sysfs 的 `ac/online` 会残留成 1，看起来像一直在充电。

**同时按 EE 修正的参数**：

- `bat_res`：80 → **127**（EE 是 `0x7f`）
- `ocv_table` 21 个点与 EE 逐点一致
- 属性名统一成 `charge_blue_gpio`（原来写的 `charge_green_gpio` 是同一个脚）

**驱动层修复**：`rk817_charge_usb_init()` 里原本是

```c
if (charge->dc_charger != DC_TYPE_NONE_CHARGER)
        rk817_charge_set_chrg_param(charge, charge->usb_charger);
```

这块板子 `dc_charger` 永远是 `DC_TYPE_NONE_CHARGER`，这个 `if`
**永远为假**，`usb_in` 从头到尾没被初始化过。改成无条件调用。

---

## 3. 电源灯 / 充电灯长期亮着（息屏也亮）—— 已解决

这个问题我走了两个极端，都记下来免得再犯：

**第一版的理解（错）**：以为灯由 rk817 硬件按 `CHG_STS` 自动驱动。
删掉 pinctrl 之后灯变成「永远不亮」—— 充电中红灯也不亮。

**真相**：

- 5.10 的 `rk817_battery.c` / `rk817_charger.c` **完全不解析**
  `charge_red_gpio` / `charge_blue_gpio`（全树 grep，除 DTS 外零引用）
- rk817 芯片里也没有「充电点灯」的硬件状态机
- 所以灯的亮灭完全取决于 **引脚电平由谁负责**：
  - 原来的 `pcfg_pull_up` 上拉 → 一直通电 → **常亮，息屏也亮**（最初的问题）
  - 谁都不管、浮空 → **永不亮**
  - 正确做法：**交给内核 leds-gpio 注册成标准 LED，用户态按状态点**

**实测引脚语义**（直接拉 GPIO 验证，用户肉眼确认）：

| 引脚 | 全局号 | 颜色 | 有效电平 | 实测结果 |
| --- | --- | --- | --- | --- |
| `GPIO3_C1` | gpio-113 | 蓝 | 高 | 拉高 → 蓝灯亮 |
| `GPIO3_C2` | gpio-114 | 红 | 高 | 拉高 → 红灯亮 |
| `GPIO3_C3` | gpio-115 | ？ | —— | 无可见效果 |

**实现**：

1. DTS 加 `gpio-leds` 节点，注册成
   `/sys/class/leds/charge-red` 与 `/sys/class/leds/charge-blue`
2. `/vendor/bin/ngp-powerled.sh` 轮询（3 秒）按状态点灯：

| 状态 | 灯 | 判据 |
| --- | --- | --- |
| 真在充电 | 红灯常亮 | `current_now > +150 mA` |
| 已充满 | 蓝灯常亮 | `Full` 或容量 ≥99% 且电流接近 0 |
| 外部供电但没充 | 蓝灯常亮 | 插着线但电流不是正的（OTG 口典型） |
| 拔掉线 | 全灭 | 寄存器 `0xF0` 的 `PLUG_IN_STS` = 0 |

**关键坑：不能用 `ac/online` 判断有没有插线。**

实测过「什么都没插」的时候：

```
ac/online  = 1        <- 假的
ac/status  = Charging <- 假的
0xF0       = 0x82     -> PLUG_IN_STS = 0   （芯片说没插）
0xEB       = 0x80     -> CHG_STS = 0(OFF)  （充电没启动）
gpio-103   = lo       （DC 检测脚说没插）
```

这是 `usb_in` / `ac_in` 残留导致的老问题。所以守护脚本
**直接读 PMIC 寄存器的 `PLUG_IN_STS` 位**，那是芯片自己采样的，
不会残留。

同理 `battery/status` 也不可靠，实测遇到过
`status=Charging` 但 `current_now = -785000`（在放电）。
**判据一律以电流方向为准。**

**验证记录**：

```
没插线：         red=0 blue=0                    （全灭）
DC 口插入：f0=0xc0, cur=+1,923,000  -> red=1     （红灯亮）
OTG 口插入：f0 无插线位, cur=-520,000 -> blue=1  （蓝灯亮）
拔掉：           red=0 blue=0                    （全灭）
```

---

## 4. 返回键 / M 键搞不懂 —— 已理清

三种"返回"混在一起是根本原因，先把语义定死：

| 键 | 位置 | DTS 里的键码 | 现在翻译成 |
| --- | --- | --- | --- |
| **M 键** | 左侧摇杆与方向键之间、靠近屏幕那颗小键 | `KEY_MUTE(113)` | **BACK** |
| **返回键** | 机身 | `KEY_ESC(1)` | **BACK**（短按）／长按 1.5 秒退出游戏 |
| **手柄 Guide** | 手柄区 | `BTN_MODE(316)` | **HOME**（回桌面） |

**改动**：

- `adc-keys.kl`：`key 1 BACK` / `key 113 BACK`（原来是 MENU）
- 清掉 `persist.gammaos.gamepad.remap_btn` 里的 `316:158,704:158`
  残留（`704 = BTN_TRIGGER_HAPPY1`，`swap_start_home=0` 时用不到）
- 新增 `/vendor/bin/ngp-navkey.sh`：`KEY_ESC` 按住 ≥1500ms 且前台不是桌面时
  `am force-stop` + 回 LANGOS；短按只读不写，BACK 由 keylayout 正常发出

**顺带修正**：`adc-keys` 的音量键阈值原来是反的。

```
EE:   vol-up = 300000, vol-down = 17000
我们: vol-up =  17000, vol-down = 300000   <- 按加号变小声
```

17 个 GPIO 键与 EE 逐项核对，**完全一致**，没有需要改的。

**悬案**：`gpio1_C7`（gpio-55）映射到 `BTN_MODE`，但官方按键标注图上
没有任何对应位置，孤立在 gpio1 组最前面。待实测确认物理归属。

---

## 5. 摇杆灯设置中文化

「设置 → 掌机设置 → joystick led」打开的是 `com.gammaos.joystickled`。

这个 App **自带 `values-zh-rCN`**，界面绝大多数已经是中文，
实测只有右上角预览标签是英文 —— 因为它是拼在 Kotlin 代码里的：

```kotlin
"Preview (" + String.format("#%06X", color) + ")"
```

**改法**：默认值与 `values-zh-rCN` 各加一条 `preview_label`
（`Preview` / `预览`），资源 ID 在 `public.xml` 里固定为 `0x7f0f00a1`，
smali 里改调 `getString()`。

**为什么不能直接换 `/system/app` 里的 apk**：

- `/system` 是 `mmcblk1p4` 以 **ro** 挂载，`mount -o remount,rw /` 直接失败
- 不是 verity（`ro.boot.veritymode=disabled`），不是 SELinux（`Permissive`），
  块设备 `ro=0` —— 真因是 **ext4 超级块带错误标志**：

```
EXT4-fs (mmcblk1p4): error count since last fsck: 27
EXT4-fs (mmcblk1p4): initial error at time 1792543475: ext4_find_extent:928: inode 4336
```

- `pm install -r` 也不行：系统版用的是 AOSP 公共测试密钥
  （`CN=Android, android@android.com`，序列号 `b3998086d056cffa`），
  私钥不在手上，自签的包装上去签名对不上

所以走 **bind mount 单个文件**，和 `azahar-nano-zh` 同一路数：

```
/vendor/etc/ngp/JoystickLedPicker-zh.apk
        ↓ mount --bind（ngp-fixup.sh 第 ⑩ 段，boot_completed 时）
/system/app/JoystickLedPicker/JoystickLedPicker.apk
```

**验证**：截图前后对比，`Preview (#B30000)` → `预览 (#B30000)`，
界面其余部分本来就是中文。切换效果按钮后
`persist.gammaos.rgb.effect` 从 `2` → `1` → `2`，功能完好。

---

## 6. 两个 Type-C 口的分工（实测结论）

| 口 | 角色 | 数据 | 供电 | 给电池充电 |
| --- | --- | --- | --- | --- |
| **OTG 口** | 数据 + 供电 | 有（插上会切 host，ADB 会断） | 2500 mA 限流 | **不能**（`PLUG_IN_STS=0`） |
| **DC 口** | 充电 | 无 | 有 | **能**（`CHG_STS=3`，+1.88 A，5 W） |

接 DC 口时实测充电功率 **5 W**，与用户观察一致。

---

## 文件清单

```
kernel-patches/rk3562-ngp45ht.dts        摇杆灯 SPI0 + gpio-leds + 按键 + 电池参数
powerled/ngp-powerled.sh                 状态灯守护
powerled/ngp-powerled.rc
scripts/ngp-navkey.sh                    返回键长按退出
scripts/ngp-navkey.rc
ime/ngp-fixup.sh                         第 ⑩ 段：摇杆灯设置汉化 bind
keylayout/adc-keys.kl                    M 键/返回键 → BACK
apps/JoystickLedPicker-zh.apk            摇杆灯设置中文版
apps/README.md                           汉化过程与绕过只读的完整说明
doc/KEYMAP.md                            按键总表 + 实测电平
stickled/                                WS2812 用户态工具
scripts/build_v33.sh                     v33 镜像构建
```
