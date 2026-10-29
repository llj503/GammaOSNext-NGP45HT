# 3DS —— azahar-nano + AzaharSf

NGP45HT 上的 Nintendo 3DS 由两部分组成：

| 组件 | 位置 | 作用 |
| --- | --- | --- |
| `azahar-nano` | `/system/bin/` | 3DS 前端宿主，自带 DRM 和 SurfaceFlinger 两套渲染后端 |
| `AzaharSf` | `/system/app/AzaharSf/` | Android 侧宿主 Activity，写 ROM 路径并触发会话 |
| `libazahar-nano-core.so`（38 MB） | `/vendor/azahar/` | 模拟器主体 |
| 4 个 AdrenoTools hook | `/vendor/azahar/` | `libhook_impl` / `libmain_hook` / `libfile_redirect_hook` / `libgsl_alloc_hook` |

只走 Vulkan —— OpenGL ES 在 Mali-G52 上跑 azahar 会崩，菜单里没有 GL 选项是正常的。

## 渲染后端：能出图的只有 DRM

**这是 v30 才发现的关键事实。** `azahar-nano` 根据 `sys.gammaos.azahar_nano.host`
选后端，两条路的实测结果完全不同：

| host | 后端 | 现象 |
| --- | --- | --- |
| `app` | SurfaceFlinger | 层建出来了（`azahar-nano#1477`），游戏在跑 53 fps，**但该层始终没有 buffer 交给 HWC**，`dumpsys SurfaceFlinger` 的 HWC layers 表里只有 AzaharSf 自己那一层，屏幕全黑 |
| `nano` | DRM 直出 | `DRM backend up: 1 panel(s)`、`DRM: crtc 71 flips=1780 drops=48 ... commit->flip avg 12.6 max 17.1 ms`，`perf: game 55.5 fps speed 93%`，正常上屏 |

所以 v30 把 `start_app=1` 分支的 host 从 `app` 改成了 `nano`。改完之后：

- **截图会变黑**。`screencap` 走 SurfaceFlinger，而 DRM 直出绕过了它，画面抓不到 ——
  黑屏截图不等于没出图，要看 `DRM: crtc ... flips=` 计数和 `perf: game ... fps`。
- 会话结束时不能无脑拉 `gammaos-nano`，否则会把 LANGOS 顶掉。所以加了
  `sys.gammaos.azahar_nano.from_app` 标记，只有 `from_app=0`（从 nano 外壳来的）
  才 `start gammaos-nano`；从 Android 来的让 AzaharSf 自己 `finish()` 回桌面。

AzaharSf 的 `poll()` 每轮读 `sys.gammaos.azahar_nano.session`，session 消失
连续 2 个 tick 就 `finish()`，启动后 20 个 tick 还没见到 session 则报
"azahar-nano did not start" 并退出。所以退出游戏会自动回到 LANGOS。

## core 为什么在 /vendor 而不在 /system

两个硬约束：

1. **放不进 system**。p4 加完内置应用后只剩约 4.6 MB，core 本身 38 MB。
2. **必须和 4 个 hook 同目录**。前端从 core 的 dirname 推导 hook 目录，hooks 散在
   `/system/lib64` 就找不到。

也不能靠符号链接放进 `/vendor/lib64` —— linker 会按 realpath 判断，链接目标不在
permitted paths 里会被拒。

所以：core + hooks 一起放 `/vendor/azahar/`，开机由 `azahar-nano-setup.sh` 复制到
`/data`，再把 `persist.gammaos.azahar_nano.core` 指向 `/data/azahar-core.so`。
前端从属性里拿绝对路径 dlopen，`/data` 没有 namespace 限制。

> v26/v27 时 p5 只有 254 MiB、剩 7.8 MB，core 是放在启动分区（p3 的 `/azahar`，
> FAT32）再复制到 `/data` 的。v28 把 p5 扩到 575 MiB，core 才搬进 vendor ——
> 不再依赖 FAT 分区，p3 也腾出了 36 MB。

## 一个容易误判成"模拟器坏了"的坑：audioserver

`azahar-nano` 启动时如果 `media.audio_flinger` 还没注册，主线程会卡在
`AudioSystem::getService` 的无限重试里：

```
D AudioSystem: getService: waiting for media.audio_flinger   ← 每秒一条，永不结束
```

此时游戏**一帧都不会渲染**，日志停在 `Audio SetSink type 0 device 'Auto'`，
看起来像模拟器挂了。实际是 `init.svc.audioserver` 处于 `stopped`
（内存吃紧时被 LMK 收掉，或刚开机还没起来）。

判据：

```bash
adb shell getprop init.svc.audioserver          # 要 running
adb shell service list | grep media.audio_flinger
```

不在就 `adb shell su -c 'start audioserver'`，几秒后 `media.audio_flinger` / `media.audio_policy`
会注册上，再启动游戏就正常了。

## 文件来源

`libazahar-nano-core.so` 和 4 个 hook 来自 **`GammaOSCore-RG52Mini-20261025-2119-ota.zip`**
（RG52mini v1.14）的下列路径，未做任何修改：

```
system/lib64/libazahar-nano-core.so        37,943,712 B  md5 db3d2ab74a3af4611b9dc2b5ef4e6a9d
system/lib64/libhook_impl.so                  277,824 B  md5 423d0691585c9b2a16b59358125038ec
system/lib64/libmain_hook.so                    3,984 B  md5 959fcaa5e12136e7969d8c9475328142
system/lib64/libfile_redirect_hook.so           3,784 B  md5 868aededd1dd042c2c58e7f5415bdbd4
system/lib64/libgsl_alloc_hook.so               4,080 B  md5 717ce0e8b721c25f237b4f5234c7e97e
```

这 5 个二进制不进 git（38 MB，走 Git Data API 太慢），需要时按上表从 zip 里取。

`azahar-nano` 前端自身（524,080 B）和 `nano_shaderc` 在 `GammaOSCore-RG52Mini` 的
`system/bin/` 下，同样未改动，直接写进镜像的 `/system/bin/`。

## 两个脚本

**`azahar-nano.rc`** —— init 服务定义。`post-fs-data` 时跑一次 setup；
`sys.gammaos.azahar_nano.start=1`（nano 外壳拉起）和 `start_app=1`
（Android 侧 AzaharSf 拉起）是两个入口，两者都走 DRM 后端，靠 `from_app` 区分
会话结束后是否回到 nano 外壳。

**`azahar-nano-setup.sh`** —— 把 core 和 hooks 从 `/vendor/azahar` 复制到 `/data`。
按**文件大小**判断是否需要复制，所以升级镜像时 /data 里的旧 core 会被自动换掉
（只判断"是否存在"的话，刷了新版 core 也还是用旧的）。
