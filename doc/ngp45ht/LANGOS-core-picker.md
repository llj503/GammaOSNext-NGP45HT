# LANGOS 逐游戏切换 RetroArch 核心（v3.6）

## 需求

街机改版经常要换核心才能启动，原版 LANGOS 只会用 `getPlatformCore(平台id)`
算出的默认核心，进游戏前没有入口。要求：

- 游戏详情页、点“启动游戏”之前能选核心；
- 选择按游戏保存，重启后还在；
- **按平台过滤**：GBA 只列能跑 GBA 的核心，街机只列街机核心，
  不要把所有 170 多个核心都倒出来。

## 基线

v39 的 `LANGOS-3.5-emupick.apk`（md5 `a0f69f9adcb1bce6fd774fa4325e3084`）。
本版保留“开游戏时选模拟器”，在它上面加核心切换，版本号 3.6 / versionCode 22。

## 实现

### 1. 新增 `com.retrofront.CoreOptions`

Java 辅助类，编译成 smali 后放进 `smali_classes3`。负责：

- 在详情页插一行“游戏核心”按钮；
- 弹核心选择框（单选，列出该平台兼容的核心）；
- 读写 `/data/data/com.retrofront/shared_prefs/langos_core_overrides.xml`，
  key 是 ROM 完整路径，value 是核心名；
- 给 `startGame` 提供覆盖路径。

### 2. 详情页入口

`GameDetailDialog.createView()` 在按钮行之前调用：

```smali
invoke-static {v13, v6, v12, v10, v11}, Lcom/retrofront/CoreOptions;->install(
    Landroid/content/Context;Landroid/widget/LinearLayout;Ljava/lang/String;
    Ljava/lang/String;Ljava/lang/String;)V
```

参数依次是 Context、详情页的纵向 `container`、ROM 路径、平台 id、默认核心名。

**平台 id 必须用 `game.getPlatformId()`**，不能用
`currentPlatform.getId()`：在“最近游玩 / 收藏”屏 currentPlatform 是
`recent` / `favorite`，过滤会失效。这一点和 v39 的模拟器选择器相同。

按钮显示：

- 没有覆盖：`游戏核心: 自动（mgba）`，括号里是 LANGOS 原来的默认核心；
- 有覆盖：`游戏核心: gpsp`。

### 3. 启动钩子

`NativeActivity.startGame()` 在算出默认 `corePath` 之后、构造 RetroArch
Intent 之前：

```smali
invoke-virtual {v11}, Ljava/io/File;->getAbsolutePath()Ljava/lang/String;
move-result-object v0
invoke-static {v1, v0}, Lcom/retrofront/CoreOptions;->resolveOverride(
    Landroid/content/Context;Ljava/lang/String;)Ljava/lang/String;
move-result-object v0
if-eqz v0, :cond_coreov_end
move-object v2, v0
:cond_coreov_end
```

有覆盖时只替换 `v2`，后面 `LIBRETRO` extra 自然拿到覆盖核心的绝对路径。
RetroArch 的全局配置、默认核心都不动。选“自动”会删掉该游戏的 key。

### 4. 按平台过滤

`CoreOptions.coresForPlatform()` 给每个平台一张白名单，再和本机实际可用核心
取交集。主要分组：

| 平台 id | 候选核心 |
|---|---|
| `gba` | `mgba`、`gpsp`、`vba_next`、`vbam`、`skyemu` |
| `gb` / `gbc` | `gambatte`、`sameboy`、`DoubleCherryGB`、`gearboy`、`skyemu`、`tgbdual` |
| `nes` / `famicom` | `fceumm`、`nestopia`、`quicknes`、`mesen` |
| `snes` / `sfc` | `snes9x*`、`bsnes*`、`mesen-s`、`mednafen_supafaust` |
| `n64` | `mupen64plus_next_gles2`、`mupen64plus_next_gles3`、`parallel_n64` |
| `nds` | `melonds`、`melondsds`、`desmume`、`desmume2015`、`skyemu` |
| `psx` | `pcsx_rearmed`、`mednafen_psx`、`mednafen_psx_hw`、`swanstation` |
| `megadrive` / `genesis` | `genesis_plus_gx*`、`picodrive`、`blastem`、`clownmdemu` |
| `mastersystem` / `gamegear` | `genesis_plus_gx*`、`gearsystem`、`smsplus`、`picodrive` |
| `cps1/2/3`、`fbneo`、`neogeo`、`arcade`、`mame2003` | `fbneo`、`fbalpha2012*`、`mame*`、`hbmame` 等 |
| `ngpc` | `mednafen_ngp`、`race` |
| `dreamcast` | `flycast` |
| `saturn` | `mednafen_saturn`、`yabause`、`yabasanshiro` |

其余平台也配了对应白名单（PCE、WonderSwan、Lynx、VB、Atari、3DO、C64、
Amiga、DOS、MSX、ZX Spectrum、PC-98、X68000 等）。

兼容核心不足 2 个时**不显示核心按钮**：3DS、PS2、PSP 以及
`bios` / `themes` / `金手指` / 移植游戏等平台不会出现一行无意义的选择。
安卓 APP 详情页也不显示。

### 5. 核心清单从哪来

LANGOS 是普通 app，读不了 `/data/data/com.retroarch.aarch64/cores`
（0700，u0_a97）。所以：

1. 先扫 `/storage/emulated/0/RetroArch/cores`；
2. 再扫 `/storage/emulated/0/Android/data/com.retroarch.aarch64/files/cores`；
3. 都为空时用 APK 内置的 174 个核心名（与镜像自带核心一致）。

**不要用 `su -c ls` 去列。** app 进程带 `no_new_privs`，即使
`/vendor/bin/su` 是 4755，也会报：

```
su: cannot set uid 0: Operation not permitted
su: (setuid bit missing? chmod 4755 this binary)
```

`adb shell run-as com.retrofront /vendor/bin/su -c ...` 能跑，不代表 app 里能跑。

## 实测

- GBA `007-谁与争锋[英].zip`：选择框只出现
  `自动（mgba） / mgba / gpsp / vba_next / vbam / skyemu`；
  选 `gpsp` 后日志：
  `LIBRETRO=/data/data/com.retroarch.aarch64/cores/gpsp_libretro_android.so`，
  游戏正常进标题画面。
- 街机 `1941.zip`：选择框只出现 `fbneo / fbalpha2012* / mame* / hbmame`；
  选 `fbalpha2012_cps1` 能正常进游戏。
- 重启 LANGOS 后选择仍在；“自动”恢复为 `mgba` / `fbneo`。
- v39 的“开游戏选模拟器”仍然保留：如果玩家在模拟器选择里选了独立模拟器，
  核心选择不影响它；选 RetroArch 时才使用这里的核心覆盖。

## 镜像集成

APK 放在 `device/ngp45ht/apps/LANGOS-3.6-core.apk`。下一个镜像构建把
`NEWLANGOS`（参考 `scripts/build_v39.sh`）指向它即可；已发布的 v39 镜像
仍是 3.5-emupick，不包含本改动。
