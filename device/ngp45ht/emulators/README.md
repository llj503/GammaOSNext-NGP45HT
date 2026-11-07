# emulators —— 首启安装的模拟器 APK

`ngp-fixup.sh` 首次开机把这些 APK `pm install` 到 `/data/app`，玩家可在「应用」里卸载。
卸载后 `/data/ngp/emu-installed/<包名>` 标记保留，不会再自动装回。

| 文件 | 包名 | 版本 | 说明 |
| --- | --- | --- | --- |
| `NetherSX2.apk` | `xyz.aethersx2.android` | — | PS2；LANGOS 选择器里的 NetherSX2 / AetherSX2 |
| `Azahar-official-2126.2.apk` | `org.azahar_emu.azahar` | 2126.2-vanilla | 3DS；LANGOS 3.7.1 的 **Azahar(官方)**，用 content URI 直接启动。性能配置见 `../azahar/official-azahar-2126.2-mali-g52.ini` |
| `ARMSX2-2.9.2-legacy-armv8.0.apk` | `com.armsx2` | 2.9.2 legacy | PS2；LANGOS 3.7.1 直接用 ROM 绝对路径启动。**必须用 legacy armv8.0**：RK3562 是 Cortex-A53，armv8.2 包会在 `libemucore_4k.so` 读游戏序列号时 SIGILL |

来源与校验：

- 官方 Azahar：<https://github.com/azahar-emu/azahar/releases/tag/2126.2>
  `azahar-android-vanilla-2126.2.apk`，sha256
  `b511d1d38012c5ab0dfdb4479335059bb89ef17acfbf0ba45e79107ed4185ba3`
- ARMSX2：<https://github.com/ARMSX2/ARMSX2/releases/tag/2.9.2>
  `ARMSX2-2.9.2-legacy-armv8.0-sdk26.apk`，sha256
  `5603dbc218cd164a1ed1daadcf2d3a79ecb93a8e978bd845363aa415ee852fa1`

官方 Azahar 首次启动仍需完成一次向导（用户目录建议 `/storage/emulated/0/azahar-emu`，
授予文件系统权限），并在游戏手柄设置里 **Auto-Map Controller** 按一次 A；
ARMSX2 需要用户自己配置 BIOS/ROM 目录。
