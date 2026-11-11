# v43r2 — 修复 Vita3K+ 首启固件不播种

## 改了什么

1. **开箱即用真正生效**：v43 首启 Vita3K+ 会提示「安装主固件 / 字体包」。
   根因是 `ngp_fixup` 为 `oneshot` 服务，第 ⑬ 段把解包放进后台 `&`，
   主线程退出后被 init 连同进程组回收。现改为前台同步解包，写完标记才退出。
2. **已刷 v43 不用重刷**：附 `v43-seedfix-OTA.zip`，放进 `/sdcard/OTA/`
   重启即自动替换 `vendor/bin/ngp-fixup.sh` 并再次重启完成播种。
3. 顺带加固：uid 用 `stat -Lc` 取、每次开机强制修正 `show-welcome` /
   `warn-missing-firmware`、解包日志落 `/data/ngp/vita3k-seed.log`。

## 镜像与文件

| 文件 | 大小 |
|---|---|
| `GammaOSCore-NGP45HT-20261111-v43r2.img.xz` | 2,041,587,900 B |
| 解压后 `.img` | 5,451,564,032 B |
| `v43-seedfix-OTA.zip` | 20,973 B |

基线 v42，只改 p4 system + p5 vendor，**userdata 不动**。
校验见 `SHA256SUMS-v43r2.txt`。**原 v43 发布物一个字节未动**。

## 刷完注意

- 首次开机固件解包约 20~60 秒（前台跑完再退出），解包完再点开 Vita3K+
- 判据：`adb shell cat /data/ngp/vita3k-seed.log`
- 商业游戏不含，自己拷进 `ux0/app/<TITLE_ID>/`

详细变更见 `v43r2-CHANGES.md` / 仓库 `doc/ngp45ht/v43-CHANGES.md` 第六章。
