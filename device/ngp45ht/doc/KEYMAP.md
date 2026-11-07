# NGP45HT 物理按键总表

依据：官方「按键标注」图（1688 商品图）+ 实测 evdev 码 + 原厂 EmuELEC DTS。
图上每一颗键在下面都有明确归属，没有归属的就是「DTS 未配置」。

---

## 一、正面面板

| 位置 | 图上名称 | 通路 | 内核码 | keylayout | Android 侧 | 状态 |
|---|---|---|---|---|---|---|
| 左上 | 氛围灯 | SPI0 WS2812 | — | — | `ws2812-common` | ✅ 已通 |
| 左摇杆上方 | 左摇杆（带氛围灯圈） | ADC `saradc0 ch0/ch1` | `ABS_X`/`ABS_Y` | — | 左摇杆 | ✅ |
| 左摇杆上方（红色圈） | **电源键** | `rk805 pwrkey` | `KEY_POWER(116)` | — | 电源/息屏 | ⚠️ 待确认 |
| 左侧边，电源键下 | **复位键** | **无** | — | — | — | ❌ **DTS 未配置** |
| 左侧 | 十字键 | GPIO `gpio0_B5/B6/B3/B4` | `BTN_DPAD_*`→`ABS_HAT0X/Y` | — | D-Pad | ✅ |
| 屏幕下居中 | **M 键** | **ADC 电阻梯** | `KEY_MUTE(113)` | `key 113 UNKNOWN` | 单击 HOME / 双击无动作 / 长按 MENU | ✅ 已修 |
| 屏幕下左侧 | 喇叭 | — | — | — | — | — |
| 右侧四色 | Y/X/A/B | GPIO `gpio2_A1/PA0`、`gpio0_C5/PC3` | `BTN_WEST/NORTH/SOUTH/EAST` | `key 30x BUTTON_*` | 面键 | ✅ |
| 右侧 | 右摇杆（带氛围灯圈） | ADC `saradc0 ch2/ch3` | `ABS_RX`/`ABS_RY` | — | 右摇杆 | ✅ |
| 右摇杆上方 | **返回键** | **ADC 电阻梯** | `KEY_ESC(1)` | `key 1 UNKNOWN` | 单击 BACK / 双击无动作 / 长按终止前台应用 | ✅ 已修 |
| 返回键上方 | **电源指示灯** | rk817 硬件 | `CHG_STS` | — | — | ✅ 见下文 |
| 顶部左 | 选择键 | GPIO `gpio0_A5` | `BTN_SELECT(314)` | `key 314 BUTTON_SELECT` | SELECT | ✅ |
| 顶部右 | 开始键 | GPIO `gpio3_A6` | `BTN_START(315)` | `key 315 BUTTON_START` | START | ✅ |
| 底部中 | 振动马达 | GPIO `gpio0_B7` | — | — | 震动 | ✅ |

> **注意**：`gpio1_C7`（gpio 全局号 **55**，第 15 个 GPIO 键，映射为 `BTN_MODE`）
> 在图上**没有对应标注**。
>
> 实测电平表（全部按键松开态，共 17 个 `|key` 条目）：
>
> | gpio 号 | 引脚 | 图上按键 |
> |---|---|---|
> | 5 | `gpio0_A5` | 选择键 |
> | 11-14 | `gpio0_B3/B4/B5/B6` | 十字键 |
> | 19 | `gpio0_C3` | B |
> | 21 | `gpio0_C5` | A |
> | 22, 23 | `gpio0_C6/C7` | L3 / R3 |
> | **55** | **`gpio1_C7`** | **？（图上无标注）** |
> | 57, 58, 59 | `gpio1_D1/D2/D3` | L1 / L2 / R1 |
> | 60 | `gpio1_D4` | R2 |
> | 64, 65 | `gpio2_A0/A1` | X / Y |
> | 102 | `gpio3_A6` | 开始键 |
>
> gpio-55 孤立在 gpio1 组的**最前面**（55 → 57 → 58 → 59 → 60），
> 位置关系暗示它可能是「第 5 个肩键」或者**电源键/复位键的 GPIO 备选**，
> 但图上没有任何标注。这颗键的实际物理位置**待实测确认**（按住某个
> 无标注的键，看 gpio-55 是否由 hi 变 lo）。
>
> 它同时是 gammapad 眼里的 Guide 键。之前 `remap_btn=316:158` 把它
> 改成了 BACK，是「M 键行为混乱」的来源之一，现已清除。

---

## 二、机身侧面

| 位置 | 图上名称 | 通路 | 状态 |
|---|---|---|---|
| 左侧边 | **音量键**（双向拨动） | ADC 电阻梯 `KEY_VOLUMEUP/DOWN` | ✅ 阈值已按 EE 修正 |
| 左侧边 | 挂绳孔 | — | — |
| 底部左 | **TF1 OS 卡** | SDMMC | ✅ 系统盘 |
| 底部中左 | **OTG 接口**（Type-C） | DWC3 `dr_mode=otg` | ✅ |
| 底部中 | **电源口**（Type-C DC） | rk817 DC 通路 + `GPIO3_A7` 检测 | ✅ |
| 底部中右 | **TF2 游戏卡** | SDMMC | ✅ |
| 底部右 | **耳机孔** | `gpio0_A6` 检测 + rk817 codec | ✅ |
| 底部右 | **HDMI**（迷你 HD 转标准 HD） | RK628D 桥 | ✅ 已打通 |
| 左下 | L1 / L2 | `gpio1_D1` / `gpio1_D2` | ✅ |
| 右下 | R1 / R2 | `gpio1_D3` / `gpio1_D4` | ✅ |

