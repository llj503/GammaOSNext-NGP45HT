# 本地 OTA（增量文件包）

v43 起支持不重刷整卡升级：把一个小目录包拷进掌机的 `/sdcard/OTA/`，重启后由
开机脚本校验并替换 `/system`、`/vendor` 里的文件，再自动重启生效。用户数据
（`/data` 里的应用数据、`/sdcard` 上的 ROM 与存档）完全不碰。

## 为什么不是官方 update.zip

- 本机没有 recovery 分区，也没有 A/B 槽和 `update_engine`；
- 镜像是社区拼装、非发布密钥签名，官方 payload 的签名校验无法通过；
- 能用的只有「开机后以 root 写系统分区」这一条路。好处是包可以只带变动的
  文件（常见更新只有几十 KB），坏处是必须重启、且第一次要先装好钩子。

整卡重刷仍然是最终兜底：OTA 不修改分区表，刷回旧镜像随时可以恢复。

## 工作原理

1. 开机完成（`sys.boot_completed=1`）时，init 以 root 运行
   `/vendor/bin/ngp-fixup.sh`；
2. 它第一件事调用 `/vendor/bin/ngp-ota.sh`；
3. `ngp-ota.sh` 等 `/sdcard` 挂载好，找 `/sdcard/OTA/update-*/` 下第一个没有
   `STATUS.txt` 的包；
4. 校验 manifest 合法性、逐个文件比对 sha256、检查剩余空间和 dm-verity 状态；
5. 重新挂载 `/system`、`/vendor` 为可写，逐个文件「同目录临时文件 → `mv` 覆盖」；
6. 在包目录写 `STATUS.txt`，然后 `setprop sys.powerctl reboot` 重启生效。

校验失败不会写任何文件，只写 `STATUS.txt` 说明原因，本次开机照常继续。
应用中途失败时已经替换的文件保持新版本，删掉 `STATUS.txt` 再重启会整包重试
（替换是幂等的）。

## 包格式

```
update-20261111a/
  manifest.txt
  README.txt                      # 给人看的说明，不参与校验
  payload/
    vendor/etc/ngp/LANGOS.apk
    vendor/bin/ngp-fixup.sh
```

`manifest.txt` 用 `|` 分隔，路径不允许含空格：

```
format=1
pkg=update-20261111a
reboot=1
file|vendor/etc/ngp/LANGOS.apk|0644|0|0|<sha256>
file|vendor/bin/ngp-fixup.sh|0755|0|2000|<sha256>
```

- `pkg=` 只作记录，去重标记和日志一律用包目录名；
- `file|路径|mode|uid|gid|sha256`，路径是相对根目录的 `system/...` 或 `vendor/...`；
- 其它前缀、含 `..`、含空格的路径一律拒绝，避免包被写坏时改到别的分区；
- `reboot=0` 时应用后不重启（脚本类文件下次开机自然生效，APK 需要手动重启）。

`sha256` 是完整性校验，不是来源认证：能往 `/sdcard` 写文件的程序也能放包。
本机是 userdebug/root 环境，这层防护的边界就是「别让包损坏」，不是对抗本机
上的恶意软件 —— 真有恶意软件，它本来就能改 `/data`。

## 制作

```bash
cd device/ngp45ht/scripts
./make_ota_package.sh /sdcard/OTA update-20261111a ngp-fixup.sh ngp-ota.sh
```

- 第一个参数是输出根目录，第二个是包名（必须以 `update-` 开头）；
- 后面的参数是逻辑载荷名，省略则打包全部（约 153 MiB，其中固件种子包 132 MiB）。
  常见更新只带几个脚本，几十 KB 就够；
- 载荷文件按 `$NGP_PAYLOAD_DIR` → 脚本同目录 → `device/ngp45ht/` 下
  `apps / emulators / ime / scripts` 的顺序查找。仓库里的 APK 带版本号，
  由 `src_of()` 做映射；
