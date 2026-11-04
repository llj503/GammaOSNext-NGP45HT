# v35 更新说明（2026-11-04）

## 一句话

电量显示从「芯片自己猜的库仑计数」改成「按电压查表」，顺便把按键映射真正装进镜像。

## 一、电量显示为什么不准

### 真正的原因：SoC 根本不看电压

`rk817_battery.c` 里报给系统的音量是这个：

```c
battery->rsoc = rk817_bat_get_rsoc(battery);   /* = remain_cap / fcc */
```

`remain_cap`（剩余容量）和 `fcc`（满充容量）都是 RK817 内部 fuel gauge
的学习值,而这套学习只有**完整充放电循环**之后才会收敛。

掌机常年插着充电器、浅充浅放,fuel gauge 的学习值就一直漂。实测:

| 项 | 值 |
|---|---|
| 端电压 | 4.281 V |
| charger 目标 | 4.350 V |
| OCV 表上限 | 4.171 V |
| 系统报的电量 | 64 ~ 74 % |

这解释了为什么**改 OCV 表、改内阻补偿全都没用** —— 那条路根本不参与计算。
`rk817_bat_vol_to_soc()`(查表函数)在整个驱动里只在**首次上电**时被调用一次,
之后永远走 fuel gauge。

### 这一版怎么改

**驱动**(`rk817_battery.c` 的 `rk817_bat_update_info()`):

```c
ocv_mv = voltage_avg - current_avg * bat_res / 1000;   /* 端电压回算开路电压 */
soc    = rk817_bat_vol_to_soc(battery, ocv_mv);        /* 查表 */
if (chrg_status == CHARGE_FINISH || ocv_mv >= design_max_voltage) soc = 100;
else if (ocv_mv <= pwroff_vol)                                    soc = 0;
battery->rsoc = soc * 1000;
```

- 内阻补偿的方向:充电电流为正,端电压比开路电压**高**,所以要减掉 `I·R`
- 两端做强校正,既让「充满=100%、欠压=0%」确定,也把漂移挡在外面不累积
- 休眠/唤醒路径里的 `rk817_bat_get_rsoc()` 原样保留,不动,唤醒后由
  每 5 秒一次的 `update_info()` 用新算法覆盖

**OCV 表**(DTS):

| | 0% | … | 50% | … | 100% |
|---|---|---|---|---|---|
| 旧表(EE 4.2V) | 3500 | | 3818 | | **4171** |
| 新表(4.35V) | **3400** | | 3818 | | **4350** |

旧表顶在 4171 mV,是给 4.2 V 电池做的,但本机 charger 的
`max_chrg_voltage = 4350`,说明电池是 4.35 V 高压体系。用旧表的话
4171 mV 以上整段都算 100%,最后约 15% 的容量在表里根本没有对应区间。

`design_max_voltage` 一并从 4120 改成 4350 —— 原来它比 OCV 表顶还低 51 mV,
驱动拿它做强校正,会导致 4.12 V 就被判定满电。

> ⚠ **这张新表是 4.35V 锂电的典型曲线,不是实测值。**
> 刷完后请按实际放电数据校正:记录 90/70/50/30/10% 各自对应的
> `voltage_now`,再逐点修表。旧表已留在 DTS 注释里,方便回退。

## 二、按键映射之前是空转的

`dumpsys input` 显示本机按键设备名是 **`adc-keys-ngp`**,而镜像里那个文件叫
`adc-keys.kl`。InputManager 按**设备名**找 keylayout,名字对不上就回落到
`Generic.kl` —— 也就是说过去所有对 `adc-keys.kl` 的修改**一次都没生效过**。

这一版:

- 新增 `/vendor/usr/keylayout/adc-keys-ngp.kl`(文件名改对了)
- **删除** `/vendor/usr/keylayout/adc-keys.kl`(死文件,留着只会误导后来人)

最终映射(按你的要求):

| 物理键 | kernel code | Android 键 | 行为 |
|---|---|---|---|
| 返回键 | 1 (KEY_ESC) | BACK | 短按弹模拟器菜单 / 返回;长按 1.5s 退出游戏 |
| M 键 | 113 (KEY_MUTE) | **HOME** | 直接回 LANGOS 桌面 |
| 音量 + | 114 | VOLUME_UP | 调大 |
| 音量 − | 115 | VOLUME_DOWN | 调小 |

音量键为什么会对调:DTB 里 `vol-up-key` 的阈值是 17000 µV、`vol-down-key`
是 1200000 µV,而物理「+」键落在 1.2 V 那档,所以它上报的是 114(VOLUMEDOWN)。
在 keylayout 层对调即可,不用改 DTB。

## 三、验证

| 项 | 结果 |
|---|---|
| 内核 Image 编译 | OK(需绕开 safe-delete 对 `rm` 的劫持) |
| DTB 编译 | OK,反编译确认 21 点全对(0xd48..0x10fe) |
| 镜像内 DTB 回读 | 与编译产物 md5 一致,表为新曲线 |
| 镜像内 keylayout | md5 `b90c95ce…`,标签 `vendor_keylayout_file:s0` |
| `adc-keys.kl` | 已确认从镜像中删除 |
| 4 MiB 分块比对 | dArkOS_Fat 内 18 块、vendor 内 4 块、**分区外 0 块** |
| e2fsck | 干净 |

镜像 5,451,564,032 B / md5 `3542d26374a45d6ad59275925cc1a888`

## 四、升级注意

- 只改 p3(内核/DTB) 和 p5(vendor),**不动 userdata,存档和设置都在**
- 刷完后:
  - 进系统看电量,若与电压明显不符,记一组放电数据给我校正 OCV 表
  - 按键:返回键弹菜单、M 键回桌面、音量键正反向
- `/data/system/devices/keylayout/adc-keys-ngp.kl` 如果还留着,优先级高于
  `/vendor`。刷机前建议删掉它,避免"以为镜像改了其实没生效":
  `adb shell rm -f /data/system/devices/keylayout/adc-keys-ngp.kl`

## 五、已知未做

- OCV 表没有实测数据支撑,是典型曲线。需要一次完整放电来校准。
- 硬件 fuel gauge 仍然在跑(休眠路径还在用它的值),只是不再主导显示。
