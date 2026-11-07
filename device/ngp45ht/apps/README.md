# apps —— 内置进 system 分区的应用

这两个 APK 直接写进 `/system/app/`，刷完机即存在，不需要用户再安装。

| 文件 | 包名 | 入口 | 大小 | md5 |
| --- | --- | --- | --- | --- |
| `NgpIme.apk` | `com.llj.ngpime` | `com.llj.ngpime/.NgpImeService` | 1,131,187 | `4a161671889af113caf1af0a07e422b0` |
| `LANGOS.apk` | `com.retrofront` | `com.retrofront/.NativeActivity` | 3,920,516 | `865d65b57392a7a0790f46852a4c7c66` |
| `JoystickLedPicker-zh.apk` | `com.gammaos.joystickled` | `com.gammaos.joystickled/.MainActivity` | 3,488,534 | `27d4fe002502c0356b13529fb3505478` |

`langos.jks` 是用来重签 LANGOS 的自签名密钥库（alias `langos`，口令都是 `ngp45ht`）。
**换签名后必须整卡刷入** —— 详见 `../langos/README.md` 的重打包一节。

`JoystickLedPicker-zh.apk` 不覆盖系统里的原件，而是**运行时 bind mount** 盖上去
（原因见下面「摇杆灯设置汉化」一节），所以它落在 `/vendor/etc/ngp/` 而不是
`/system/app/`。用于重签它的私钥 `ngp-app.jks` 不入库（见 `.gitignore`）。

## NgpIme —— 手柄拼音输入法

