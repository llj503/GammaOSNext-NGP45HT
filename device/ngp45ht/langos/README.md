# LANGOS 前端 —— 3DS 支持与平台识别规则

LANGOS（`com.retrofront`）是 v27 起内置的默认桌面。它自己扫描 ROM 目录生成平台卡片，
不依赖 Daijishō 的数据库。v30 起 3DS 可以从 LANGOS 里直接点开。

## 平台是怎么来的

`rom_root` 下的**每一个子目录就是一个平台**，目录名小写后就是平台 id：

```
/data/data/com.retrofront/shared_prefs/retrofront.xml
    <string name="rom_root">/storage/00000000-0000-0000-0000-000000000001</string>
```

这台机器的 ROM 在**第二张 TF 卡**上（vold 给的占位 UUID 挂载点），不是内置存储。

扫描结果缓存在 `/data/data/com.retrofront/files/scan_cache.json`（约 5.7 MB），
结构是 `{platforms: [{id, name, folder, gameCount}], games: {平台id: [游戏...]}, timestamp}`。

## 3DS 的目录名必须是 `3ds`，不能是 `n3ds`

**这是实测结论，容易踩：**

| 目录名 | 扫描层 | 卡片 |
| --- | --- | --- |
| `n3ds` | 收录，`平台数 26`、`任天堂 9` 都对 | **不显示** |
| `3ds` | 收录 | **正常显示**，且排在第一位 |

原因在 `NativeActivity` 的显示名映射表里：key 是 `3ds`，映射到
`"Nintendo 3DS"`；`n3ds` 不在表里，走默认分支，卡片就不画了。

EmuELEC 的 ROM 目录约定是 `n3ds`，直接拷过来会踩这个坑。

映射表里 3DS 的完整条目（`smali_classes3/com/retrofront/NativeActivity.smali`）：

```
:sswitch_2b
const-string v1, "3ds"
...
:cond_20
const-string v0, "Nintendo 3DS"
```

## v30 的启动链路（已打通）

LANGOS 对每个平台有一个"独立模拟器包名"映射，`getStandaloneEmulator(platformId)`。
3DS 原本返回 `io.github.lime3ds.android`（Lime3DS），这个包没装，于是
`startGame` 回落到 RetroArch 核心 —— **而且不检查核心文件是否存在**，
`citra_libretro_android.so` 根本不在 RA 的 152 个核心里，结果就是黑屏 + ANR。

v30 把 3DS 的独立模拟器改成 AzaharSf：

| 位置 | 改动 |
| --- | --- |
| `getStandaloneEmulator` 的 `:cond_4` | `"io.github.lime3ds.android"` → `"com.gammaos.azaharsf"` |
| `launchWithStandaloneEmulator` 的 `:cond_0` | 插入 Azahar 专用分支（见下） |

插入的分支（smali）：

```smali
:cond_0
const-string v0, "com.gammaos.azaharsf"
invoke-virtual {v9, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
move-result v0
if-eqz v0, :ngp_azahar_fallthrough

new-instance v0, Landroid/content/Intent;
const-string v1, "android.intent.action.VIEW"
invoke-direct {v0, v1}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V
const-string v1, "com.gammaos.azaharsf.AzaharSfActivity"
invoke-virtual {v0, v9, v1}, Landroid/content/Intent;->setClassName(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;
const-string v1, "ROM"
invoke-virtual {v14}, Ljava/io/File;->getAbsolutePath()Ljava/lang/String;
move-result-object v2
invoke-virtual {v0, v1, v2}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;
invoke-virtual {v8, v0}, Lcom/retrofront/NativeActivity;->startActivity(Landroid/content/Intent;)V
goto :goto_12

:ngp_azahar_fallthrough
invoke-virtual/range {p1 .. p1}, Ljava/lang/String;->hashCode()I
```

### 为什么传 extra 而不是 URI

AzaharSf 的 `romPath(Intent)` 判定顺序是：

1. `getStringExtra("ROM")`，非空就直接用；
2. 否则才看 `getData()`，**而且只接受 `file` scheme**，`content://` 一律忽略。

而 LANGOS 原来给 citra 构造的是 `FileProvider.getUriForFile("com.retrofront.fileprovider")`
的 **content:// URI**，AzaharSf 拿到也解析不出路径。改走 `"ROM"` extra 传绝对路径，
既绕开了 scheme 限制，也绕开了 targetSdk 34 的 `FileUriExposedException`。

### 需要 DRM 后端，不是 SurfaceFlinger 后端

这是最反直觉的一条，实测证据在 `azahar/README.md`：AzaharSf 默认走 SurfaceFlinger
后端，层建出来了（`azahar-nano#1477`）但**始终没有 buffer 交给 HWC**，屏幕全黑；
换成 DRM 直出后 `DRM: crtc 71 flips=1780 ... commit->flip avg 12.6 ms`，55 fps 正常上屏。

所以 v30 把 `azahar-nano.rc` 里 `start_app=1` 的 `host` 从 `app` 改成 `nano`（DRM），
并用 `sys.gammaos.azahar_nano.from_app` 区分"从 Android 来的"和"从 nano 前端来的"：
前者会话结束后不拉 gammaos-nano，让 AzaharSf 自己 finish 回 LANGOS。

## 改完目录后怎么让它重新扫

LANGOS 不会自动发现新目录，必须手动触发：

1. 设置（`START` 键）→ **重新扫描游戏** → 执行；或
2. `adb shell su -c 'rm /data/data/com.retrofront/files/scan_cache.json'`
   然后 `am force-stop com.retrofront` 再启动

全量重扫 11600+ 款游戏约 **80~90 秒**，期间界面是空的或停在旧画面 ——
**别在这时候截图判断结果**（我第一次就是这样误判成"3DS 不显示"的）。

## 重打包方法

本机没有 Android SDK，但 apktool 的 fat jar 自带 aapt2，配合 build-tools 的
`zipalign` / `apksigner` 就够：

```bash
java -jar /tmp/apktool.jar d LANGOS.apk -o langos-d          # 反编译
# 改 smali_classes3/com/retrofront/NativeActivity.smali
java -jar /tmp/apktool.jar b langos-d -o unsigned.apk        # 重打包
zipalign -f -p 4 unsigned.apk aligned.apk
apksigner sign --ks apps/langos.jks --ks-pass pass:ngp45ht \
    --key-pass pass:ngp45ht --ks-key-alias langos --out LANGOS.apk aligned.apk
```

签名密钥在 `apps/langos.jks`（自签名，口令 `ngp45ht`）。**换签名后必须整卡刷入**：
system 分区上留着旧签名的 APK、`/data` 里有旧的安装记录，两者签名不一致时
PackageManager 会拒绝加载，`adb install -r` 也报
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`（`pm uninstall --user 0` 也没用 ——
它只是对该用户禁用，system 分区上的包仍在，签名检查照样拦）。

## 卡片排序

不是按目录名，也不是按游戏数。新出现的平台会排在前面（3ds 加进去后直接占了第一位）。
