# v37 更新说明（2026-11-05）

## 一句话

HDMI 输出满屏 + LANGOS 大屏布局改 5 列；顺带修掉「覆盖升级装不上新 LANGOS」的坑。

## 一、HDMI 不满屏（黑边）

现象：插 HDMI 到 1080p 显示器，游戏画面左右各 240px 黑边，只有中间 4:3 一块。

**先排除的**：HDMI 输出确实是 1080p —— VOP `1920x1080p60`、RK628 in/out 均
`1920x1080p60`、clk 148500，一路对到底。

**真因有两层**：

1. RK3562 只有一个 VOP（Video Port0），DSI 内屏与 RK628D HDMI 共用。HDMI 接入时
   HWC 把 VOP 抢给 HDMI，但 **App 的 Window 仍挂在 display 0（内屏）上**：
   ```
   mDisplayId=0 Requested w=1024 h=768
   ```
   → PPSSPP 就算内容是 16:9，它的 Surface 也只有 1024×768。
2. SurfaceFlinger 走镜像合成（`toInternalDisplay=true`），把 1024×768 的源
   **等比**塞进 1920×1080：
   ```
   sourceCrop  =[0,0,1024,768]
   displayFrame=[240,0,1680,1080]
   ```
   上下方向没占满、左右各空 240px，就是看到的黑边。

**修法**：HDMI 接入时把逻辑分辨率切成 16:9 的 `1366×768`，Window 变成 16:9，
镜像后正好铺满 1920×1080。

```sh
wm size 1366x768    # HDMI 接入
wm size reset       # 拔线复位
```

实测 `displayFrame` 从 `[240,0,1680,1080]` 变成 `[0,0,1920,1080]`，**满屏零黑边**。

> 为什么不是 `1920x1080`？实测 `wm size 1920x1080` 会把 system_server 打崩
> （`service list` 从 233 掉到 47，`Can't find service: window`），等 init 自动重启
> 约 12 秒才恢复。`1366×768` 是同比例下的安全上限。

新增 `/vendor/bin/ngp-hdmi-ratio.sh` + `/vendor/etc/init/ngp-hdmi-ratio.rc`，
开机 `late_start` 起 `watch` 服务，每 3 秒比一次
`/sys/class/drm/card0-HDMI-A-1/status`，状态变化才动手（插线后多等 2 秒，
等 HWC 把 VOP 切过去）。

三态实测：

| 状态 | override | VOP | 内屏 | HDMI |
|---|---|---|---|---|
| 无 HDMI | 无 | 1024×768p61 | 1:1 满屏 | — |
| 插 HDMI | 1366×768 | 1920×1080p60 | 上下各 96px | **1:1 满屏** |
| 拔 HDMI | 已清空 | 1024×768p61 | **1:1 满屏** | — |

> 插着 HDMI 时内屏会被压扁（上下各 96px）。这是单 VOP 的物理限制，两个屏
> 共用一个时序，只能取交集。

## 二、LANGOS 在 HDMI 上仍 4 列

`getScreenRatio()` 用的是 `getDisplayMetrics()`，拿到的永远是**镜像源**尺寸
1024×768，ratio 恒为 `1.333`；而 `getHomeColumns()` 虽然算出了 ratio，
却直接 `return 4`。

改动两处（`NativeActivity.smali`）：

1. `getScreenRatio()`：先扫 `DisplayManager.getDisplays()`，只要存在
   `displayId != 0` 的显示就直接返回 `1.7777778f`（16:9），否则回落到
   `widthPixels/heightPixels`。
2. `getHomeColumns()`：去掉硬编码 4，改用与 `getGameColumns()` 同一判据
   （ratio ≥ 1.7f → 5 列）。

实测内屏 4 列、HDMI 5 列。

## 三、覆盖升级时新 LANGOS 装不上（顺带修）

`ngp-fixup.sh` 原来判断「要不要装新 LANGOS」用的是**路径**：

```sh
if dumpsys package com.retrofront | grep -q "codePath=/data/app"; then
    : # 已经是更新版，不用重复装
```

从 v36 或更早版本**覆盖升级**上来的机器，`/data/app` 里已经有上一版，
这段直接跳过 `pm install -r` —— **新版 APK 永远装不上**。本轮的新 LANGOS
就会因此静默失效。

改成**内容比对**：

```sh
want=$(md5sum "$NGP_DIR/LANGOS.apk" | awk '{print $1}')
apk_path=$(pm path com.retrofront | sed -n 's/^package://p' | head -1)
[ -n "$apk_path" ] && have=$(md5sum "$apk_path" | awk '{print $1}')
if [ -n "$want" ] && [ "$want" = "$have" ]; then
    : # 已是最新版
else
    pm install -r "$NGP_DIR/LANGOS.apk"
fi
```

`pm path` 拿不到（未安装 / 被禁用）视为不一致，照样走安装。

## 四、验证

| 项 | 结果 |
|---|---|
| 4 MiB 分块比对 | 5 块（879/901/943/948/949），**全在 p5 vendor，分区外 0 块** |
| 镜像大小 | 5,451,564,032 B（与 v36 同尺寸） |
| p5 内文件回读 | LANGOS.apk `f9403a88…`、ngp-hdmi-ratio.sh `1b8bb671…`、rc `a4197865…`、ngp-fixup.sh `09a04565…` 全部 OK |
| e2fsck | 干净（1472/3920 文件，1.4% 不连续） |
| 分区表 | 9 个分区几何与 v36 完全一致 |
| DTB / 内核 | **未改动**（p3 一字节未变） |

## 五、升级注意

- 只改 p5 vendor，**userdata 不动，存档和设置都在**
- LANGOS 由 `ngp-fixup` 开机 `pm install -r` 装入 `/data/app`，
  本版起会按 md5 判断，覆盖升级也能自动换成新版；首次开机请等 10 秒左右
- 插上 HDMI 后约 2~3 秒画面才会切到满屏，这是 `watch` 的轮询间隔，正常

## 六、已知未做

### 息屏休眠失败（未修，沿用 v36 结论）

`/sys/power/suspend_stats` 实测 `success=0 / fail=143`，
`last_failed_dev=alarmtimer.0.auto`、`errno=-16 (EBUSY)`。
手动 `echo mem > /sys/power/state` 能成功一次，但随后 OTG 口挂死不恢复。
本版**没有**动 suspend 相关任何代码。

### HDMI 独占 1080p 模式

让 HDMI 把内屏完全关掉、独占 1080p 的路线已验证不可行：
`setprop vendor.hwc.device.display-0 release` 会把 DSI 和 HDMI **一起关掉**
（两个都 `dpms=Off`、`Video Port0: DISABLED`），只能
`setprop ctl.restart vendor.hwcomposer-2-1` 救回。
