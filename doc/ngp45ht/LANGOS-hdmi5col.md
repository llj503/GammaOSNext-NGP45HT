# LANGOS HDMI 大屏 5 列布局（3.3-hdmi5col）

## 现象
HDMI 输出到显示器时，LANGOS 首屏与游戏列表仍是 4 列，左右各留 240px 黑边，
卡片在大屏上又空又稀。内屏 1024×768 显示正常。

## 根因
RK3562 只有一个视频控制器（VOP0）。HDMI 接入时：

1. HWC 把 VOP0 让给 HDMI，输出 1920×1080
2. 内屏 DSI-1 被 `release`，`vendor.hwc.device.display-0` 变为 `DSI-1:71:disconnected`
3. SurfaceFlinger 仍以 `layerStack=0xFFFFFFFF`（`toInternalDisplay=true`）
   做镜像合成，源是 1024×768 的 Display 0
4. 该镜像等比塞进 1920×1080 → 1440×1080 居中 + 左右黑边（SF 侧行为，LANGOS 无法改变）

LANGOS 侧的原代码：

```kotlin
private fun getScreenRatio(): Float {
    val metrics = resources.displayMetrics
    return metrics.widthPixels.toFloat() / metrics.heightPixels.toFloat()
}

private fun getGameColumns(): Int =
    if (getScreenRatio() >= 1.7f) 5 else 4

private fun getHomeColumns(): Int {
    val ratio = getScreenRatio()   // 算了但没用
    return 4                       // 硬编码
}
```

`getDisplayMetrics()` 拿到的永远是**镜像源**尺寸 1024×768，ratio 恒为 1.333，
所以 `getGameColumns()` 永远 4；`getHomeColumns()` 更是直接写死 4。

## 修复
两处改动（`NativeActivity.smali`，dex: `classes3.dex`）：

1. `getScreenRatio()`：先扫 `DisplayManager.getDisplays()`，存在 `displayId != 0`
   的显示时直接返回 `1.7777778f`（16:9），否则回落原有 `w/h`。
2. `getHomeColumns()`：原 `const/4 v1, 0x4; return v1` 改为与 `getGameColumns()`
   同一判据（`ratio >= 1.7f` → 5，否则 4）。

判据实测日志（调试版）：

```
W NGP_RATIO: getDisplays count=2
W NGP_RATIO: found external display -> 16:9
```

HDMI 接入时 `dumpsys display` 里 HDMI 的 `mDisplayId=3`（不是 1），
所以判据用 `!= 0` 而不是 `== 1`。

## 结果
- 内屏 1024×768：4 列（ratio 1.333，未变）
- HDMI 1920×1080：5 列，历史/收藏/3DS/CPS1/CPS2 排满一行
- 左右 240px 黑边仍在（单 VOP 镜像架构决定，非 LANGOS 可控）

## 构建
```bash
# 反编译
java -jar apktool.jar d base.apk -o out     # classes3.dex 在 com.retrofront

# 改 smali 后汇编（注意 smali.jar 是坏的，用 asm.jar）
java -jar /tmp/smali/asm.jar assemble out/c3 -o classes3.dex

# 回填并重打包
cp classes3.dex d2/classes3.dex
java -jar apktool.jar b d2 -o raw.apk

# 对齐 + 签名（必须用项目密钥，否则覆盖安装失败）
zipalign -f -p 4 raw.apk al.apk
apksigner sign --ks apps/langos.jks --ks-pass pass:ngp45ht \
  --ks-key-alias langos --key-pass pass:ngp45ht --out LANGOS.apk al.apk
```

证书 SHA-256 必须为 `05689c30e666e0fbd2c9d187c5471409397261f84ac830577befcc749950b756`。

## 交付
- `device/ngp45ht/apps/LANGOS-3.3-hdmi5col.apk`
  3,867,268 B / md5 `f9403a88adcc88c882dd6a86056f9d34`
- `device/ngp45ht/apps/langos-patch/NativeActivity.smali`（改后完整 smali，供复现）
- `device/ngp45ht/apps/archive/LANGOS-3.2-pre-hdmi5col.apk`（改前备份）

## 注意
- LANGOS 是 HOME 应用，`am force-stop` 后会被立刻拉起；验证布局改动必须
  确认 PID 已变，否则看到的还是旧进程的界面。
- `getScreenRatio()` 只在 `onCreate` 走到（构造 GridLayoutManager 时），
  插拔 HDMI 后需要**重启 LANGOS**（或切走再切回）才重新计算列数。
