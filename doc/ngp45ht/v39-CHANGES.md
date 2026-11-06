# v39 更新说明（2026-11-06）

## 一句话

开游戏时能选模拟器了；PS2 的 NetherSX2 从系统里挪出来，玩家可以卸载/更换。

## 一、开游戏时可选模拟器

以前 LANGOS 每个平台硬编码一个模拟器包名，装了几个都只能用那一个。
现在点启动时：

- 该平台**只装了 1 个** → 直接用，不打扰
- 装了 **≥2 个** → 弹「选择模拟器（平台）」，列出全部已安装的

| 平台 | 会自动列出的候选 |
|---|---|
| PS2 | NetherSX2 / AetherSX2、ARMSX2 |
| 3DS | 内置 Azahar 前端、官方 Azahar、Citra、Citra MMJ |
| PSP | PPSSPP、PPSSPP Gold |
| NDS | DraStic、内置 DraStic 前端 |

「最近游玩 / 收藏」屏也生效（按游戏自身平台判断，不会因为屏 ID 是 `recent` 就失效）。

> 顺带修了 Android 11+ 的包可见性问题：`AndroidManifest.xml` 的 `<queries>`
> 里没有列的包，`getPackageInfo` 会直接抛异常，导致候选全部被判成「没装」。

## 二、PS2 模拟器改为可卸载

NetherSX2 原来放在 `/vendor/app/NetherSX2/`，属于 system app，玩家既卸不掉
也换不了。现在：

- apk 挪到 `/vendor/etc/ngp/emulators/NetherSX2.apk`（不参与系统扫描）
- 首次开机由 `ngp-fixup.sh` 用 `pm install` 装进 `/data/app`
- 玩家可以在「设置 → 应用」里正常卸载
- **卸载后不会自己装回来**：首次装成功时在 `/data/ngp/emu-installed/<包名>`
  打标记，之后发现「没装但有标记」就跳过

想恢复内置模拟器：

```sh
rm /data/ngp/emu-installed/xyz.aethersx2.android   # 然后重启
```

> 为什么不用 `pm list packages -u` 判断「玩家卸载过」？实测本机卸载后
> 普通列表和 `-u` 列表都是空的，卸载记录根本不保留。

## 三、3DS 模拟器：不能卸载，但可以替换

内置的 3DS 前端 `com.gammaos.azaharsf` 动不了 —— 它是
`sharedUserId=android.uid.system` 的 system app，要写 `/data/system` 并发
`setprop sys.gammaos.azahar_nano.*` 才能把 ROM 交给 `azahar-nano` 进程。
重签就丢 system uid，从 `/system/app` 挪走同样丢，两条路都走不通。

玩家的替代方案：

1. **直接装官方的**（Azahar / Citra）。装完 LANGOS 的「选择模拟器」里就有两个，
   点哪个用哪个。
2. **想让内置的彻底消失**：

   ```sh
   mkdir -p /data/ngp && touch /data/ngp/disable-internal-3ds
   # 重启后自动 pm disable-user com.gammaos.azaharsf
   # 恢复：rm /data/ngp/disable-internal-3ds && pm enable com.gammaos.azaharsf
   ```

## 四、镜像

| 项 | 值 |
|---|---|
| 文件 | `GammaOSCore-NGP45HT-20261106-v39.img.xz` |
| 基线 | v38 |
| 改动分区 | 只有 p5 vendor |

p5 内的四处改动：

| 动作 | 路径 |
|---|---|
| 覆盖 | `/etc/ngp/LANGOS.apk` → 3.5-emupick |
| 覆盖 | `/bin/ngp-fixup.sh` → 含第 ⑫b 段 |
| 新增 | `/etc/ngp/emulators/NetherSX2.apk` |
| **删除** | `/app/NetherSX2/`（整个目录） |

## 五、验证

| 项 | 结果 |
|---|---|
| 4 MiB 分块比对 | 见构建日志，全部落在 p5 范围内、范围外 0 块 |
| p5 文件回读 | LANGOS / fixup / NetherSX2 三者 md5 与模板一致 |
| `/app/NetherSX2` | 已从 vendor 分区删除 |
| e2fsck | 干净 |
| LANGOS 弹窗实测 | 3DS `cand=1` 直启；`cand=2` 弹框，选中项正常启动 |
| 卸载标记实测 | 有标记 + 未装 → 跳过；删标记 → 装并重建标记 |

## 六、升级注意

- 只改 p5 vendor，**userdata 不动，存档和设置都在**
- 从 v38 升上来的机器：NetherSX2 会从 system app 换成 `/data/app` 的用户应用。
  首次开机 `ngp-fixup` 装好后，原来的 PS2 存档在 `/data/data/xyz.aethersx2.android`，
  **不受影响**（同包名，数据目录不变）
- LANGOS 由开机脚本 `pm install -r` 装入，首次开机等 10 秒左右
