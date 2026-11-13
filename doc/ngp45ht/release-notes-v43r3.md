# GammaOS Core NGP45HT v43r3（2026-11-13）

## 改了什么

1. **修「刷机后没有 RetroArch 等 7 个模拟器/工具」**：v43 起 provisioning flags
   抢先写，SetupWizard 不跑 → `setup.sh` 从不执行 → apps.list 的 7 个 app 全不装。
   v43r3 开机前台补跑 `setup.sh`，并复查 7 个包；没齐就清掉完成标记，下次开机重试。
2. **补 `/system/bin/zstd`**：镜像里原本根本没有 zstd，而 `setup.sh` 的 8 个
   `.zst` 解包全靠它。不补的话 APK 装上了，RA 核心 / 配置 / ROM 也铺不开。
   NDK r27c 静态编译 zstd 1.5.7，qemu 实测解包与 x86 宿主逐字节一致。
3. ⓪a-1 提前到 ⓪a-0 之前，避免两个 `setup.sh` 并发；已完成首启的机器不干预，
   不重解 ROM、不强行装回用户卸载的 app。只改 2 个文件，其余字节与 v43r2 一致。

## 镜像

| 文件 | 字节 | SHA256 |
|---|---|---|
| `GammaOSCore-NGP45HT-20261113-v43r3.img.xz` | 2,041,983,764 | `96182e4b…8ab2` |
| `...v43r3.img`（解压后） | 5,451,564,032 | `4460c39f…b732` |
| `OTA/v43r3-upgrade-OTA.zip` | 541,108 | `48552834…c109` |

完整哈希见 `SHA256SUMS-v43r3.txt`；`xz -t` 与 `xz -dc | md5sum` 回读均通过。

## 刷机后

第一次开机会前台装 7 个 app 并解包约 530 MB，**约 3~8 分钟**，屏幕常亮，
期间不要断电、不要拔卡；之后 RetroArch 等模拟器应全部出现在系统里。
验证：`adb shell cat /data/ngp/setup-status.log` → `OK: 7/7 apps installed`。

已刷 v43 / v43r2 不想重刷：用 `OTA/v43r3-upgrade-OTA.zip`（会重启两次），
安装前把 `/sdcard/OTA/` 下所有旧的 `update-*` 目录移走。
早期的 rafix OTA 包不含 zstd，不要再拿它修这个问题。

细节见 `doc/ngp45ht/v43r3-CHANGES.md`。
