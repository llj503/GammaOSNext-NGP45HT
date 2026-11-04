# v34 更新说明（2026-11-04）

## 一句话

**摇杆灯现在真的能调了** —— 设置里改颜色、亮度、效果，灯带立刻跟着变。

## 根因

v33 已经把摇杆灯的硬件链路全部打通（DTB 里开了 SPI0、写了 `ws2812-common`
帧生成器和 `ngp-stickled.sh` 守护脚本），但刷完 v33 依然「调节无效」。

查下来是**两层问题叠加**：

### 第一层：文件根本没进镜像

`build_v33.sh` 的 vendor 写入清单里漏了 `stickled/` 整个目录。对比一下就很清楚：

```
$ debugfs -R "stat /bin/ws2812-common" vendor.img
文件不存在
$ debugfs -R "stat /bin/ngp-stickled.sh" vendor.img
文件不存在
```

v33 设备上 `/vendor/bin/` 只有 `ngp-powerled.sh`（状态灯），没有摇杆灯那两个。
`.rc` 也就无从启动，服务压根不存在。

### 第二层：即便文件在，上游 rg52-ledd 也不认这条灯带

上游 `rg52-ledd` 只监听 UART1（RG52Mini 的接线方式）。本机灯带挂在 SPI0，
它开机就放弃并打日志：

```
rg52-ledd: no /dev/ttyS1: UART1 is not enabled in the device tree,
           LEDs unavailable
```

于是设置界面写下的 `persist.gammaos.rgb.*` 没有任何人消费 —— 界面能改，
灯不变。`ngp-stickled.sh` 就是补上这一环的：它订阅同一组属性，把颜色
编码成 WS2812 帧从 SPI0 推出去。

## 这一版改了什么

只在 **vendor 分区（p5）** 动了四个文件，**内核与 DTB 完全没碰**（沿用 v33）。

| 镜像内路径 | 动作 | 说明 |
|---|---|---|
| `/bin/ws2812-common` | 新增 | WS2812 帧生成器（C，静态编译），一个 SPI 字节对应一个 WS2812 bit |
| `/bin/ngp-stickled.sh` | 新增 | 守护脚本：读 `persist.gammaos.rgb.*` → 推帧 |
| `/etc/init/ngp-stickled.rc` | 新增 | init 服务，`sys.boot_completed=1` 后启动 |
| `/bin/ngp-fixup.sh` | 替换 | 补上第 ⑩a 段：开机自检工具与 `/dev/spidev0.0` 是否就位 |

## 设置界面与属性的对应关系

「设置 → 掌机设置 → joystick led」写入的属性，以及各按钮实际写下的值
（这些都是实机上一个个点出来确认的，不是看代码猜的）：

| 界面按钮 | `persist.gammaos.rgb.effect` |
|---|---|
| 跟随屏幕 RGB | `follow` |
| 纯色 | `none` |
| 关闭 | `none`（同时把颜色改成暗色，不是 `#000000`） |
| 效果 1 / 2 / 3 | `"1"` / `"2"` / `"3"`（纯数字字符串） |

其余属性：

- `persist.gammaos.primary.rgb_hex` —— 当前生效颜色，**带 `#` 前缀**
- `persist.gammaos.rgb.led_brightness` —— 亮度 0-100
- `persist.gammaos.rgb.enable` —— 总开关

`follow`（跟随屏幕取色）没有屏幕取色后端，退化为静态色显示，其余全部生效。

## 验证方法

不靠眼睛看，用 SPI 控制器自己的字节计数器：

```
$ cat /sys/class/spi_master/spi0/statistics/bytes
1664
# 在设置里改一个颜色之后
$ cat /sys/class/spi_master/spi0/statistics/bytes
2080
```

差值 **416 字节** = 16 颗灯 × 24 bit + 32 字节复位。这个数字对上了，
就说明「改设置 → 真的推了一帧出去」，与灯珠是否亮无关，可以排除
「看着像亮了其实没变」的误判。

v34 构建时另外做了三重校验：

1. 四个文件从镜像里回读，md5 与仓库源逐一对上
2. 可执行位确认为 0755
3. 4 MiB 分块比对 v33/v34，**差异块必须全部落在 vendor 分区内**，
   范围外 0 块 —— 这条比回读更能证明没碰到别的分区

## 升级注意

- 只改 vendor，可以直接用 v33 的 userdata，不会清游戏存档
- `persist.*` 属性存在 userdata 里，刷完设置值保留
- 如果某个版本刷完灯还是不动，先查这两条：

```
getprop init.svc.ngp_stickled          # 应该是 running
logcat -b kernel -d | grep -i stickled # 有 WARN 就是缺文件或缺 spidev
```

## 已知未做

设置界面里「掌机设置」页还有 17 条英文字符串（设备工具、全局着色器、
双屏同显、副屏、摇杆灯、音效均衡器、启动保护、网络共享等）。

简体中文翻译已经全部做好，技术上卡在**签名**：`Settings.apk` 用 AOSP
平台私钥签名，而该私钥不可得。试过的两条替代路径都走不通：

- **重打包后自签名**：与系统 `android.uid.system` 共享 uid 的应用签名不符，
  装了会直接打不开，风险不可接受
- **RRO（运行时资源覆盖）**：overlay 能正确映射到全部 17 个目标资源，
  但 Android 14 要求目标 apk 声明 `<overlayable>`，Settings 没有声明，
  运行期被拒（`STATE_NO_IDMAP`）

所以这一版 Settings **保持原样**，一个字没改。
