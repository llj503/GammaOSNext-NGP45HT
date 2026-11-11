# v43 更新说明（2026-11-11）

## 一句话

集成 Vita3K+ v1.4 与 PS Vita 固件，PSV 不用再手工装模拟器/固件；同时加入
本地 OTA 增量升级，并把 PokectAis 仓库里适用于 NGP45HT 的通用修复合并进来。

基线：`v42-ngp45ht-20261107`（LANGOS 3.7.1 + 官方 Azahar / ARMSX2）。

## 一、为什么是 Vita3K+ 而不是官方 Vita3K

官方 `org.vita3k.emulator` continuous（v0.2.1 4303-e96df7a5）在本机反复崩溃：

- tombstone 里是 4 地址递归环
  `0x169aa88 → 0x13848ac → 0x10b0db8 → 0x1699348 → 0x169aa88`，
  形态为 `ThreadState::wait(CB_BIT) → run_callbacks() → 回调进游戏代码 → 再 wait`；
- `signal 5 (SIGTRAP)` 由 Vita3K 自身 `signal_handler` 在 `Unhandled access` 后
  `raise(5)`，不是 GPU 驱动或显存问题；
- 关掉异步管线编译 / compile-shaders / validation-layer 仍崩；
- 上游 `shouldShowCustomDriverOptions()` 对 Mali 返回 false，自定义驱动 UI
  整块隐藏，malisx2 方案在官方版上也走不通。

Vita3K+ v1.4 汉化版（`org.vita3kplus.emulator`，versionCode 140）实机用
**系统 Vulkan**（Mali-G52 / r25p0）跑通 `PCSE00328 / Blast 'Em Bunnies`，
日志有稳定帧率输出，无 SIGTRAP / tombstone。两者包名不同，可与官方版共存。

> LANGOS 的 PSV 入口原来写死 `org.vita3k.emulator`。v43 改为
> `org.vita3kplus.emulator`，启动 Activity 仍是 `org.vita3k.emulator.MainActivity`。

## 二、镜像里到底放了什么

### p5 vendor（4 个文件）

| 动作 | 路径 | 大小 | 说明 |
|---|---|---|---|
| 覆盖 | `/etc/ngp/LANGOS.apk` | 3,920,516 B | 3.7.1-v43，versionCode 24→25 |
| 新增 | `/etc/ngp/emulators/Vita3K-Plus-v1.4.apk` | 25,092,114 B | 首启 `pm install`，可卸载 |
| 覆盖 | `/bin/ngp-fixup.sh` | 44,117 B | +71 行 |
| 新增 | `/bin/ngp-ota.sh` | 9,472 B | 本地 OTA 应用器，mode 0755 gid 2000 |

LANGOS 改动：

- `getStandaloneEmulator("psv"/"psvita")` → `org.vita3kplus.emulator`；
- `getStandaloneActivity()` 前置分支返回 `org.vita3k.emulator.MainActivity`；
- `AndroidManifest.xml` 的 `<queries>` 补 `org.vita3kplus.emulator`
  （Android 11+ 包可见性，不补会判成「没装」）；
- 证书沿用 `device/ngp45ht/apps/langos.jks`，SHA-256 `05689c30…b756`，
  与 v42 一致，可覆盖升级。

### p4 system（1 个文件，132 MiB）

`/system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz`，131,812,544 B，
sha256 `23cbfe29ba6991091878b89936c8439630a4a3a39fc30f78f9e1d091b363c813`。

内容来自设备实测可跑的 Vita3K+ `files/`（3452 文件 / 465 MiB），排除商业游戏
`ux0/app/PCSE00328` 与 shader cache 后压成 126 MiB：

- PS Vita 固件 / 字体 / `os0 sa0 vs0` 系统目录；
- VitaFS 骨架与空目录 `gui-configs/ cache/ cheats/ patch/ textures/` 等；
- `config.yml`：`show-welcome: false`、`warn-missing-firmware: false`、
  `initial-setup: false`、`backend-renderer: Vulkan`、`custom-driver-name: ""`。

**不含商业游戏**。玩家把游戏拷到 `ux0/app/<TITLE_ID>/` 即可被 Vita3K+ 扫描。

### p4 先回收空隙再注入

v42 的 p4 分区是 3400 MiB，但 ext4 文件系统只建到 3003 MiB，尾部约 397 MiB
一直空着；p5 只有约 136 MiB 空闲，放不下 132 MiB 种子包。

```
e2fsck -fy p4.img → resize2fs p4.img "${P4_SEC}s" → 按 offset 写回原 img
```

