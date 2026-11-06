# HDMI 16:9 逻辑分辨率（ngp-hdmi-ratio）

## 问题
PSP 是 16:9（480×272），但在 HDMI 上播放时左右留 240px 黑边，无法全屏。

## 根因（实测，链路分两层）

### 第一层：窗口尺寸被 4:3 内屏卡死
```
$ dumpsys window windows | grep ppsspp
  mDisplayId=0  Requested w=1024 h=768
  mBounds=Rect(0, 0 - 1024, 768)
```

PPSSPP 的 Window 挂在 **display 0（内屏 1024×768，4:3）** 上，因为它是从内屏启动的。
RK3562 单 VOP，HDMI 接上时 HWC 把 VOP0 让给 HDMI 出 1920×1080，但 App 的窗口
仍然属于 display 0，最大只能 1024×768。

于是 PPSSPP 的 SurfaceView 缓冲区是 **1024×768**，PSP 的 16:9 在第一层就丢了。

### 第二层：SurfaceFlinger 按 4:3 等比镜像
```
Output Layer SurfaceView[org.ppsspp.ppsspp](BLAST)
  sourceCrop   = [0, 0, 1024, 768]        ← 4:3
  displayFrame = [240, 0, 1680, 1080]     ← 按 4:3 等比进 1920×1080
```

左右各 240px 黑边就是这么来的。

**PSP 的 16:9 与黑边无关** —— 黑边是容器比例造成的，不是内容比例。

## 修复
把逻辑分辨率切成 **1366×768（16:9）**，让 App 窗口本身变成 16:9：

```
$ wm size 1366x768
```

之后 SF 变成：

| 显示 | sourceCrop | displayFrame | 效果 |
|---|---|---|---|
| HDMI 1920×1080 | 1366×768 | `[0,0,1920,1080]` | **满屏零黑边** |
| 内屏 1024×768 | 1366×768 | `[0,96,1024,671]` | 上下各 96px 黑边 |

内屏会变差，所以**只在 HDMI 连接时切**，拔掉立刻复位。

## 为什么是 1366×768 不是 1920×1080
`wm size 1920x1080` 会让 **system_server 崩**：
`service list` 从 233 掉到 47，`cmd: Can't find service: window`。

1366×768 像素总量接近物理值（约 1.05M vs 0.79M），实测稳定：
233 个服务不变，无 WATCHDOG、无 FATAL。

## 实测结果

| 状态 | override | VOP | 内屏 | HDMI |
|---|---|---|---|---|
| 无 HDMI | 无 | 1024×768p61 | 1:1 满屏 | — |
| 插 HDMI | 1366×768 | 1920×1080p60 | 上下 96px | **1:1 满屏** |
| 拔 HDMI | 已清空 | 1024×768p61 | **1:1 满屏** | — |

日志：
```
I ngp-hdmi-ratio: HDMI in -> 1366x768
I ngp-hdmi-ratio: HDMI out -> reset
```

## 文件
- `device/ngp45ht/hdmi/ngp-hdmi-ratio.sh` → `/vendor/bin/`
- `device/ngp45ht/hdmi/ngp-hdmi-ratio.rc` → `/vendor/etc/init/`

脚本三个入口：

| 命令 | 用途 |
|---|---|
| `ngp-hdmi-ratio.sh start` | 开机按当前状态对齐一次 |
| `ngp-hdmi-ratio.sh watch` | 常驻轮询（3s），热插拔切换 |
| `ngp-hdmi-ratio.sh status` | 打印 hdmi/physical/override/vop |

## 注意
- 切换瞬间 system_server 重建 display 配置，界面会闪一下，属正常
- **游戏全屏运行时不要切**，游戏窗口会跟着变尺寸
- PPSSPP 自身设置无需改动：`DisplayStretch=False`、`DisplayAspectRatio=1.0`
  是对的，容器变成 16:9 后 16:9 的内容自然铺满；4:3 的 PSP 游戏仍会留黑边
  （这是内容比例，不是容器问题）
- `wm size reset` 会让 system_server 短暂重启，等约 10 秒恢复
