# gammaos-nano 前端 —— ROM 从哪来

`gammaos-nano`（`/system/bin/gammaos-nano`，6.8 MB）是 GammaOS 自带的 XMB 风格前端，
DRM 直出，不走 SurfaceFlinger。3DS 会话（`azahar-nano`）也是它的兄弟组件。

它和 LANGOS 是两个独立的前端，**ROM 来源机制完全不同**：

| | LANGOS（`com.retrofront`） | gammaos-nano |
|---|---|---|
| 运行方式 | 普通 Android 应用 | 原生 DRM 进程（init 域） |
| ROM 根目录 | `rom_root`（用户 SAF 选的，本机指 TF2 根） | **硬编码 `/data/media/0/ROMs/`** |
| 传给模拟器的路径 | SAF `content://` | **`/sdcard/ROMs/<平台>/<rom>`** |
| 平台识别 | 每个子目录一个平台 | `nano_systems.json` 里的 16 个系统 + `romDir` |
| 配置文件 | `/data/data/com.retrofront/shared_prefs/` | `/data/system/nano_systems.json` |

## 它只扫内置存储

`strings /system/bin/gammaos-nano` 里的路径常量：

```
/data/media/0/ROMs/
/storage/emulated/0
/data/media/0/GammaShader
```

`nano_systems.json` 里每个系统只有 `romDir`（相对名，如 `nes`、`3ds`）和
`scanSources`（本机全是空数组），**没有绝对根路径** —— 根是二进制里写死的
`/data/media/0/ROMs`。

所以 ROM 必须落在 `/data/media/0/ROMs/<romDir>/` 下，nano 才看得见。

## 本机的坑：ROM 全在第二张 TF 卡上

NGP45HT 的 ROM 放在 TF2（vold 给的占位 UUID 挂载点
`/storage/00000000-0000-0000-0000-000000000001`），而它的**根目录直接就是平台目录**
（`3ds/`、`snes/`、`nes/` …），并没有 `ROMs` 这一层。

结果就是：LANGOS 能正常用（它的 `rom_root` 就指向 TF2 根），
**nano 前端一个游戏都扫不到**——`/data/media/0/ROMs/` 下只有系统自带的 174 个空平台
目录和 210 个示例小游戏，而且连 `3ds` 这个目录都没有。

要把 ROM 弄进去，得同时解决两件事，**少一件都不行**：

| 症状 | 原因 | 修法 |
|---|---|---|
| nano 里看不到 TF2 的游戏 | 扫描走 `/data/media/0/ROMs`，那里没有 TF2 内容 | 第 ⑤ 段 bind（解决"看得到"） |
| 游戏点开闪退回桌面 | 读 ROM 走 `/sdcard/ROMs`，落在 FUSE 上，root 打不开文件 | 第 ⑥ 段再 bind 一层（解决"打得开"） |

## 第 ⑤ 段：让 nano 扫得到

**符号链接不行。** `/storage/emulated/0` 是 MediaProvider 的 FUSE，
`ln -s` 能建成功，但一 `ls` 就报：

```
ls: /storage/emulated/0/ROMs/_t2test: Function not implemented
```

FUSE 不支持 symlink，只能 bind mount：

```sh
T2=/storage/00000000-0000-0000-0000-000000000001
if [ -d "$T2" ]; then
    if [ -d /data/media/0/ROMs ] && [ ! -e /data/media/0/ROMs.builtin ]; then
        mv /data/media/0/ROMs /data/media/0/ROMs.builtin   # 只挪一次
    fi
    mkdir -p /data/media/0/ROMs
    mount --bind "$T2" /data/media/0/ROMs
fi
```

bind 之后 FUSE 会把内容透出来，两个视图都能读到目录内容。

**不要逐平台 bind。** 试过对 TF2 的每个子目录单独 mount：174 个目录每个都要先走
FUSE 判空再 mount，5 分钟都跑不完，而且 `/data/media/0/ROMs` 里根本没有 `3ds`
这类目录（只有 174 个旧平台名），逐平台挂会漏掉一半。一次 bind 整个根目录是
O(1)，瞬间完成。

**内置的 210 个示例游戏没有删**，第一次运行时整个 `ROMs` 目录被改名成
`ROMs.builtin`（174 个平台目录 + 210 个文件）。要找回就把 bind umount 掉、
把 `ROMs.builtin` 改回 `ROMs`。

## 第 ⑥ 段：让 azahar-nano 打得开

### 症状

点 3DS 游戏后"闪退"，azahar 日志（`/data/system/azahar-nano/log/azahar_log.txt`）：

```
Loader <Error> core/loader/loader.cpp:GetLoader:159: Failed to load file !/sdcard/ROMs/3ds/超级马里奥 3D大陆 汉化版.cci
Core <Critical> core/core.cpp:Load:671: Failed to obtain loader for !/sdcard/ROMs/3ds/超级马里奥 3D大陆 汉化版.cci
azahar-nano: core shutdown request 100        ← core starting 之后 8 毫秒
azahar-nano: core returned 100
init: Service 'azahar-nano' (pid 5468) exited with status 0 oneshot service took 1.167s
```

### 根因

