# apps —— 内置进 system 分区的应用

这两个 APK 直接写进 `/system/app/`，刷完机即存在，不需要用户再安装。

| 文件 | 包名 | 入口 | 大小 | md5 |
| --- | --- | --- | --- | --- |
| `NgpIme.apk` | `com.llj.ngpime` | `com.llj.ngpime/.NgpImeService` | 1,131,101 | `5cbaf7a244610c150970881e45415ef6` |
| `LANGOS.apk` | `com.retrofront` | `com.retrofront/.NativeActivity` | 3,913,400 | `3245d228852d76e0db1005523ce1900c` |

## NgpIme —— 手柄拼音输入法

来自 [llj503/ngp-pinyin-ime](https://github.com/llj503/ngp-pinyin-ime) 的
v0.1.0 release，没改过。它是手柄优先的离线拼音输入法，10×4 QWERTY 网格，
焦点环全走 D-pad，不需要触摸屏；词库是 CC-CEDICT + jieba 词频，打包在
`assets/dict.tsv.gz` 里，不联网、没有 INTERNET 权限。

系统自带的两个键盘（AOSP leanback、LeanKey）都只有英文，中文输入只能靠这个。

## LANGOS —— 游戏前端

`com.retrofront`，3.0 带电池修正版（`LANGOS-3.0-battfix.apk`）。
它同时声明了 `LAUNCHER` / `LEANBACK_LAUNCHER` / `HOME`，可以直接当桌面，
替掉上游镜像默认的 Daijishō。

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

注意 `rom_root` 要指到**放 ROM 的那一层**。如果指成 `/storage/emulated/0`，
LANGOS 会把 `ROMs`、`RetroArch` 这些一级子目录各自当成一个"平台"，
而不是进 `ROMs` 里按机种分类。

`ngp-fixup.sh` 里另有一段处理它和 vold 的竞态：LANGOS 比 vold 先起时读不到
rom_root，会误弹选择框（开机必现）；脚本等 public 卷挂载完成后，如果前台仍是
选择页就重启一次 LANGOS。

## 重新取这两个 APK

```bash
# NgpIme：直接用 release
curl -L -o NgpIme.apk \
  https://github.com/llj503/ngp-pinyin-ime/releases/download/v0.1.0/ngp-ime-0.1.0.apk

# LANGOS：本仓库 apps/ 下这份就是镜像里用的，md5 见上表
```
