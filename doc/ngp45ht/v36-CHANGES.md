# v36 更新说明（2026-11-05）

## 一句话

修三个小毛病：LANGOS 电量不刷新、满电后仍谎报「正在充电」、摇杆灯点「关闭」关不掉。

## 一、LANGOS 桌面电量不刷新

`NativeActivity$timeUpdateRunnable` 每 30 秒读一次 `/sys/class/power_supply/battery/capacity`，
读到的值也确实算好了字符串 —— 但更新 TextView 的条件写反了：

```smali
sget-object v0, Lcom/retrofront/NativeActivity;->ngpBattText:Landroid/widget/TextView;
if-nez v0, :cond_3a     # 原：view 为空才 setText
invoke-virtual {v0, v5}, Landroid/widget/TextView;->setText(Ljava/lang/CharSequence;)V
```

`if-nez` 意味着只有 view **不存在**时才走 setText —— 而 view 正常存在，
于是每次都跳到 `:cond_3a` 跳过赋值。改成 `if-eqz`（存在才赋值）：

```smali
if-eqz v0, :cond_3a
```

安全性已核：定时器启动和 `ngpBattText` 赋值同在 `onCreate` 内，
首次 `postDelayed` 30 秒后才执行，那时字段早已赋值，`if-eqz` 分支不会空指针。

> 装法沿用 v32 的做法：apk 放在 `/etc/ngp/LANGOS.apk`，
> `ngp-fixup` 开机用 `pm install -r` 装进 `/data/app`，不换 `/system/app`。

## 二、满电后 ac / usb 仍报 Charging

现象：设置里电池显示 100% / 满电，但下拉通知栏的充电提示永远不消失。

实测（满电状态）：

| 属性 | 值 |
|---|---|
| `battery/status` | **Full** |
| `ac/status` | Charging ← 错 |
| `usb/status` | Charging ← 错 |
| `0xEB` (CHG_STS) | `0xc3` → bit[6:4] = 4 = CHRG_TERM |
| `0xF0` (PLUG_IN_STS) | `0xc0` → bit6 = 1 |

根因在 `rk817_charger.c`：`ac` / `usb` 的 status 都来自 `charge->prop_status`，
而这个变量**只在 `set_chrg_param()` 里赋值** —— 也就是只在**插拔事件**时刷新。
电池从 CC 充到 CHRG_TERM 这个自然过程不触发插拔，`prop_status` 就永远停在
插电那一刻的 `CHARGING`。`battery` 那边是实时算的（`dsoc==100 -> FULL`），
两边必然分叉。

本版在 `get_property` 路径上实时判定：

```c
static int rk817_charge_report_status(struct rk817_charger *charge)
{
	if (!rk817_charge_online(charge))
		return charge->prop_status;
	if (rk817_charge_get_charge_status(charge) == CHRG_TERM ||
	    rk817_charge_get_dsoc(charge) >= 99)
		charge->prop_status = POWER_SUPPLY_STATUS_FULL;
	return charge->prop_status;
}
```

`CHG_STS == CHRG_TERM` 是硬件给的「充电终止」结论，比容量值可靠；容量 ≥99 作兜底
（覆盖 fuel gauge 卡在 99 的情况）。`ac` 和 `usb` 两个 get_property 都换成调它。

## 三、摇杆灯点「关闭」关不掉

界面点「关闭」时，写进 `persist.gammaos.primary.rgb_hex` 的**不是 `#000000`，
而是 `#010101`**（logcat 实证：`solid #010101, 16 leds`）。
`ngp-stickled.sh` 原来是严格判等：

```sh
if [ "$_hex" = "000000" ]; then ... off
```

永远不成立，于是落到静态分支推了一帧 `#010101` —— WS2812 全亮到 1/255，
肉眼看就是「灯没关」。而把亮度拉到 0% 时 `scale_color()` 把每个分量乘成 0，
才真的得到 `000000`，这就解释了「只有亮度 0% 能关灯」。

改成阈值判等（各分量都 ≤2 视为关闭）：

```sh
if [ "$_r" -le 2 ] && [ "$_g" -le 2 ] && [ "$_b" -le 2 ]; then
    kill_anim; "$BIN" --device "$DEV" --leds "$LEDS" off
fi
```

实测三条路径：

| 属性值 | logcat | 灯 |
|---|---|---|
| `#010101`（点关闭） | `near-black #010101, all off` | 灭 |
| `#000000`（亮度 0%） | `near-black #000000, all off` | 灭 |
| `#2100A9`（点开） | `solid #2100A9, 16 leds` | 亮 |

## 四、验证

| 项 | 结果 |
|---|---|
| 内核编译 | OK（`rk817_charger.o` 单编 + 完整 `make Image dtbs`） |
| 反汇编确认 | `ac_get_property` 内联后含 `cmp w0,#0x4`(CHRG_TERM) / `cmp w0,#0x62`(98) → `mov w0,#4`(FULL) |
| DTB | 编译产物 md5 `65357f8c…` 与 v35 镜像内**完全一致**，未改动 |
| LANGOS dex 回读 | 从设备 `/data/app` 拉回 base.apk，`if-eqz v0, :cond_3a` 已生效 |
| stickled 脚本 | 推 `/vendor/bin` 后实测三条颜色路径全对 |
| 4 MiB 分块比对 | dArkOS_Fat 9 块 + vendor 5 块，**分区外 0 块** |
| e2fsck | 干净（1470/3920 文件，1.4% 不连续） |
| 镜像大小 | 5,451,564,032 B（与 v35 同尺寸） |

## 五、升级注意

- 只改 p3（内核）和 p5（vendor），**不动 userdata，存档和设置都在**
- LANGOS 由 `ngp-fixup` 开机 `pm install -r` 装入 `/data/app`，首次开机请等 10 秒左右
- 摇杆灯：界面点「关闭」现在立刻灭，不用再去拉亮度 0%

## 六、已知未做

### 息屏休眠失败（未修）

`/sys/power/suspend_stats` 实测 `success=0 / fail=143`，`last_failed_dev=alarmtimer.0.auto`、
`last_failed_errno=-16 (EBUSY)`。手动 `echo mem > /sys/power/state` 能成功一次，
但随后 OTG 口挂死、adb 断开不恢复。

> ⚠ 这一版**没有**动 suspend 相关任何代码。原因是：手动触发 suspend 会让 USB
> 口挂死后需要重启整机才能继续调试，取证成本高，且目前无法确认用户侧的真实症状
> 是「息屏后电量不涨」还是「息屏掉电快」。充电本身实测是正常的
> （+1.77 A，25 分钟 65%→100%）。

### HDMI 画面异常（未修）

需要插上 HDMI 线才能取证（`card0-HDMI-A-1/status`、`vendor.hwc.device.display-1`、
RK628 寄存器）。空口无法判断。
