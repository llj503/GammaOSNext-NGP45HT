#!/system/bin/sh
# ngp-hdmi-1080.sh — 强制 HDMI 独占 1920x1080，内屏让出视频端口
#
# 背景（RK3562 只有一个 VOP）
# ─────────────────────────────
# 本机 DSI 内屏和 RK628D HDMI 桥共用 Video Port0，任何时刻只能有一个分辨率。
# 只要 DSI 连接器是 connected，HWC 就按内屏的 1024x768 合成，HDMI 拿到的也是
# 1024x768 时序 —— 在 1080p 显示器上表现为「只显示左上角一部分」。
#
# 做法：把 DSI 的 DRM 连接器强制置为 disconnected，HWC 收到 hotplug 后
# 只剩 HDMI 一个输出，于是按 EDID 首选模式（1920x1080）重新协商 VOP。
# RK628 桥会自动跟随输入时序，实测 input/output 都是 1080p60 / 148.5MHz。
#
# 实测结果（2026-11-05）
# ─────────────────────
#   DRI:    Display mode 1920x1080p60  clk[148500]
#   RK628:  input  1920x1080p60  H-total 2199  V-total 1125
#           output 1920x1080p60  H: 1920 2008 2052 2200
#   合成:   src rect[1024x768] -> dst pos[240,0] rect[1440x1080]
#
# ⚠ 左右各留 240 像素黑边是**预期行为**：Android 仍按内屏 1024x768 合成，
#   再等比放大到 1440x1080 居中。这是单 VOP 架构的结果，不是 bug。
#
# ⚠ 不要用 `wm size 1920x1080` 试图消除黑边 —— 实测会触发配置变更把
#   system_server 打崩（service list 从 217 掉到 47），必须等它自己重启。
#
# 恢复内屏：ngp-hdmi-1080.sh internal

TAG=ngp-hdmi-1080
DSI=/sys/class/drm/card0-DSI-1/status

case "$1" in
external)
    # 拔线或没接显示器：把内屏要回来（可能上次已经被切成 off 了）。
    if [ "$(cat /sys/class/drm/card0-HDMI-A-1/status)" != "connected" ]; then
        if [ "$(cat $DSI 2>/dev/null)" != "connected" ]; then
            echo detect > "$DSI" 2>/dev/null
            log -t $TAG "no HDMI, restored internal panel"
        else
            log -t $TAG "no HDMI, internal already on"
        fi
        exit 0
    fi

    # 已经是 1080p 就别再折腾，避免每次属性变化都闪一下屏。
    cur=$(sed -n 's/.*Display mode: *//p' /sys/kernel/debug/dri/0/summary 2>/dev/null | head -1)
    case "$cur" in
    1920x1080*)
        [ "$(cat $DSI 2>/dev/null)" = "off" ] && exit 0
        ;;
    esac

    echo off > "$DSI" 2>/dev/null || {
        log -t $TAG "cannot write $DSI"
        exit 1
    }
    sleep 2
    #
    # 关键：切完之后**不要把 DSI 设回 detect**。
    # 实测 detect 会让连接器回到 connected，但 VOP 仍停在 1080p ——
    # 看似更好，实际上 HWC 下一轮 hotplug 会重新按内屏尺寸抢回端口。
    # 保持 off 才能让 1080p 稳定。
    #
    mode=$(sed -n 's/.*Display mode: *\([0-9x]*p[0-9]*\).*/\1/p' \
           /sys/kernel/debug/dri/0/summary 2>/dev/null | head -1)
    log -t $TAG "switched to external, mode=$mode"
    ;;

internal)
    echo detect > "$DSI" 2>/dev/null
    log -t $TAG "restored internal panel"
    ;;

status)
    echo "DSI status : $(cat $DSI 2>/dev/null)"
    echo "HDMI status: $(cat /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null)"
    echo "VOP mode   : $(sed -n 's/.*Display mode: *//p' /sys/kernel/debug/dri/0/summary 2>/dev/null | head -1)"
    echo "RK628      : $(sed -n 's/.*Display mode: *//p' /sys/kernel/debug/rk628/3-0050/summary 2>/dev/null | head -1)"
    echo "display-0  : $(getprop vendor.hwc.device.display-0)"
    echo "display-1  : $(getprop vendor.hwc.device.display-1)"
    ;;

*)
    echo "usage: $0 {external|internal|status}" >&2
    exit 2
    ;;
esac