- Block count 768879 → 870400，Free blocks 13230 → 119248，inode 88 → 1140；
- 注入后 Free blocks 87065（约 340 MiB 可用）；
- **不能直接对 `img?offset=...` 跑 resize2fs**：e2fsprogs 1.47.2 会把整个
  镜像 ftruncate 到文件系统大小，p5..p9 全丢。必须抽出独立 p4.img 再写回；
- GPT 与 p5..p9 分区几何完全未改。

### 首启播种（ngp-fixup.sh 第 ⑬ 段）

```sh
xz -dc "$V3K_SEED" | tar -xf - -C "$V3K_DEST"
chown -R "$_uid:$_gid" "$V3K_DEST"   # uid 取 /data/data/<pkg>，gid 取 Android/data
chmod -R 770 "$V3K_DEST"
: > /data/ngp/vita3k-plus-seeded
```

条件：种子包存在 + 标记不存在 + `pm path org.vita3kplus.emulator` 成功。
后台执行，解包失败下轮开机重试。设备 `/system/bin/xz` 5.7.0alpha 支持 `-dc`。

## 三、本地 OTA（合并自 PokectAis）

`/sdcard/OTA/update-*/` 目录包，开机由 `ngp-fixup.sh` ⓪0 钩子调用
`ngp-ota.sh`：

1. 等 `/sdcard` 挂载，找第一个无 `STATUS.txt` 的包；
2. 校验 manifest（路径只允许 `system/*` / `vendor/*`，禁 `..` 与空格）、
   逐文件 sha256、剩余空间、`ro.boot.veritymode=disabled`；
3. remount 后用「同目录临时文件 → `mv`」替换，写 `STATUS.txt`，
   `reboot=1` 时 `setprop sys.powerctl reboot`；
4. 失败不写任何系统文件，只记原因；`/data/ngp/ota.log` 存历史。

配套 `scripts/make_ota_package.sh` 生成包，逻辑载荷名自动映射到仓库里带
版本号的真实文件。实测：只带两个脚本的小包 53 KiB，全量包 153 MiB。
详见 `doc/ngp45ht/local-ota.md`。

### PokectAis 合并取舍

| 合并 | 未合并（Pocket AIS 专用） |
|---|---|
| 本地 OTA 机制 + ⓪0 钩子 | SDIO WiFi 看门狗 |
| `device_provisioned` / `user_setup_complete` / `tv_user_setup_complete` 补齐 | 专用 DTB / 面板时序 / 音频功放补丁 |
| LANGOS 空 ROM 根目录守卫（路径改 `/storage/EEROMS`） | 专用按键 remap / HOME 抢占修复 |
| — | Daijishō seed / setup.sh 补装逻辑 |

`device_provisioned` 是必要的：LANGOS 抢了 home 之后 SetupWizard 不再运行，
三个标记不补会卡在 provisioning 状态。

## 四、验证

| 项 | 结果 |
|---|---|
| GPT `sgdisk -v` | No problems found，18399 free sectors |
| p4/p5 注入文件回读 | 5 个文件 debugfs dump 的 md5 与源逐字节一致 |
| 4 MiB 分块比对 | 75 个差异块：p4=63、p5=12、**范围外 0** |
| debugfs 写入方式 | 用 `rm` 而非 `unlink`（unlink 不释放 inode，会留孤儿块） |
| e2fsck | p4 / p5 均 `Filesystem state: clean` |
| 裸镜像 | 5,451,564,032 B，md5 `548dcf1a…f10f1`，sha256 `931309ac…24a` |
| `.img.xz` | `xz -t` 通过，解压 md5 与裸镜像一致，见 `SHA256SUMS-v43.txt` |
| OTA 打包脚本 | `bash -n` 通过；小包/全量包 manifest 与载荷 sha256 实测正确 |
| 仓库模板对齐 | 注入镜像的 5 个文件与 `device/ngp45ht/` 下模板 md5 一致 |

**未做**：真机刷机首启验证（固件解包、LANGOS PSV 拉起、OTA 重启链）需要
上机跑，镜像层已全部静态校验通过。

## 五、升级注意

- 只改 p4 / p5，**userdata 不动**，存档和设置都在；从 v42 升级不需要清数据
- 首次开机等 10~20 秒：LANGOS 覆盖安装、Vita3K+ 首装、固件后台解包
- 想恢复被卸掉的 Vita3K+：`rm /data/ngp/emu-installed/org.vita3kplus.emulator`
  再重启
- 想重新播种固件：`rm /data/ngp/vita3k-plus-seeded` 再重启
- 种子包 132 MiB 超过 GitHub 单文件 100 MB 限制，**未入库**；重建镜像需
  从设备 `files/` 重新生成（见 `scripts/build_v43.sh` 注释）
