# LANGOS 开游戏时选模拟器（v39）

## 需求

同一个平台可能装了不止一个模拟器（比如 PS2 有 NetherSX2 和 ARMSX2，3DS 有内置
的 Azahar 前端和官方 Azahar）。原版 LANGOS 里 `getStandaloneEmulator(id)` 是
**每个平台硬编码一个包名**，玩家装了几个都只能用那一个。

改成：点游戏时如果该平台有 **≥2 个已安装**的候选，弹框让玩家选；只有 1 个就
直接用，不打扰玩家。

## 实现

基线：v38 的 `LANGOS.apk`（md5 `33daa30a04ab309d64315c2b758cefc1`）

改动都在 `com/retrofront/NativeActivity.smali`，另新增一个内部类。
补丁脚本 `device/ngp45ht/apps/langos-patch/patch_langos_emu.py` 可整套复现。

### 1. 新增字段

```smali
.field private ngpPickedEmu:Ljava/lang/String;
```

本次选中的包名。`getStandaloneEmulator()` 开头优先返回它，所以下游
`launchWithStandaloneEmulator()` 不用改。

### 2. 候选表 `ngpEmuCandidates(platformId) -> String[]`

每个平台一张表，元素 `包名|显示名`，分号分隔，**只返回本机真的装了的**：

| 平台 | 候选 |
|---|---|
| `ps2` | `xyz.aethersx2.android`(NetherSX2/AetherSX2)、`com.armsx2`(ARMSX2) |
| `3ds` | `com.gammaos.azaharsf`(内置)、`org.azahar.azahar`、`org.citra.emu`、`org.citra.citra_emu` |
| `psp` | `org.ppsspp.ppsspp`、`org.ppsspp.ppssppgold` |
| `nds` | `com.dsemu.drastic`、`com.gammaos.drasticsf` |

其余平台保持原样（单候选，不进这张表）。

### 3. 选择器 `ngpEmuChooser(platformId, game) -> boolean`

返回 `true` 表示「已经弹框，后续由对话框回调启动」，调用方 `startGame` 直接
`return-void`。`cand==0` 或 `cand==1` 返回 `false`，走原来的逻辑。

⚠️ **平台 ID 不能用 `currentPlatform.getId()`** —— 在「最近游玩 / 收藏」屏它是
`recent` / `favorite`，查不到候选表。要用 `game.getPlatformId()`。

### 4. `startGame` 钩子

```smali
invoke-direct {v1, v10, v2}, Lcom/retrofront/NativeActivity;->ngpEmuChooser(Ljava/lang/String;Lcom/retrofront/data/Game;)Z
move-result v13
if-eqz v13, :ngp_chooser_go
return-void
:ngp_chooser_go
```

### 5. 回调类 `NativeActivity$NgpEmuPickListener`

实现 `DialogInterface.OnClickListener`，持有 `activity` / `game` / `pkgs[]`，
`onClick` 里调 `access$ngpLaunch(activity, pkgs[pos], game)`（新加的
`access$` 合成方法，用来跨类调 private 的 `launchWithStandaloneEmulator`）。

### 6. AlertDialog

LANGOS 的主题是 `@android:style/Theme.Material.NoActionBar`（不是 AppCompat），
所以必须用 `android.app.AlertDialog$Builder`，不能用 androidx 的。

## 三个必踩的坑

### ★ `if-gez` 是「≥0 时跳」，不是「<0 时跳」

```smali
invoke-virtual {v4, v0}, Ljava/lang/String;->indexOf(I)I
move-result v3
if-gez v3, :ngp_cand_next      # ✗ 意思是「找到 | 了就跳过」
```

`gez` = **greater-or-equal-zero**。原来这里写 `if-gez`，导致每个候选都被跳过，
`cand` 永远是 0（日志里能骗人：`n=4` 但一个都没进结果）。正确写法是 `if-ltz`。

同一族的其他助记符也容易混：`if-lez`(≤0)、`if-gtz`(>0)、`if-ltz`(<0)。

### ★ Android 11+ 包可见性：`<queries>` 里没列的包，`getPackageInfo` 直接抛

`isPackageInstalled()` 用 `getPackageInfo(pkg, 0)`。目标 SDK ≥30 时，不在
`<queries>` 里的包会抛 `NameNotFoundException`，于是**所有候选都被判成"没装"**。

v38 的 `<queries>` 里没有 `com.gammaos.azaharsf` / `com.armsx2` 等，必须补：

```xml
<queries>
    ...
    <package android:name="com.gammaos.azaharsf"/>
    <package android:name="com.gammaos.drasticsf"/>
    <package android:name="com.armsx2"/>
    <package android:name="org.azahar.azahar"/>
    <package android:name="org.ppsspp.ppssppgold"/>
</queries>
```

### ★ apktool 重建的 apk 必须 zipalign，否则 `pm install` 直接拒

```
Failure [-124: Failed parse during installPackageLI: Targeting R+ (version 30 and above)
requires the resources.arsc of installed APKs to be stored uncompressed and aligned
on a 4-byte boundary]
```

apktool 2.9.3 不再自动 zipalign。构建链固定为：

```bash
java -jar apktool.jar b out -o patched.apk
zipalign -p -f 4 patched.apk aligned.apk
apksigner sign --ks langos.jks --ks-pass pass:ngp45ht --ks-key-alias langos \
          --key-pass pass:ngp45ht --out final.apk aligned.apk
```

## 构建

```bash
# 基线反编译
java -jar apktool.jar d -f -o out LANGOS-3.4-v38.apk
# 打补丁（内部会改 AndroidManifest.xml 的 <queries>）
python3 patch_langos_emu.py
# 上面三步
```

产物：`apps/LANGOS-3.5-emupick.apk`，3,916,420 B，md5 `a0f69f9adcb1bce6fd774fa4325e3084`，
签名证书 SHA-256 `05689c30e666e0fbd2c9d187c5471409397261f84ac830577befcc749950b756`（langos.jks）。

## 实测

| 场景 | 日志 | 结果 |
|---|---|---|
| 3DS，只装内置 Azahar | `chooser platform=3ds cand=1` | 直启 `AzaharSfActivity`，无弹窗 |
| 3DS，再装一个（测试用 DraStic） | `chooser platform=3ds cand=2` | 弹「选择模拟器（3ds）」，列表两项；选第一项正常启动 Azahar |
| CPS2（不在候选表） | `chooser platform=cps2 cand=0` | 走 RetroArch，行为不变 |
| 最近游玩屏点 3DS 游戏 | `chooser platform=3ds`（`game.getPlatformId()` 生效） | 同上 |

保留了 `Log.d("NGP_EMU", "chooser platform=... cand=...")` 一行，方便以后排障。
