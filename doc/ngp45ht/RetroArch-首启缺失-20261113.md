# v43 / v43r2 刷机后没有 RetroArch —— 根因与修复（2026-11-13）

## 结论

**不是镜像里没打包 RetroArch，是首启安装脚本从头到尾没运行。**

v43 引入的 `ngp-fixup.sh` ⓪a-1 段在 `sys.boot_completed=1` 后抢先写
`device_provisioned=1` / `user_setup_complete=1`，LineageOS SetupWizard 判定
「已完成」直接退出，于是 `persist.gammaos.setupwizard_run` 永远是 0，
init 里的 `gammaossetupwizard` 服务（执行 `/system/bin/setup.sh`）从不启动。
`/system/etc/gammaos/apps.list` 的 **7 个 app 全部没装**：RetroArch、
MiXplorer、Aurora Store、PPSSPP、DraStic、Flycast、M64Plus FZ。

影响范围：**v43 与 v43r2 都中招**（v42 的首启脚本没有 ⓪a-1，不受影响）。

## 证据链（全部离线从 v43r2 镜像 debugfs 取证）

| 环节 | 位置 | 内容 |
|---|---|---|
| 素材在 | p4 `/system/etc/` | `RetroArch_aarch64.apk` 183,397,852 B、`retroarch.tar.zst` 356,899,832 B、`roms.tar.zst` 174,649,251 B；v42 基线逐项同尺寸，v43 没删任何东西 |
| 清单在 | p4 `/system/etc/gammaos/apps.list` | 第 10 行 `RetroArch\|com.retroarch.aarch64\|/system/etc/RetroArch_aarch64.apk\|\|post_retroarch`，共 7 条 |
| 安装者 | p4 `/system/bin/setup.sh` | `install_apps` 读 apps.list 逐个 `pm install`；`post_retroarch` 解包 + 授权 + 置 gl 驱动；尾部 `mkdir -p /data/setupcompleted` |
| 触发条件 | p4 `/system/etc/init/hw/init.rc` 815-819 / 1624-1632 | 815-819 每次开机把 `persist.gammaos.setupwizard_run=0`、`done=0`；1624 `service gammaossetupwizard /system/bin/setup.sh`；1631 `on property:sys.boot_completed=1 && property:persist.gammaos.setupwizard_run=1 → start`。**run=1 只有 SetupWizard 会设** |
| 谁掐断 | p5 `/vendor/bin/ngp-fixup.sh` ⓪a-1 | `settings put global device_provisioned 1` + `secure user_setup_complete 1` + `tv_user_setup_complete 1`；`/vendor/etc/init/ngp-fixup.rc` 是 `on property:sys.boot_completed=1 start ngp_fixup`，与 SetupWizard 同批触发且更早 |
| 回归点 | v42 dump `ngp-fixup-v42.sh` | 全脚本无 `device_provisioned` / `user_setup_complete` 字样 → ⓪a-1 确为 v43 从 PokectAis 合并进来的新增段 |
| 真机交叉印证 | 11-12 提取 APK 时 | 刷了 v43 的机器上 apps.list 的 7 个包一个都没有（当时记录「系统里没有 RetroArch」），只有 vendor 预置的 4 个模拟器 + LANGOS + 机型工具 |

顺带排除：`ngp-fixup.sh` ⑧ 段只负责给**已存在**的
`/storage/emulated/0/Android/data/com.retroarch.aarch64/files` 补中文和字体，
不负责安装；它 `if [ -d "$RA_DIR" ]` 判空直接跳过，所以中文修复也不会触发。

## 修复

### A. 手上这台机器立刻修（不用重刷、不用等 SetupWizard）

`hotfix-20261113/fix-retroarch-on-device.sh`：

```bash
bash fix-retroarch-on-device.sh --dry   # 先看状态
bash fix-retroarch-on-device.sh         # 前台补跑 setup.sh，3~8 分钟
```

脚本做四件事：打印 `device_provisioned` / `setupwizard_run` / `done` /
`/data/setupcompleted` / setup.log；列出 7 个包；前台执行
`/system/bin/sh /system/bin/setup.sh`（`timeout 900`）；复查并打印日志末尾。
**前台同步**是关键 —— `ngp_fixup` 是 oneshot，后台任务会被 init 回收
（v43r2 首启固件不播种就是同一个坑）。

### B. 防止以后重现 / 让开机自愈：本地 OTA 包

`OTA/v43r2-rafix-OTA.zip`（21,594 B，sha256 `061356fe…b972db`）：

```bash
unzip v43r2-rafix-OTA.zip -d /sdcard/OTA/
adb reboot
```

只替换 `vendor/bin/ngp-fixup.sh` 一个文件（48,883 B，md5 `00dfe140…`，
manifest sha256 `4e2240dc…be1`），`reboot=1`。新脚本在 ⓪a-1 之前插入
**⓪a-0**：

```sh
if [ -x /system/bin/setup.sh ] && [ ! -e /data/setupcompleted ]; then
    # 若上游服务已在跑就等它完成，否则前台直接跑
    /system/bin/sh /system/bin/setup.sh
fi
```

判据用 `/data/setupcompleted`（setup.sh 成功收尾时建的目录），已装过的机器
直接跳过，不重解 ROM / 存档。跑完再走 ⓪a-1 补 provisioning flags，
「设置一闪就退」的修复不回退；⑧ 段随后能立刻给刚装好的 RA 补简体中文与字体。

⚠️ `ngp-ota.sh` 每次只取**第一个**待处理包。`/sdcard/OTA/` 里若还留着
`update-20261111-seedfix`，会先应用旧包并重启，下一次才轮到新包。
**先把旧目录移走，只留 `update-20261113-rafix/`。**

### C. 镜像层（v43r3）

同一份 `ngp-fixup.sh` 直接进镜像即可，无需改其它文件。
重出镜像 / 另发 release 尚未执行 —— 需要你点头（2 GB 重出 + 上传）。

## 验证与待办

已做：
- `sh -n` / `bash -n` 通过，脚本 925 → 959 行
- OTA manifest 的 sha256 与载荷实测一致；应用器 `--dry-run` 通过（1 文件 / 46 KB vendor / `reboot=1`）
- 修复脚本与 payload、仓库版三份 md5 一致

待上机（当前 `adb devices` 为 `no devices`）：
1. `bash fix-retroarch-on-device.sh --dry` 看 7 个包是否全 MISSING、`setupwizard_run=0`、`/data/setupcompleted=MISSING`
2. 跑修复，判据 `pm path com.retroarch.aarch64` 返回 `package:/data/app/.../base.apk`
3. 看 `/data/data/org.lineageos.setupwizard/files/gammaos_setup.log` 末尾

**已知风险（真机才能确认）**
- 镜像的 `/system/bin` 与 `/vendor/bin` 里**没找到 `zstd` 二进制**，而
  `setup.sh` 的 `extract_archive_once()` 用 `zstd -dc "$archive" | tar -x -P -C /`。
  若设备上确实缺，7 个 APK 会装成功、但 RA 核心/配置/ROM 解包失败 ——
  日志里会出现 `extracting ... failed`。看到就把日志发回来，再补 zstd 或
  改用 PC 侧解包推送。
- `/system/bin/setup.sh` 正常由 init 以 `u:r:gammaossetupwizard:s0` 运行；
  这里是从 `u:r:shell:s0`（ngp_fixup / adb shell）前台调用。本机
  `ro.build.type=userdebug`、SELinux permissive，风险低，但 `pm grant` /
  `chown` 类操作仍建议真机复核一次。