来自 [llj503/ngp-pinyin-ime](https://github.com/llj503/ngp-pinyin-ime) 的
v0.1.1（main `b9b03df`）。v0.1.1 增加了「手柄拼音按键过滤」无障碍服务：
LocalSend 等 Flutter 应用会自己吞掉硬件按键，输入法收不到；过滤器在输入法
显示时接管手柄键、隐藏时原样透传，退格改用 `KEYCODE_DEL` 兼容 Flutter。
它是手柄优先的离线拼音输入法，10×4 QWERTY 网格，
焦点环全走 D-pad，不需要触摸屏；词库是 CC-CEDICT + jieba 词频，打包在
`assets/dict.tsv.gz` 里，不联网、没有 INTERNET 权限。

系统自带的两个键盘（AOSP leanback、LeanKey）都只有英文，中文输入只能靠这个。

## LANGOS —— 游戏前端

`com.retrofront`，基于 3.0 带电池修正版（`LANGOS-3.0-battfix.apk`）改了 3DS 的启动目标。
它同时声明了 `LAUNCHER` / `LEANBACK_LAUNCHER` / `HOME`，可以直接当桌面，
替掉上游镜像默认的 Daijishō。

**v30 起这个 APK 不是原版了**：把 3DS 的独立模拟器从 Lime3DS 改成 AzaharSf，
具体改动与重打包方法见 `../langos/README.md`。原版 APK 的签名是
`CN=LANGOS Patch`，私钥不可得，所以改动版用 `langos.jks` 重签。

**v3.6（versionCode 22）在 3.5-emupick 基础上加了逐游戏核心切换**：
详情页在“启动游戏”上方多一行“游戏核心”，按平台过滤（GBA 只列
`mgba` / `gpsp` / `vba_next` / `vbam` / `skyemu`），选择按 ROM 路径保存。
实现与实测见 `../../../doc/ngp45ht/LANGOS-core-picker.md`。
APK 为 `LANGOS-3.6-core.apk`（3,920,516 字节，md5
`efc852b11e11e41ea05de393474a63a9`）。v39 镜像是 3.5-emupick，v40/v41 是
3.6-core；v42 起用 3.7.1。

**v3.7（versionCode 23）**：3DS 模拟器选择器加入官方 Azahar
（`org.azahar_emu.azahar`），用 LANGOS FileProvider content URI 直接传 ROM。
官方 Azahar 首次启动需完成向导（用户目录建议 `/storage/emulated/0/azahar-emu`、
授予文件系统权限），并在游戏手柄设置里 Auto-Map 一次，否则物理 B 会被当成返回。
**v3.7.1（versionCode 24）**：PS2 选择器支持 ARMSX2（`com.armsx2`），
用绝对路径 data 启动 `com.armsx2.MainActivity`（ARMSX2 只认文件路径，
不认 content URI）；官方 Azahar 的 content URI 启动不变。
镜像 v42 起用 3.7.1：`LANGOS.apk`（md5 `865d65b57392a7a0790f46852a4c7c66`），
历史 APK `LANGOS-3.7.1-armsx2.apk` 同内容。

`ngp-fixup.sh` 每次开机做两件事：把 home 固定到它，以及给它
`MANAGE_EXTERNAL_STORAGE`（扫 ROM 目录要用，内置到 system 后这条授权仍然要单独给）。

### 首次开机要手动选一次 ROM 目录

LANGOS 没有 rom_root 时会拉起 SAF 目录选择框，这一步没法自动化 ——
选择框是 DocumentsUI 的普通 Activity，脚本替用户点不了，而且 ROM 放哪
本来就是用户的偏好。手柄操作：D-pad 移动到目标目录，Start 确认。

选完之后它写两条配置，之后开机直接进游戏库：

```
/data/data/com.retrofront/shared_prefs/retrofront.xml
    <string name="rom_root">/storage/emulated/0</string>
/data/data/com.retrofront/shared_prefs/saf_prefs.xml
    <string name="saf_tree_uri">content://com.android.externalstorage.documents/tree/primary%3A</string>
```

v42 起：`ngp-eeroms-link` 服务开机把 EEROMS 卡链到 `/storage/EEROMS`，
`ngp-fixup.sh` 首次开机把 `rom_root` 改成 `/storage/EEROMS`；SAF tree URI
机制不变。若清除 LANGOS 数据或重刷后仍弹选择框，选 `/storage/EEROMS` 即可。

注意 `rom_root` 要指到**放 ROM 的那一层**。如果指成 `/storage/emulated/0`，
LANGOS 会把 `ROMs`、`RetroArch` 这些一级子目录各自当成一个"平台"，
而不是进 `ROMs` 里按机种分类。

`ngp-fixup.sh` 里另有一段处理它和 vold 的竞态：LANGOS 比 vold 先起时读不到
rom_root，会误弹选择框（开机必现）；脚本等 public 卷挂载完成，如果前台仍是
选择页就重启一次 LANGOS。

> 另外，`adb install` 覆盖装过 LANGOS（或 `pm uninstall --user 0` 再
> `install-existing`）会把 SAF 的持久化授权一起清掉 —— `/data/system/urigrants.xml`
> 变空，`saf_prefs.xml` 里的 tree URI 还在但没权限了，于是又弹选择框。
> 授权没法用 adb 直接补，只能手柄再选一次。

## 摇杆灯设置汉化（JoystickLedPicker-zh.apk）

「设置 → 掌机设置 → joystick led」打开的就是 `com.gammaos.joystickled`
（`/system/app/JoystickLedPicker/`）。它本来自带 `values-zh-rCN`，所以界面
绝大多数已经是中文 —— 实测只有右上角那个预览标签是英文。

原因是它拼在 Kotlin 代码里，没走资源：

```kotlin
"Preview (" + String.format("#%06X", color) + ")"
```

改法是给默认值与 `values-zh-rCN` 各加一条 `preview_label`（默认 `Preview`、
中文 `预览`），把这句换成 `getString(R.string.preview_label)`。新增字符串的
资源 ID 在 `res/values/public.xml` 里固定成 `0x7f0f00a1`（紧跟 `title_joystick_led`
的 `0x7f0f00a0`），smali 里直接引用这个 ID。

### 为什么不直接换 `/system/app` 里的 apk

`/system` 是 `mmcblk1p4` 以 **ro** 挂载的，而且 `mount -o remount,rw /`
会直接失败：

```
'/dev/block/by-name/system' is read-only
```

不是 verity（`ro.boot.veritymode=disabled`）、也不是 SELinux
（`getenforce` = `Permissive`）、块设备 `ro=0`。真因是 **ext4 超级块带着
错误标志**，内核因此强制只读：

```
EXT4-fs (mmcblk1p4): error count since last fsck: 27
EXT4-fs (mmcblk1p4): initial error at time 1792543475: ext4_find_extent:928: inode 4336
```

要改只能先 `e2fsck -y` 修超级块再重启，风险与收益不成比例。

另外 `pm install -r` 也走不通：系统版 apk 用的是 AOSP 公共测试密钥
（`CN=Android, android@android.com`，序列号 `b3998086d056cffa`，
SHA-256 `C8:A2:E9:BC:...`），私钥不在手上，自签的包装上去签名对不上。

所以走 **bind mount 单个文件**，跟 `azahar-nano-zh` 是同一路数：

```
/vendor/etc/ngp/JoystickLedPicker-zh.apk
        ↓ mount --bind
/system/app/JoystickLedPicker/JoystickLedPicker.apk
```

`ngp-fixup.sh` 第 ⑩ 段在 `sys.boot_completed=1` 时做这件事（那时 `/vendor`
早已挂载），bind 成功后再 `am force-stop` 一次，让下次启动重新 mmap 新 apk。
源文件缺失或 bind 失败都保持原版，不会影响开机。

**不需要动 `oat/`**：apk 内容变了，`/data/dalvik-cache` 里的旧产物会自动失效重建。

### 复现这套改动

```bash
java -jar apktool.jar d -f -o decoded JoystickLedPicker.apk
# 改 decoded/res/values/strings.xml、values-zh-rCN/strings.xml、values/public.xml
# 改 decoded/smali/com/gammaos/joystickled/MainActivity.smali 里 updatePreviewLabel
java -jar apktool.jar b decoded -o unsigned.apk
zipalign -f -p 4 unsigned.apk aligned.apk
apksigner sign --ks ngp-app.jks --ks-pass pass:ngp45ht --ks-key-alias ngpapp \
    --out JoystickLedPicker-zh.apk aligned.apk
```

原版与改后逐字节对照之外，要在机器上 `am start` 截图确认 ——
只对比文件 md5 不能证明 UI 文案生效。

## 重新取这两个 APK

```bash
# NgpIme：本仓库 apps/NgpIme.apk 是 0.1.1（源码 main b9b03df）；
# 上游 v0.1.0 release 不含无障碍按键过滤。

# LANGOS：本仓库 apps/ 下这份就是镜像里用的（已改 3DS 目标），md5 见上表
```
