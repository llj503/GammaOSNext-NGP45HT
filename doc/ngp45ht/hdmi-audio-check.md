# NGP45HT HDMI 音频排查手册

**结论先行：本机 HDMI 音频通路是好的，不需要修。**
这份文档记录一次完整排查的路径与判据，避免下次再从零开始。

## 一、三行判据

HDMI 没声音时，按顺序跑这三条，能定位到具体是哪一层：

```bash
# 1. 有没有音频流进来（最关键）
adb shell head -1 /proc/asound/card1/pcm0p/sub0/status
#    期望：state: RUNNING
#    closed = Android 根本没往 HDMI 送音频，往下查路由/应用

# 2. Android 路由对不对
adb shell dumpsys media.audio_flinger | grep 'Output devices'
#    期望：0x400 (AUDIO_DEVICE_OUT_HDMI)
#    是 0x2 (SPEAKER) = 路由没切

# 3. RK628 芯片静音位
adb shell grep '^0x70010:' /sys/kernel/debug/rk628/3-0050/registers/hdmi
#    期望：播放中第 2 个值为 00000000
#    00000006 = AUDIO_MUTE(1) + AUDIO_PD(1)，即被静音且掉电
```

三条全过还是没有声音，才需要怀疑硬件（那是另一回事，见文末）。

## 二、RK628 寄存器地址算法（★ 容易算错）

```c
#define HDMI_BASE        0x70000
#define HDMI_REG_STRIDE  4
#define HDMITX_REG(x)    ((x * HDMI_REG_STRIDE) + HDMI_BASE)
```

**是 `x * 4 + 0x70000`，不是 `0x70000 + x`。**
`AUDIO_SAMPLE_RATE` 在 `0x700dc`，不是 `0x70037`。按字节偏移读会得到全 0，
从而误判成"音频从未配置"。

debugfs 文件每行 4 个 32 位值、地址标签步进 `0x10`：
```
0x700d0: 00000000 00000001 00000040 00000002
           ^0x700d0  ^0x700d4  ^0x700d8  ^0x700dc
                     CTRL1             SAMPLE_RATE
```

## 三、关键寄存器与正常值（48kHz / 2ch 立体声）

| 寄存器 | 地址 | 正常值 | 含义 |
|---|---|---|---|
| `HDMI_AV_MUTE` | `0x70014` | 播放中 `0x00`，空闲 `0x06` | bit2=AUDIO_PD, bit1=AUDIO_MUTE |
| `HDMI_AUDIO_CTRL1` | `0x700d4` | `0x01` | bit7 CTS源(0=内部), bit4:3 源(0=I2S), bit1:0 MCLK比率 |
| `AUDIO_SAMPLE_RATE` | `0x700dc` | `0x02` | 0x00=44.1K, 0x02=48K, 0x03=32K, 0x0a=96K |
| `AUDIO_I2S_MODE` | `0x700e0` | `0x04` | bit5:2 通道(1=1/2ch), bit1:0 模式(0=标准 I2S) |

## 四、Android 音频策略的分工（正常行为，不是 bug）

| Strategy | 输出设备 |
|---|---|
| `STRATEGY_MEDIA`（游戏/视频/音乐） | **AUDIO_DEVICE_OUT_HDMI** |
| `STRATEGY_SONIFICATION`（按键音/提示音） | SPEAKER（板载） |
| `STRATEGY_PHONE`（通话） | SPEAKER |

接 HDMI 时在桌面上点来点去是听不到按键音的 —— 只有媒体播放走 HDMI。
别把这个当成故障。

## 五、最容易误判的一种情况

**游戏/视频压根没跑起来时，Android 不会把路由从 SPEAKER 切到 HDMI**，
表现就是"HDMI 完全没声音"。

本机实际踩过：ROM 路径依赖 `mount --bind /storage/emulated/0/ROMs/ps2 /storage/emulated/0/A_PS2`，
设备重启后 bind 丢失 → 模拟器点游戏秒退（`Requested filename ... does not exist`）
→ 没有任何音频流 → 一片安静。看起来像音频坏了，实际是路径问题。

排查顺序应该是「先确认有流，再谈音质」，而不是一上来怀疑音频驱动。

## 六、驱动实现情况（不需要改）

`drivers/misc/rk628/rk628_hdmitx.c` 是完整的：

- `audio_codec_ops`（约 1015 行）注册 `hdmi_codec_pdata`，生成 `hdmi-audio-codec` 平台设备，
  被 `simple-audio-card` 当成 codec
- `rk628_hdmi_audio_config_set()`（约 844 行）写上面全部寄存器 + N 值 + AAI InfoFrame
- `rk628_hdmi_setup()`（约 575 行）在 `bridge_enable` 时补配置，
  解决单 VOP 机型上 `hw_params` 早退的问题（上游 mamaich 的 RG52 补丁）
- `hw_params` 里 `if (!hdmi->bridge.encoder->crtc) return 0` 是**有意设计**：
  返回 0 避免 Android 关掉流，实际配置留给 `rk628_hdmi_setup()`

DTS 侧 `rk628-sound`（`simple-audio-card`, format=i2s, mclk-fs=128, name=rockchip,hdmi-rk628）
与 EE 原厂一致。SAI2 的 pinctrl 只需 LRCK/SCLK/SDO 三根 —— **RK628 的 I2S 没有 MCLK 引脚**。

## 七、已排除的错误方向（省下重新怀疑的时间）

| 怀疑点 | 为什么不是 |
|---|---|
| audio_policy 类型不匹配（`AUX_DIGITAL` vs `HDMI`） | 框架实测已识别为 `AUDIO_DEVICE_OUT_HDMI`（Port ID 9） |
| `attachedDevices` 没列 `HDMI Out` | HAL 动态上报 extcon1，不影响路由 |
| MCLK 引脚缺失 | RK628 的 I2S 只有 SCK/D/LR 三根，没有 MCLK |
| `GRF_SYSTEM_CON3` 引脚复用 | 只用于 RK628F 的 DSI 模式，I2S 是固定功能 |
| `sink_has_audio = false` | 日志无 "Sink do not support audio"，EDID 有 5 个 SAD |
| EDID 不支持音频 | `05ac:3000` 的 CEA-861 扩展块含 LPCM 2ch 32~192kHz |

## 八、验证记录（2026-11-04）

ARMSX2 跑《God of War II》与影视仓播片时：

```
card1 (HDMI):  state RUNNING, 48000Hz S16_LE 2ch
card0 (rk817): closed
AudioFlinger:  0x400 (AUDIO_DEVICE_OUT_HDMI)
RK628:         AV_MUTE=0x00, SAMPLE_RATE=0x02, I2S_MODE=0x04
```

媒体音频正确走 HDMI，板载 codec 不占用。
