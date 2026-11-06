# PS2 / 3DS 模拟器改为可卸载（v39）

## 需求

玩家想自己换模拟器。原来两个都是焊死在系统里的：

| 模拟器 | 位置 | 类型 | 能卸吗 |
|---|---|---|---|
| NetherSX2（PS2） | `/vendor/app/NetherSX2/NetherSX2.apk` | vendor app，系统扫描安装 | ✗ |
| AzaharSf（3DS） | `/system/app/AzaharSf/AzaharSf.apk` | system app + `sharedUserId=android.uid.system` | ✗ |

## PS2：真改成可卸载

### 改动

1. **apk 位置**：`/vendor/app/NetherSX2/NetherSX2.apk` → `/vendor/etc/ngp/emulators/NetherSX2.apk`
   （`/vendor/etc` 不参与 PackageManager 扫描，放这里就是个普通数据文件）
2. **`ngp-fixup.sh` 新增第 ⑫b 段**：首次开机 `pm install`，装进 `/data/app`，
   玩家在「设置 → 应用」里能正常卸载。
3. **卸载后不重装**：见下。

### 卸载后为什么不会又装回来

直觉做法是查 `pm list packages -u`（带 `-u` 会列出「保留数据的已卸载包」）。
**实测本机不成立**：

```
# 卸载 com.armsx2 之前
pm list packages    | grep armsx2  -> 1 条
pm list packages -u | grep armsx2  -> 1 条
# pm uninstall com.armsx2 之后
pm list packages    | grep armsx2  -> 0 条
pm list packages -u | grep armsx2  -> 0 条   ← 记录也没了
```

所以改成**自己维护标记**：

```
/data/ngp/emu-installed/<包名>     # 首次装成功时创建
```

判据：

| 已装 | 标记 | 动作 |
|---|---|---|
| 是 | — | 比 md5，不一致就 `pm install -r` 升级；顺手补标记 |
| 否 | 有 | **玩家自己卸的，跳过不装** |
| 否 | 无 | 首次，`pm install` 并建标记 |

玩家想恢复内置模拟器：`rm /data/ngp/emu-installed/xyz.aethersx2.android` 再重启。

### 实测（设备上用 ARMSX2 模拟玩家卸载）

| 场景 | 输出 |
|---|---|
| 有标记 + 未装 | `armsx2: user uninstalled, keep it uninstalled (SKIP)` |
| 删标记 + 未装 | `armsx2: installed to /data/app`，标记自动重建 |

## 3DS：动不了，但有替代路径

### 为什么不能移出 /system

`AzaharSf` 是 GammaOS 的 3DS 前端壳，只有 45 KB，真正干活的是
`/system/bin/azahar-nano` + `/vendor/azahar/libazahar-nano-core.so`（37 MB）。
它启动游戏的机制是：

1. 把 ROM 路径写进 `/data/system/nano_azahar_nano_rom.txt`
2. `setprop sys.gammaos.azahar_nano.start_app 1`
3. 轮询 `sys.gammaos.azahar_nano.session` 等状态

`/data/system` 是 `system:system 0711`，普通 app 写不进去；`setprop` 到
`sys.gammaos.*` 也需要 system 权限。所以 Manifest 里是
`android:sharedUserId="android.uid.system"` + `usesNonSdkApi="true"`。

这条链意味着：

- 重签名 → 丢 `sharedUserId`（签名不是 platform key）→ setprop 失败 → 起不了游戏
- 移到 `/data/app` → 同上
- 只有留在 `/system/app` 且用 platform 签名才成立

**结论：AzaharSf 无法做成"可卸载"。**

### 那玩家怎么换 3DS 模拟器

两条路，都不需要动 system：

1. **装官方的就行**。装 `org.azahar.azahar`（或 Citra）之后，LANGOS 的
   「选择模拟器」会把内置的和新装的一起列出来，玩家点哪个用哪个。
   详见 `LANGOS-emulator-picker.md`。
2. **想让内置的彻底消失**：建一个标记文件，开机时 `ngp-fixup.sh` 会把它
   `pm disable-user`：

   ```sh
   mkdir -p /data/ngp && touch /data/ngp/disable-internal-3ds
   # 重启后 com.gammaos.azaharsf 变成 disabled 状态
   # 恢复：rm /data/ngp/disable-internal-3ds && pm enable com.gammaos.azaharsf
   ```

   `disable` 之后它不出现在启动器里，LANGOS 的 `isPackageInstalled` 也查不到
   （`getPackageInfo` 对 disabled 包会抛），候选表自然不会再列它。

## 镜像侧改动（v39）

p5 vendor 分区：

| 动作 | 路径 |
|---|---|
| 删除 | `/vendor/app/NetherSX2/`（整个目录，含 apk 和 oat） |
| 新增 | `/etc/ngp/emulators/NetherSX2.apk`（21,621,788 B） |
| 覆盖 | `/etc/ngp/LANGOS.apk`（换成 `LANGOS-3.5-emupick.apk`） |
| 覆盖 | `/bin/ngp-fixup.sh`（加第 ⑫b 段） |

⚠️ **必须把 `/vendor/app/NetherSX2/` 删掉**。只加 apk 不删目录的话，
系统还是会把那个当 system app 装上，`pm install` 会因为签名/版本冲突失败，
玩家依旧卸不掉。
