# GammaOS Core NGP45HT v43r4（2026-11-16）

## 改了什么

1. **恢复首次开机欢迎向导**：v43 起首启脚本抢写 provisioning flags、抢 HOME
   给 LANGOS，SetupWizard 判定「已完成」直接退出，刷机后没有欢迎 / 语言 /
   Wi-Fi 页面。v43r4 让原厂向导链完整跑起来（向导 → `run=1` → init 起
   `setup.sh` → 安装进度页 → 进桌面）。
2. **新增 init 托管的 `ngp_postwizard` 服务**：向导期间不写 flags、不抢 HOME、
   不启动 LANGOS、不抢跑 `setup.sh`；向导结束后把桌面与 rom_root 交回
   LANGOS，并兜底补装 apps.list 的 7 个 app。v43r3 的 zstd / 补装修复不回退。
3. 只改 p5 两个文件（`ngp-fixup.sh` 995→1128 行、`ngp-fixup.rc` 加服务），
   其余字节与 v43r3 一致；已完成首启的机器行为不变，不重解 ROM、不重装
   用户卸载的 app。

## 镜像

| 文件 | 字节 | SHA256 |
|---|---|---|
| `GammaOSCore-NGP45HT-20261116-v43r4.img.xz` | 2,041,987,380 | `94edc189…5f07` |
| `...v43r4.img`（解压后） | 5,451,564,032 | `bdbe66b4…d6df` |
| `v43r4-welcome-OTA.zip` | 25,931 | `6c46c5a5…93d` |

完整哈希见 `SHA256SUMS-v43r4.txt`；`xz -t` 与 `xz -dc | md5sum` 回读均通过，
4 MiB 分块比对差异 5 块全在 p5、范围外 0。

## 刷机后

首次开机依次出现：欢迎 → 选语言 → 选 Wi-Fi → 安装进度页（装 7 个模拟器并
解包约 530 MB，**约 3~8 分钟**，别断电）→ 自动进 LANGOS 游戏库。
验证：`adb shell cat /data/ngp/welcome-status.log`。

已刷 v43 / v43r2 / v43r3 不想重刷：用 `v43r4-welcome-OTA.zip`（会重启两次），
安装前把 `/sdcard/OTA/` 下旧的 `update-*` 目录移走；装完想立刻重看一次向导，
用 `reset-welcome-wizard.sh --apply --reboot`（不清数据）。

细节见 `doc/ngp45ht/v43r4-CHANGES.md`。