nano 传给 azahar-nano 的路径是 **`/sdcard/ROMs/3ds/<rom>`**，这个前缀硬编码在
`gammaos-nano` 二进制里（`strings -t d` 偏移 353930 `/sdcard/ROMs/`、
353944 `/sdcard/ROMs/3ds/`），改不了。

而 `/sdcard` → `/storage/self/primary` → `/storage/emulated/0`，最后一层是
**MediaProvider 的 FUSE**。FUSE 给 root 列目录，但**打开文件失败**：

```bash
su -c 'ls /sdcard/ROMs/3ds/'            # 正常列出
su -c 'dd if=/sdcard/ROMs/3ds/x.cci'    # Bad file descriptor / Bad address
```

### 三条路径的实际可读性

| 路径 | `ls` | `dd` 读内容 |
|---|---|---|
| `/sdcard/ROMs/3ds/x.cci`（FUSE） | OK | **失败** Bad address |
| `/data/media/0/ROMs/3ds/x.cci` | OK | OK，但 mount 表里已经被 `/dev/fuse` 盖住 |
| `/mnt/media_rw/<uuid>/3ds/x.cci`（vfat） | OK | OK |

**第 ⑤ 段不够的原因**：它 bind 到 `/data/media/0/ROMs` 之后，MediaProvider 又在这个
路径上挂了 FUSE：

```
/dev/fuse on /data/media/0/ROMs type fuse (user_id=0,group_id=0,allow_other)
/dev/fuse on /mnt/pass_through/0/emulated/0/ROMs type fuse
```

FUSE 透传内容（所以 nano 扫描能看到 TF2 的 295 个 NES 游戏），但 root 打开文件
依然过不去。这就是"扫得到、点开却闪退"的完整解释。

### 修法：在 FUSE 视图上再压一层 vfat

```sh
if [ -d "$T2" ] && [ -d /storage/emulated/0/ROMs ]; then
    mount --bind "$T2" /storage/emulated/0/ROMs
fi
```

`/storage/emulated/0/ROMs` 是 FUSE 视图里的路径，在它上面 bind 之后，
`/sdcard/ROMs/3ds/x.cci` 就绕过 FUSE 直达 vfat，root 能读。

### 试过但否掉的方案

`/storage` 是 tmpfs（rw），可以把 `primary -> /storage/emulated/0` 这个 symlink
改成 `-> /data/media/0`，`/sdcard/ROMs/3ds/x.cci` 就直接解析成可读路径，
**实测也能跑**。

但 symlink 是全局共享的：所有进程（含普通 app）的 `/sdcard` 都会变成
`/data/media/0`，而那个目录是 `media_rw:media_rw 0770`，普通应用进不去 ——
会悄悄破坏所有硬编码 `/sdcard` 的应用。**已回滚，改用局部 bind。**

## 持久化

两段都写在 `ngp-fixup.sh` 末尾，开机 `sys.boot_completed=1` 后执行
（前面有 `sleep 70`，那时 TF2 和 MediaProvider 的 FUSE 都已就位）。
bind 是临时的（mount 表重启清空），所以每次开机都要重新执行 —— 这是幂等的。

## 实测

**扫描**（第 ⑤ 段）：bind 之前 nano 里只有系统自带的几个示例（GB 3 款、GBC 3 款），
bind 之后 NES **295** 款、SNES **300** 款，数字全部来自 TF2。日志确认：

```
ngp-fixup: tf2 roms bound
```

**启动**（第 ⑥ 段）：`rom.txt` 写 `/sdcard/ROMs/3ds/超级马里奥 3D大陆 汉化版.cci`
后 `setprop sys.gammaos.azahar_nano.start 1`：

```
azahar-nano: perf: game 60.7 fps, system 60.7 fps, speed 101%
azahar-nano: DRM: crtc 71 flips=692 drops=0 ...
```

无 `Failed to load file`，画面正常出图。日志确认：

```
ngp-fixup: tf2 roms bound for azahar (/sdcard)
```

**重启后自动恢复**（已实测）：重启等 `boot_completed` + 90 秒，
`dd` 能读出 cci 的前 64 字节，无需手动干预。

## 排查手法

判断 nano 是否扫到，看 `/data/system/nano_systems.json` 里各系统的 `romDir`
和实际目录；判断能不能读，**不要用 `ls`，要用 `dd` 或 `head` 读内容** ——
FUSE 下 `ls` 成功但读文件失败是最容易误判的一步。

3DS 的失败现场看 `/data/system/azahar-nano/log/azahar_log.txt`（每次会话覆盖，
上一次在 `azahar_log.old.txt`），`Failed to load file` + `core shutdown request`
基本就是路径问题。

## 相关文件

| 文件 | 作用 |
|---|---|
| `/data/system/nano_systems.json` | 16 个系统的定义（id / romDir / extensions / launchType） |
| `/vendor/bin/ngp-fixup.sh` | 第 ⑤ ⑥ 段做 bind |
| `/vendor/etc/init/ngp-fixup.rc` | `sys.boot_completed=1` 触发 |
| `/data/media/0/ROMs.builtin/` | 被挪走的内置 ROMs（174 目录 / 210 文件） |
| `/data/system/azahar-nano/log/` | azahar core 日志 |
| `/data/system/nano_azahar_nano_rom.txt` | nano 写给 azahar-nano 的 ROM 路径 |