- `vita3k-plus-seed.tar.xz` 132 MiB 超过 GitHub 单文件 100 MB 限制，**未入库**。
  要打全量包先生成种子包，再设 `NGP_PAYLOAD_DIR` 指向它所在目录：

  ```bash
  NGP_PAYLOAD_DIR=/home/liang/rainject/v43-work/payload \
    ./make_ota_package.sh /tmp/OTA update-20261111b
  ```

- 载荷到系统路径的映射表在 `make_ota_package.sh` 的 `dest_of()`，必须与
  `scripts/build_v43.sh` 的落盘路径一致；
- 生成后把整个包目录拷到掌机的 `/sdcard/OTA/` 下，重启。

## 应用与排错

结果看两处：

- 包目录里的 `STATUS.txt`（成功写 `applied ...`，失败写 `failed: 原因`）；
- `adb shell cat /data/ngp/ota.log`，历史 manifest 存在
  `/data/ngp/history/`，失败记录在 `/data/ngp/failed/`。

只想检查不写入（不会重启）：

```bash
adb shell /vendor/bin/ngp-ota.sh --dry-run
```

常见失败原因：sha256 不符（拷卡时损坏）、空间不足、`ro.boot.veritymode` 不是
`disabled`、分区重挂载失败。前三种在制作/拷贝阶段就能排除。

想重新应用一个**已经成功**的包（比如手工改了包里的文件），要同时删掉包目录里的
`STATUS.txt` 和 `/data/ngp/applied/<包名>`；只删一个还是会被跳过。失败重试只需
删 `STATUS.txt`。这样设计是为了防止 `/sdcard` 写失败时同一个包每次开机都被
重刷、反复重启。

## 首次安装钩子（只做一次）

刷了 v42 或更早版本、想直接走 OTA 而不重刷整卡的机器，需要先把钩子推进 `/vendor`：

```bash
adb root
adb remount
adb push device/ngp45ht/scripts/ngp-ota.sh   /vendor/bin/ngp-ota.sh
adb push device/ngp45ht/ime/ngp-fixup.sh     /vendor/bin/ngp-fixup.sh
adb shell chmod 0755 /vendor/bin/ngp-ota.sh /vendor/bin/ngp-fixup.sh
adb shell restorecon /vendor/bin/ngp-ota.sh /vendor/bin/ngp-fixup.sh
adb reboot
```

`adb remount` 依赖 verity 已关闭（本镜像 `ro.boot.veritymode=disabled`）。
`scripts/build_v43.sh` 构建的镜像已自带这两个文件，刷过 v43 的机器不需要这一步。

## 限制

- **只能改 `/system`、`/vendor`**，不改分区表、不动 `/data`、不做 A/B 回滚；
- **系统分区里的 APK 换包时 `versionCode` 要递增**。同版本号替换
  `vendor/etc/ngp/LANGOS.apk`，PackageManager 可能沿用缓存的解析结果；
  即使刷新，`/data` 里的旧 dexopt 产物也要等下一次校验才会重编。
  拿不准时用更高的版本号重新打包；
- 包在开机时应用，**应用完必定重启一次**（`reboot=0` 除外）；
- 包目录必须完整拷完再重启：`manifest.txt` 不在时该目录会被跳过，不会误判失败；
- 回滚用整卡镜像；也可以做「旧文件包」走同一机制推回去，但要把 `versionCode`
  处理好。

## 实战：v43 首启播种热修复包

`OTA/update-20261111-seedfix/`（`v43-seedfix-OTA.zip`）是单文件最小包，
只替换 `vendor/bin/ngp-fixup.sh`，修的是 v43 首启固件不播种的
`oneshot` + 后台 `&` 问题。这是本机制第一次用于现网修复：

```bash
./make_ota_package.sh <out-root> update-20261111-seedfix ngp-fixup.sh
```

应用后 `reboot=1` 自动重启，重启时新脚本前台解包固件 / 字体并写标记。
详见 `v43-CHANGES.md`「六、v43r2 首启播种热修复」。
