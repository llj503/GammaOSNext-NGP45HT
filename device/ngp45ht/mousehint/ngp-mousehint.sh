#!/system/bin/sh
# 鼠标模式切换提示：在屏幕底部弹一个 Toast，不闪屏。
#
# 常驻监听 sys.gammaos.gamepad.mouse_active。gammapad 的
# GammapadVibrationBridge 在这台 GSI 上没有启动（gammapad_vibrate
# socket 不存在），所以 gammapad 自己的 toast 发不出来；RG52 原来的
# rg52-mouseflash.sh 用整屏颜色反转当提示，看起来就是屏幕闪。
# persist.rg52.mouse_flash=0 关掉它，由这里补一个真正的 Toast。
#
# app_process 以 root 启动，ToastMain 先用 ActivityThread.systemMain()
# 建 system context，再降到 uid 1000 再 enqueueToast —— 包 android 的 uid
# 正好是 1000，NotificationManager 的 package/uid 检查才放行。
#
# 用常驻循环而不是 init 的 property trigger + oneshot：实测 property
# trigger 在启动早期会撞上“service already running”，后一次切换直接丢；
# 常驻循环还能在 Toast 显示期间继续记录状态，不会漏掉快速开/关。

TAG=ngp-mousehint
JAR=/vendor/etc/ngp/ngp-toast.jar

LAST=$(getprop sys.gammaos.gamepad.mouse_active)
[ -n "$LAST" ] || LAST=0

while true; do
    CUR=$(getprop sys.gammaos.gamepad.mouse_active)
    [ -n "$CUR" ] || CUR=0
    if [ "$CUR" != "$LAST" ]; then
        LAST=$CUR
        # gammapad 的 GammapadVibrationBridge 在的话，它自己会发
        # "Mouse mode ON/OFF"；不要重复弹。桥不在（某些冷启动/GSI 上）
        # 才由这里补中文 Toast。
        if grep -q gammapad_vibrate /proc/net/unix 2>/dev/null; then
            log -t $TAG "bridge present, gammapad toast handles $CUR"
        else
            case "$CUR" in
            1) TEXT="鼠标模式：开" ;;
            *) TEXT="鼠标模式：关" ;;
            esac
            log -t $TAG "toast $CUR"
            CLASSPATH="$JAR" /system/bin/app_process /system/bin com.ngp.ToastMain "$TEXT" >/dev/null 2>&1
        fi
    fi
    sleep 0.5
done
