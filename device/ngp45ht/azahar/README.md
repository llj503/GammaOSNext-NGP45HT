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

---

# 菜单汉化

`azahar-nano` 的菜单没有 i18n 框架（没有 .qm/.mo、没有语言枚举），所有菜单
文本都是编译进二进制的 `const char*` 字面量。汉化只能改二进制本身：

```
原始 azahar-nano       524,080 B  md5 b9f6ff35fc71ec1eea125345bb7fab5a
汉化 azahar-nano-zh    546,624 B  md5 bccd61880b57ed6aa73a46d497fef598
```

工具链在同目录 `zh/`，`python3 build.py` 从 `azahar-nano.orig` 生成 `azahar-nano.zh`。

## 做法

aarch64 没有 32 位绝对地址，字符串地址必须靠 `adrp + add` 指令对内联算出来，
所以不能像 x86 那样"改个指针"。整条链是：

1. **追加串池**：中文按 UTF-8 写进文件末尾页对齐的新区（本次 5,446 B / 205 条），
   vaddr 由尾段 LOAD 的 `p_vaddr - p_offset` 差推出（`0x1000`）。
2. **扩 LOAD**：把尾段（`.data`+`.bss` 那个）的 `p_filesz`/`p_memsz` 拉到覆盖串池，
   新页才被映射。**扩之前必须把 `[.data 末 .. 新页)` 这段文件清零** ——
   扩展后它会落到 `.bss` 的地址上，不清零 `.bss` 就带垃圾初值，进程起来就崩。
   原 `.shstrtab` / `.gnu_debugdata` / 节表在这段里，搬到文件最末（不被映射）再更新
   `e_shoff` 和两节的 `sh_offset`，分析用的符号表得以保留。
3. **重写引用**：扫 `.text` 做数据流跟踪，得到 `adrp -> 唯一 target` 的映射
   （精确分析下 2360 条 adrp **全部单目标**，启发式扫出来的"469 个多用"是寄存器
   复用造成的误判），逐条把 `adrp` 的页、`add` 的 imm12 改成串池地址。本次改写 281 条
   指令。`verify.py` 会重新反汇编核对每条都读到预期的中文，并确认没有 add 算出
   映射区外的地址。

## 三个非踩不可的坑

**① 字形图集太小 → 乱码。** `OverlayGfx` 的 atlas 写死 `1024x1024` 单通道
（`glTexImage2D(GL_LUMINANCE, 0x400, 0x400, ...)`）。中文字形数量是英文十几倍，
一页菜单就快满；`loadGlyph` 装不下时调 `resetAtlas()` 回收 —— glyph 表清空，
但**已经 emit 进 vertex buffer 的 UV 还指着旧位置**，新字形重新分配后覆盖过去，
屏幕上就是半截字。`build.py` 把尺寸、四处边界判断（`0x3ff/0x400/0x401`）、
UV 归一化系数一起改成 2048。注意 `scvtf s0, w8, #fbits` 的 **imm6 是 `64 - fbits`**
（#0xa → #0xb 对应 imm6 54 → 53），按 fbits 直接改会得到无法反汇编的垃圾指令。

**② 编译器把短字符串拆成"内存 8 字节 + 立即数 4 字节"。** 小于约 16 字节的字面量
不走 `strlen`/`memcpy`，而是：

```
adrp x9, page ; add x9, x9, #off ; ldr x9, [x9]   ← 只读前 8 字节
mov w8, #0x6953 ; movk w8, #0x6564, lsl #16      ← 后 4 字节硬编码成立即数
```

只改内存（或搬到串池）只改了前半截，后半截仍是英文，拼起来是非法 UTF-8，
显示成 U+FFFD（**菱形框加问号**）。`xref.py` 按"引用点后是否紧跟 `ldr xN,[xN]`"
把这类挑出来，`zh_inline.py` 里 28 条统一压到 **6 字节以内（2 个汉字）**，
让 NUL 一定落在前 8 字节里，`strlen` 到 NUL 就停，后面立即数补的字节读不到。
压不进去的（HLE / LLE / Xbox / Nintendo）保持英文。

**③ 段名同时是 `config.ini` 的 section 名。** `Audio` / `Controls` / `Core` /
`Layout` / `Renderer` / `System` 这几个字面量既做菜单分组标题，也做配置段名
（编译器的常量合并让两处共用一个地址）。汉化后旧配置的 `[Audio]` 就读不到了，
那些值回落到默认。`ngp-fixup.sh` 第 ⑨ 段做一次性迁移：检测到英文段名且还没有
中文段名时，备份成 `config.ini.bak-en` 再逐个改名。实测 `layout_option = 3`、
`resolution_factor = 2`、`is_new_3ds = true` 迁移后都还在。

## 部署

`/system` 是**整块只读挂载**（`/dev/block/mmcblk1p4 on / type ext4 (ro)`），改不了
文件。汉化版放 `/vendor/bin/azahar-nano-zh`，开机由 `ngp-fixup.sh` 第九段
`mount --bind` 盖到 `/system/bin/azahar-nano` 上。

**不能直接 exec `/vendor/bin/azahar-nano-zh`** —— 那样 `/proc/self/exe` 落在 vendor
命名空间，linker 找不到 `/system/lib64/libgui.so`，报
`CANNOT LINK EXECUTABLE ... library "libgui.so" not found`。bind 到 `/system/bin`
之后路径是 system 的，一切正常（实测 init 启动、游戏 60 fps）。

回滚：`umount /system/bin/azahar-nano`，原版 md5 见上表。

## 调试技巧

`sys.gammaos.azahar_nano.shot=<任意数>` 会让前端把 DRM plane 导出成 PPM
（`/data/system/azahar-nano/<n>_0.ppm` 是 320x240 游戏画面，`<n>_0_hud.ppm` 是
1024x768 HUD 层）。**菜单所在的 overlay plane 不在导出范围内**，`screencap` 也抓不到
（DRM 直出绕过 SurfaceFlinger），菜单只能人眼看。截 PPM 的办法很适合验证
"游戏有没有真的出图"。
