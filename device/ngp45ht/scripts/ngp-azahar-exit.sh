#!/system/bin/sh
# NGP45HT: 3DS 退出后的显示兜底。
#
# 正常路径实测是好的：从 LANGOS 启动 3DS（from_app=1），AzaharSf 监测到
# session 消失后自己 finish()，LANGOS 被拉回前台，焦点回到
# com.retrofront/com.retrofront.NativeActivity，画面正常。
#
# 但有两种情况会停在黑屏：
#   1) 内存吃紧时 LANGOS 被 LMK 杀掉，AzaharSf finish 后没有可回的 activity，
#      SurfaceFlinger 一个图层都没有，合成不出帧；
#   2) 别的应用（RetroArch 之类）在 3DS 前后崩溃，窗口栈被清空，但焦点窗口的
#      Window 对象还挂在 ActivityManager 里 —— 表面上看有焦点，实际那个进程
#      早没了，屏幕停在最后一帧黑。
#
# 判据：读 mCurrentFocus 里的包名，进程已经不在（或者干脆没有焦点）就拉起
# LANGOS。进程还活着就完全不动，避免打断用户正在用的应用。
# 不直接看 SurfaceFlinger 图层数：dumpsys SurfaceFlinger 超时也会返回空，
# 那样会被误判成"黑屏"。

TAG=ngp-azahar-exit
LANGOS_PKG=com.retrofront
LANGOS_ACT=com.retrofront/.NativeActivity

# 等 AzaharSf finish + 窗口切换落定
sleep 2

FOCUS=$(timeout 6 dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
if [ -z "$FOCUS" ]; then
    log -t $TAG "dumpsys window gave nothing, skip"
    exit 0
fi

case "$FOCUS" in
    *mCurrentFocus=null*)
        log -t $TAG "no focused window after 3DS exit, raising LANGOS"
        ;;
    *)
        PKG=$(echo "$FOCUS" | sed -n 's/.*u0[[:space:]]\{1,\}\([A-Za-z0-9._]*\)\/.*/\1/p')
        if [ -n "$PKG" ] && pidof "$PKG" >/dev/null 2>&1; then
            log -t $TAG "ok: $PKG alive, nothing to do"
            exit 0
        fi
        log -t $TAG "focused pkg '$PKG' is gone, raising LANGOS"
        ;;
esac

am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
       -n "$LANGOS_ACT" >/dev/null 2>&1
