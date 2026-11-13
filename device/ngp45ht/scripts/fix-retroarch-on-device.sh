#!/usr/bin/env bash
# NGP45HT v43 / v43r2 刷机后缺 RetroArch —— 现场诊断 + 修复
# 用法：
#   bash fix-retroarch-on-device.sh          # 诊断并修复
#   bash fix-retroarch-on-device.sh --dry    # 只诊断，不改动设备
#
# 根因：v43 起 ngp-fixup.sh 在 boot_completed 后抢先写
#   device_provisioned / user_setup_complete = 1，
# LineageOS SetupWizard 判定已完成直接退出，
# persist.gammaos.setupwizard_run 永远是 0，
# init 里的 gammaossetupwizard 服务（跑 /system/bin/setup.sh）从不启动，
# /system/etc/gammaos/apps.list 的 7 个 app（含 RetroArch）一个都不装。
# 修复就是手动把 setup.sh 前台跑完；再用 OTA 包把首启脚本补齐，防止重现。
set -u
ADB=/home/liang/platform-tools/adb
PKGS="com.retroarch.aarch64 com.mixplorer com.aurora.store org.ppsspp.ppsspp com.dsemu.drastic com.flycast.emulator org.mupen64plusae.v3.fzurita"
DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

$ADB get-state >/dev/null 2>&1 || { echo "设备不在线：adb devices"; exit 1; }
echo "设备在线：$($ADB shell getprop ro.product.model | tr -d '\r')"

echo
echo "=== 1. 状态 ==="
$ADB shell '
echo -n "device_provisioned   = "; settings get global device_provisioned
echo -n "user_setup_complete  = "; settings get secure user_setup_complete
echo -n "setupwizard_run      = "; getprop persist.gammaos.setupwizard_run
echo -n "setupwizard_done     = "; getprop persist.gammaos.setupwizard_done
echo -n "setupwizard_exit_code= "; getprop persist.gammaos.setupwizard_exit_code
echo -n "svc gammaossetupwizard= "; getprop init.svc.gammaossetupwizard
echo -n "/data/setupcompleted = "; [ -e /data/setupcompleted ] && echo EXISTS || echo MISSING
echo -n "setup.sh             = "; [ -x /system/bin/setup.sh ] && echo EXEC || echo MISSING
echo -n "apps.list            = "; [ -r /system/etc/gammaos/apps.list ] && echo OK || echo MISSING
echo -n "setup.log            = "; ls -l /data/data/org.lineageos.setupwizard/files/gammaos_setup.log 2>/dev/null || echo NONE
' 2>&1

echo
echo "=== 2. apps.list 7 个包 ==="
for p in $PKGS; do
    printf '  %-42s ' "$p"
    $ADB shell "pm path $p" 2>/dev/null | grep -q '^package:' && echo PRESENT || echo MISSING
done

if [ "$DRY" = 1 ]; then
    echo
    echo "--dry：未改动设备"
    exit 0
fi

echo
echo "=== 3. 前台补跑 /system/bin/setup.sh ==="
echo "会安装 7 个 APK 并解 retroarch.tar.zst(357MB) / roms.tar.zst(175MB)，约 3~8 分钟。"
echo "过程中不要断电、不要拔卡。屏幕可能保持常亮（脚本自己 pin 了 timeout）。"
timeout 900 $ADB shell '/system/bin/sh /system/bin/setup.sh' >/dev/null 2>&1
echo "setup.sh 退出码：$? （脚本自身的日志在设备 /data/data/org.lineageos.setupwizard/files/gammaos_setup.log）"

echo
echo "=== 4. 验证 ==="
$ADB shell '
echo -n "/data/setupcompleted = "; [ -e /data/setupcompleted ] && echo EXISTS || echo MISSING
echo -n "setupwizard_done     = "; getprop persist.gammaos.setupwizard_done
' 2>&1
for p in $PKGS; do
    printf '  %-42s ' "$p"
    $ADB shell "pm path $p" 2>/dev/null | grep -q '^package:' && echo PRESENT || echo "** MISSING **"
done

echo
echo "=== 5. setup.log 末尾 ==="
$ADB shell 'tail -25 /data/data/org.lineageos.setupwizard/files/gammaos_setup.log' 2>&1

echo
echo "=== 6. 收尾 ==="
echo "a) 重启一次，让修好的 ngp-fixup.sh ⑧ 段给 RetroArch 补简体中文与字体："
echo "   $ADB reboot"
echo "b) 防止以后重现：把 v43r2-rafix-OTA.zip 解压，"
echo "   整个 update-20261113-rafix/ 拷到掌机 /sdcard/OTA/ 后重启。"
echo "   新脚本会在每次开机检测 /data/setupcompleted，缺就自动补跑 setup.sh。"
echo "c) 若 setup.log 里有 'zstd: not found' 或 'extracting ... failed'，"
echo "   是缺 zstd 解压器，APK 已装但核心/配置没铺 —— 把日志发回来再补。"
