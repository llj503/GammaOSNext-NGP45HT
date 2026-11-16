# v43r4：恢复首次开机欢迎向导（语言 / Wi-Fi / 安装进度）

日期：2026-11-16　设备：NGP45HT / GammaOS Core 1.4.4 (Android 14) / RK3562

## 1. 结论：v43r3 首启**没有**欢迎界面

不是向导 APK 被删，是 v43 引入的首启脚本把它掐断了。镜像里向导一直完整存在：

| 取证项 | 结果 |
|---|---|
| 向导 APK | p4 `/system_ext/priv-app/LineageSetupWizard/LineageSetupWizard.apk` 10,452,719 B，versionName 14 |
| 向导页面 | `WelcomeActivity` / `LocaleActivity`（语言）/ `NetworkSetupActivity`（Wi-Fi）/ `DateTimeActivity` / `FinishActivity` 全在（aapt dump xmltree） |
| HOME 组件 | `org.lineageos.setupwizard/.SetupWizardActivity`，带 `ACTION_MAIN` + `DEVICE_INITIALIZATION_WIZARD` + `category.HOME` |
| build.prop | `ro.setupwizard.mode=OPTIONAL`（不是 DISABLED） |
| 禁用配置 | `/system/etc/sysconfig`、`permissions`、`disabled-packages` 里没有禁用项 |
| 安装链 | p4 `/etc/init/hw/init.rc` 815-819 每次开机把 `persist.gammaos.setupwizard_run/done/exit_code` 归零；1624 定义 `service gammaossetupwizard /system/bin/setup.sh`；1631 `on property:sys.boot_completed=1 && property:persist.gammaos.setupwizard_run=1 → start` |

**掐断点**（p5 `/bin/ngp-fixup.sh`，由 `/etc/init/ngp-fixup.rc` 在 `sys.boot_completed=1` 启动）：

- ⓪a-1：`settings put global device_provisioned 1` + `secure user_setup_complete 1` + `tv_user_setup_complete 1`。SetupWizard 判定「已完成」直接退出，`run` 永远为 0。
- ⓪a：`cmd package set-home-activity com.retrofront/.NativeActivity`，把 HOME 抢给 LANGOS；⑫a 还会 `am start` 拉起 LANGOS。
- v43r3 为修「7 个 app 全不装」加了 ⓪a-0 前台补跑 `setup.sh`，但**保留 ⓪a-1**，所以补装修好了、欢迎界面仍然没有。

原厂设计链本来是：向导走完 → 设 `run=1` → init 起 `gammaossetupwizard` 跑 `setup.sh`（装 apps.list 的 7 个 app、用 zstd 解开核心/配置/ROM）→ 向导显示安装进度页 tail `gammaos_setup.log` → `done=1` → 向导写 provisioning flags → 进桌面。v43 把这条链整个跳过了。

## 2. 修法（只改 p5 两个文件，不动 p4 / GPT / 向导 APK）

| 文件 | 改动 |
|---|---|
| `/bin/ngp-fixup.sh` | 995 → 1128 行。向导活跃时不写 flags、不抢 HOME、不启动 LANGOS、不抢跑 `setup.sh`；新增 `--postwizard` 后置分支 |
| `/etc/init/ngp-fixup.rc` | 763 → 1386 B。新增 init 直接托管的 `ngp_postwizard` oneshot 服务 |

**为什么要独立服务**：`ngp_fixup` 是 `oneshot`，在里面用 `&` 起等待任务会被 init 回收（v43r2 首启固件不播种就是同一个坑）。后置服务由 `on property:sys.boot_completed=1` 同时启动，与 `ngp_fixup` 并行，不拖慢 ⓪c 显示方向锁定（向导界面本身会倒转 180°，这条必须早执行）。

**`--postwizard` 做五件事**：

1. 等 `user_setup_complete=1` 或 `device_provisioned=1`，最多 10 分钟；
2. 若 flags 仍为 0（向导缺席/卡死），补写三个 provisioning flags，避免 Android 14 设置页一闪就退；
3. 给原厂安装链 60 秒启动窗口；若 `gammaossetupwizard` 在跑就等它结束（最多 15 分钟），仍无 `/data/setupcompleted` 则前台补跑 `setup.sh`，并复查 7 个 app；
4. 把 HOME 交回 `com.retrofront/.NativeActivity` + 补 `MANAGE_EXTERNAL_STORAGE` 授权；
5. 补 ⑫a 的 `rom_root → /storage/EEROMS`（向导期间不能启动 LANGOS 生成 shared_prefs，挪到这里）。

**已完成首启的机器**（`/data/setupcompleted` 存在）：`_WIZARD_ACTIVE=0`，行为与 v43r3 完全一致；后置服务几秒内跑完并保持幂等，不会重装用户卸载的 app、不重解 ROM。

## 3. 交付物

| 文件 | 用途 |
|---|---|
| `GammaOSCore-NGP45HT-20261116-v43r4.img.xz` | 全新刷机即用，首启直接出现欢迎页 |
| `v43r4-welcome-OTA.zip`（目录 `update-20261116-welcome/`） | 已刷 v43/v43r2/v43r3 的机器升级，只替换上面两个文件，不碰 /data |
| `install-welcome-ota.sh` | 一键装 OTA：本地校验 → 归档旧包 → push → 远端逐文件 sha256 → dry-run → 重启 |
| `reset-welcome-wizard.sh` | 装完 OTA 后，不清数据重看一次欢迎界面 |
| `sandbox-welcome.py` / `sandbox-adb.py` | 离线沙盘，可复现全部验证 |
| `SHA256SUMS-v43r4.txt` | 校验清单 |