> **两个 Type-C 口的区别**（用户确认 + 实测）：
> - **OTG 口**：数据 + 充电都走这里，`usb/online` 由 BC 检测判定
> - **电源口（DC）**：纯充电，`dc_det_gpio = GPIO3_A7` 检测，插上拉高
>
> 只插 OTG 时 `GPIO3_A7` 保持低电平 → `dc_charger = DC_TYPE_NONE_CHARGER`
> → 触发 `rk817_charge_usb_init()` 里那个 **永远为假的 if**（见下方"充电状态误报"）。

---

## 三、背面

| 位置 | 图上名称 | 说明 |
|---|---|---|
| 左侧边 | 音量键 | 与侧面表同一条 |
| 中部 | 散热孔 | — |
| 中部 | 电池 | rk817 battery，`design_capacity=3791` |
| 四角 | 防护垫 / 防滑垫 | — |

---

## 四、氛围灯分布（三处）

图上有**三个**「氛围灯」标注：

1. **左摇杆圈** —— WS2812
2. **右摇杆圈** —— WS2812
3. **机身左上角长条** —— WS2812（图上标在左摇杆上方，长条形状）

三者是**同一条 SPI0 WS2812 链**串联。灯珠数不是固定的 8 颗，
需要按实际串联数配置 `--leds N`：

```
# 单灯验证（红）
/vendor/bin/ws2812-common --device /dev/spidev0.0 --leds 8 color FF0000
# 逐颗点亮找总数
for n in 1 2 4 8 16 24 32; do
    /vendor/bin/ws2812-common --device /dev/spidev0.0 --leds $n color 0000FF
    sleep 1
done
```

用户已实测「先绿后蓝，都对」，说明至少 2 颗；实际颗数待确认后
写进 `persist.gammaos.stickled.leds`。

---

## 五、充电状态误报（本表最重要的一节）

### 硬件侧事实（寄存器实测）

| 寄存器 | 位 | 值 | 含义 |
|---|---|---|---|
| `0xE4` | bit7 | 1 | `CHRG_EN` 充电使能 |
| `0xEB` | bit[6:4] | **0** | `CHG_STS` = **未在充电** |
| `0xEB` | bit7 | 1 | `BAT_EXS` 电池在位 |
| `0xF0` | bit6 | **0** | `PLUG_IN_STS` = **未插充电器** |

### 软件侧事实

| sysfs | 值 | 判断 |
|---|---|---|
| `usb/online` | 1 | ❌ 误报 |
| `ac/online` | 0 | 正确（没插 DC） |
| `battery/status` | Charging | ❌ 误报 |
| `battery/current_now` | -783000 | 正确（在放电） |
| `battery/charge_counter` | 1 | 佐证只切过一次 |

### 根因

`rk817_charger.c` → `rk817_charge_usb_init()`：

```c
charge->usb_charger = charger;
if (charge->dc_charger != DC_TYPE_NONE_CHARGER)   /* ← 本板永远为假 */
        rk817_charge_set_chrg_param(charge, charge->usb_charger);
```

本板无 DC 输入时 `dc_charger` 恒为 `DC_TYPE_NONE_CHARGER`，
这个 `if` 永远不成立 → `usb_in` 从未被赋值 → 停留在结构体初值（实测落成 1）。

`dc_det` 中断救不了：`/proc/interrupts` 里 `rk817_dc_det` 计数 **恒为 0**，
`GPIO3_A7` 一直低电平没有边沿，那个能在 `PLUG_IN_STS=0` 时清零
`usb_in` 的 worker 永远不跑。

### 修法

改成**无条件调用**。`set_chrg_param()` 内部自己看 `dc_in`：
无 DC 且 `!PLUG_IN_STS` 时把 `ac_in`/`usb_in` 一起清零。
原代码担心的「USB 覆盖 DC 判定」不会发生。

---

## 六、M 键 / 返回键的多击与长按

`adc-keys` 驱动只报 `KEY_MUTE(113)` / `KEY_ESC(1)` 的按下、松开，
不认识单击/双击/长按，也不会替你做计时。所以 keylayout 把这两个键
映射成 `UNKNOWN`（Android 不直接发 HOME/BACK），由 userspace 守护
`/vendor/bin/ngp-navkey.sh` 读原始事件后合成：

| 按键 | 单击 | 双击 | 长按 |
|---|---|---|---|
| M 键 | HOME | 无动作 | MENU |
| 返回键 | BACK | 无动作 | 终止前台应用（`am force-stop`，回 LANGOS） |

- 单击要等 300ms 双击窗口过去才发，否则双击的第一下会先触发单击；
- 长按阈值：M ≥600ms，返回 ≥1500ms（返回键会杀应用，留长一点）；
- 监听 `/dev/input/event2`（adc-keys-ngp），按设备名找节点，不硬编码 event 号；
- 返回键长按在前台是 LANGOS/`android` 时不做任何事。