## 4. 怎么用

### A. 全新刷机（推荐）

烧录 `v43r4.img.xz`。首次开机依次出现：欢迎 → **选语言** → **选 Wi-Fi** → 安装进度页（装 7 个模拟器 + 解包约 530 MB，3~8 分钟）→ 自动进 LANGOS 游戏库。

### B. 已刷 v43r3，不想重刷

```bash
bash install-welcome-ota.sh --dry       # 先看诊断
bash install-welcome-ota.sh --reboot    # 装 OTA，会自动重启两次
```

⚠️ `ngp-ota.sh` 每次只取**第一个**无 `STATUS.txt` 的 `update-*` 包，脚本会自动把旧包归档到 `/sdcard/OTA/archive/`。

装完 OTA 后，当前机器因为 `device_provisioned=1` 不会自动再弹向导。想立刻看一次：

```bash
bash reset-welcome-wizard.sh --dry
bash reset-welcome-wizard.sh --apply --reboot
```

复位只清 3 个 flags + 把 HOME 指向 `SetupWizardActivity` + 重启；**不删 /data、不删游戏存档**，`/data/setupcompleted` 保留，`setup.sh` 会以 `FRESH_SETUP=0` 只补装缺失 app。向导结束后后置服务把 HOME 设回 LANGOS。脚本会先检查 `ngp_postwizard` 服务已装，没装就拒绝执行（否则 HOME 会永久留在向导上）。

## 5. 验证

| 层 | 结果 |
|---|---|
| 离线取证 | v43r3 裸镜像按 GPT 抽 p4/p5，debugfs 只读 dump 出 `init.rc` / `setup.sh` / `rg52-home.sh` / `build.prop` / 向导 APK；aapt 确认页面与 HOME 组件 |
| 脚本语法 | `sh -n ngp-fixup.sh`、`bash -n make_ota_package.sh` / 两个安装脚本、构建脚本均通过 |
| 控制流沙盘 | `sandbox-welcome.py` 6 条路径全 PASS：全新首启（主分支不抢向导 / 后置兜底）、已完成首启（幂等不重装）、向导缺席（回落 v43r3 自愈）。`wm fixed-to-user-rotation` 在向导活跃时仍执行 |
| 安装沙盘 | `sandbox-adb.py` 跑通 `--dry`、`--reboot`（归档旧包 1 个、push 2 文件、远端 sha 逐项一致、dry-run OK）、复位 `--apply`（flags 归 0、HOME 指向向导、重启 1 次）、未装修复时拒绝（exit 1） |
| OTA 载荷 | manifest 的两条 sha256 与仓库模板、payload 三方一致 |
| 镜像 | 见下方「构建校验」，`build_v43r4.sh` 全流程断言 |

### 构建校验（见 `/home/liang/rainject/v43-work/build-v43r4.log`、`SHA256SUMS-v43r4.txt`）

- 镜像内两个文件 `debugfs dump` 回读与仓库模板 md5 一致；权限 `0755 0:2000`（58,213 B）/ `0644 0:0`（1,386 B）
- `sgdisk -v`：`No problems found`；分区表与 v43r3 逐字一致
- 4 MiB 分块硬比对：**差异 5 块，全在 p5，范围外 0 块**（p4 一个字节没动）
- 裸镜像 5,451,564,032 B，md5 `2d6e6ba7…f97`，sha256 `bdbe66b4…d6df`
- xz 2,041,987,380 B，sha256 `94edc189…5f07`；`xz -t` 通过，`xz -dc | md5sum` = `2d6e6ba7…f97`
- OTA zip 25,931 B，sha256 `6c46c5a5…93d`

## 6. 已知风险 / 待真机确认

1. **真机未验证**：构建与沙盘期间 `adb devices` 为 `no devices`。向导是否真的显示、语言/Wi-Fi 页能否用手柄操作、安装进度页能否正常 tail 日志，都要刷机后看。
2. **preferred HOME**：全新刷机 `/data` 为空，SetupWizard 会自然接管 HOME。已用过的机器走 `reset-welcome-wizard.sh`，脚本显式把 HOME 指向 `SetupWizardActivity`；向导完成后由后置服务设回 LANGOS。
3. **SELinux label**：`debugfs rm+write` 会丢 `security.selinux`，`ea_set` 又不会补结尾 NUL（内核不认），与 v43 已验证可执行的 `/bin/ngp-ota.sh` 一样留空。本机 `userdebug + permissive` 可执行；若将来切 enforcing，需重新补 label。
4. **超时兜底**：向导 10 分钟没完成、或安装链 15 分钟没结束，后置服务会自行补 flags / 补跑 setup.sh / 设 HOME，机器不会停在无桌面状态；但这段时间用户可能看到桌面未就绪。
5. **版本策略**：v43r4 目前只做本地交付，**未推 GitHub、未建 tag、未传百度网盘**。v43r3 的 Release 与 asset 一个字节不动。
