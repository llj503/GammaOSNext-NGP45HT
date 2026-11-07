#!/system/bin/sh
# NGP45HT V38: HDMI / 内屏输出仲裁（单 VOP + RK628 桥）
#
# 实测背景（2026-11-05）：
#   * RK3562 只有一个 VOP。HDMI 接上时 HWC 把 VOP0 给 HDMI 出 1920x1080，
#     内屏 DSI 被 release；App 窗口仍在 display 0（默认 1024x768）。
#   * 在 HDMI 已经拿走 VOP 后执行 `wm size`，display 0 没有 surface，
#     WindowManager 会卡住并触发 system_server watchdog（"Can't find
#     service: window"）。所以运行时不要自动来回切。
#   * HWC 还有 "compete" 状态：DSI+HDMI 同挂 vp0，内屏被喂 1080p → 黑屏。
#
# 策略：
#   boot  —— 开机只做一次：HDMI 连接则 wm size 1366x768（LANGOS 16:9）；
#            否则 wm size reset。不做 off/on 切换。
#   watch —— 常驻，处理三个方向：
#            disconnected -> connected：走 do_hdmi 的安全切换，把逻辑尺寸
#            改成 1366x768（16:9），电视铺满；
#            connected -> disconnected：等 HWC 把 VOP 还给 DSI 后 wm size reset。
#            连接时不能裸调 wm size（HDMI 已占 VOP 会触发 WindowManager
#            watchdog），所以必须复用 do_hdmi 的 off/等内屏/on/detect 流程；
#            connected 但 VOP 被 HWC 抢回内屏：熄屏唤醒后 HWC 会自己把 VOP
#            还给 DSI（HPD 状态不变），只靠连接边沿发现不了，需要按 VOP 归属
#            复查并重做 do_hdmi。
#   hdmi  —— 手动：安全地把输出切到 HDMI（off -> 等内屏 -> wm size ->
#            on/detect -> 确认 HDMI 独占 VOP）。会闪一下电视。
#   panel —— 手动：强制回内屏（off -> 等内屏 -> wm size reset）。
#            机身返回键在桌面长按会触发这个（见 ngp-navkey.sh）。
#
# 3DS 为什么不用 SF 后端：实测 SF 后端只把 AzaharSf 的 Activity 层镜像到
# HDMI，azahar-nano 的游戏层（bbq-wrapper）不会进 HDMI 的 HWC layer 表，
# 电视停在 loading。DRM 直出虽然把 VOP 固定在 1024x768，但游戏画面能到
# 电视；电视端把画面比例设成 4:3/原始，就不会拉伸。azahar 后端保持 drm。

TAG=ngp-hdmi-ratio
MODE=1366x768
C=/sys/class/drm/card0-HDMI-A-1/status
AZB=persist.gammaos.azahar_nano.backend

log_msg() { log -t $TAG "$*"; }
hdmi_state() { cat "$C" 2>/dev/null; }
panel_state() { getprop vendor.hwc.device.display-0; }
hdmi_hwc() { getprop vendor.hwc.device.display-1; }
panel_on() {
    case "$(panel_state)" in
        *:connected*|*:compete) return 0 ;;
    esac
    return 1
}
cur_override() { wm size 2>/dev/null | sed -n 's/.*Override size: *//p'; }
vop_conns() {
    sed -n '/^Video Port0/,/^Video Port1/p' /sys/kernel/debug/dri/0/summary 2>/dev/null \
        | sed -n 's/.*Connector:\([^[:space:]]*\).*/\1/p' | tr '\n' ' '
}
vop_only_hdmi() { [ "$(vop_conns)" = "HDMI-A-1 " ]; }
vop_win_active() {
    sed -n '/^Video Port0/,/^Video Port1/p' /sys/kernel/debug/dri/0/summary 2>/dev/null \
        | grep -q 'win[0-9]*: ACTIVE'
}
vop_mode() { sed -n 's/.*Display mode: *//p' /sys/kernel/debug/dri/0/summary 2>/dev/null | head -1; }

# LANGOS 的列数在 Activity 创建时算好（getScreenRatio），wm size 改变后
# 不会自己重算：从 1366 切回 1024 会留下 5 列的旧布局（卡片变窄、文字
# 截断，看起来就是"错位"）。尺寸变化后无条件重启一次 LANGOS；这些操作
# 本来就是用户主动切显示，回桌面是预期行为。
restart_langos() {
    if pidof com.retrofront >/dev/null 2>&1; then
        log_msg "restarting LANGOS to recompute columns"
        am force-stop com.retrofront
        sleep 1
        am start -n com.retrofront/com.retrofront.NativeActivity >/dev/null 2>&1
    fi
}

wait_panel() {
    n=0
    while [ $n -lt 20 ]; do
        panel_on && return 0
        sleep 0.5
        n=$((n + 1))
    done
    log_msg "internal panel not bound, sleep/wake"
    echo "ngp_hdmi_ratio 10000000000" > /sys/power/wake_lock
    input keyevent KEYCODE_SLEEP 2>/dev/null
    sleep 1
    input keyevent KEYCODE_WAKEUP 2>/dev/null
    sleep 3
    echo ngp_hdmi_ratio > /sys/power/wake_unlock
    panel_on
}

# 开机一次性对齐：HDMI 此时已经由 HWC 接好，只改逻辑尺寸/后端；
# 如果 HWC 把 DSI+HDMI 同时挂在 vp0（compete，内屏被喂 1080p），
# 再用一次安全切换把 HDMI 单独接回来。
do_boot() {
    if [ "$(hdmi_state)" = "connected" ]; then
        if [ "$(cur_override)" != "$MODE" ]; then
            log_msg "boot HDMI -> wm size $MODE"
            wm size "$MODE"
            restart_langos
        fi
        setprop $AZB drm
        log_msg "boot HDMI: vop=$(vop_conns) mode=$(vop_mode) azahar=drm"
    else
        if [ -n "$(cur_override)" ]; then
            log_msg "boot panel -> wm size reset"
            wm size reset
            restart_langos
        fi
        setprop $AZB drm
        log_msg "boot panel: vop=$(vop_conns) mode=$(vop_mode) azahar=drm"
    fi
}

# 手动切 HDMI：需要先让内屏活着，改完尺寸再让 HWC 绑 HDMI
do_hdmi() {
    [ "$(hdmi_state)" = "connected" ] || { log_msg "no HDMI"; return 1; }
    echo off > "$C"
    wait_panel || { log_msg "no internal panel, abort"; return 1; }
    if [ "$(cur_override)" != "$MODE" ]; then
        log_msg "panel alive -> wm size $MODE"
        wm size "$MODE"
        sleep 1
        restart_langos
    fi
    setprop $AZB drm
    echo on > "$C"
    sleep 1
    echo detect > "$C"
    n=0
    while [ $n -lt 16 ]; do
        if vop_only_hdmi; then
            log_msg "HDMI owns VOP0: $(vop_mode)"
            return 0
        fi
        sleep 0.5
        n=$((n + 1))
    done
    log_msg "HDMI did not own VOP (connectors: $(vop_conns))"
    return 1
}

do_panel() {
    echo off > "$C"
    wait_panel || true
    if [ -n "$(cur_override)" ]; then
        log_msg "panel -> wm size reset"
        wm size reset
        restart_langos
    fi
    setprop $AZB drm
    log_msg "panel: vop=$(vop_conns) mode=$(vop_mode) azahar=drm"
}

# 3DS DRM 退出后 VOP 停在 1024x768，而 wm size 仍是 1366x768；
# LANGOS 的 1366 合成结果被 1024 扫描，电视上图标会显得很大/被裁。
# 只做一次轻量 off/on/detect，把 HDMI 重新绑回 1920x1080，不动 wm size。
do_restore() {
    if [ "$(hdmi_state)" != "connected" ]; then
        do_panel
        return 0
    fi
    case "$(vop_mode)" in
        *1920x1080*) return 0 ;;
    esac
    log_msg "restore HDMI mode (was: $(vop_conns) $(vop_mode))"
    echo off > "$C"
    sleep 2
    echo on > "$C"
    sleep 2
    echo detect > "$C"
    n=0
    while [ $n -lt 16 ]; do
        case "$(vop_mode)" in
            *1920x1080*)
                log_msg "HDMI mode restored: $(vop_mode)"
                return 0
                ;;
        esac
        sleep 0.5
        n=$((n + 1))
    done
    log_msg "restore failed (connectors: $(vop_conns), mode: $(vop_mode))"
    return 1
}

# HDMI 断开后的复位必须走完整的 do_panel：先 off HDMI、等/唤醒内屏，
# 再 wm size reset。实测只做裸的 wm size reset 会让 HWC 把 DSI 也解绑
# （display-0 disconnected、VOP DISABLED），需要 sleep/wake 才能恢复。
do_watch() {
    # 服务在 boot_completed 启动：如果此时 HDMI 已拔、但上次会话留下
    # 了 1366x768 override，立即修正一次。必须等内屏已 bound，避免在
    # HPD 误报断开、HDMI 仍占着 VOP 时把电视关掉。
    if [ "$(hdmi_state)" != "connected" ] && [ -n "$(cur_override)" ] && panel_on; then
        if [ "$(getprop init.svc.azahar-nano)" = "running" ]; then
            log_msg "azahar running at watch start; defer reset"
        else
            do_panel
        fi
    fi

    # 等 boot 服务完成，避免和 do_boot 同时改尺寸。
    n=0
    while [ "$(getprop init.svc.ngp_hdmi_boot)" = "running" ] && [ $n -lt 20 ]; do
        sleep 0.5
        n=$((n + 1))
    done
    # 开机后、watch 启动前 HDMI 才插上：补一次 16:9 安全切换。
    if [ "$(hdmi_state)" = "connected" ] && [ "$(cur_override)" != "$MODE" ]; then
        log_msg "HDMI connected at watch start, apply $MODE"
        do_hdmi
    fi

    last=$(hdmi_state)
    bad=0
    last_try=0
    while true; do
        sleep 2
        cur=$(hdmi_state)
        if [ "$last" != "connected" ] && [ "$cur" = "connected" ]; then
            log_msg "HDMI connected (was $last)"
            do_hdmi
            bad=0
        elif [ "$last" = "connected" ] && [ "$cur" != "connected" ]; then
            log_msg "HDMI disconnected (was connected)"
            n=0
            while [ $n -lt 10 ]; do
                panel_on && break
                sleep 0.5
                n=$((n + 1))
            done
            if ! panel_on; then
                log_msg "panel not bound after unplug; skip (manual panel fallback)"
            elif [ "$(getprop init.svc.azahar-nano)" = "running" ]; then
                # 3DS 会话结束后 ngp-azahar-exit.sh 会调 restore，
                # 由它统一回内屏 + wm size reset，避免打断游戏。
                log_msg "azahar running; defer reset to azahar-exit restore"
            else
                do_panel
            fi
            bad=0
        elif [ "$cur" = "connected" ] \
            && [ "$(getprop sys.screen.state)" = "on" ] \
            && [ "$(getprop init.svc.azahar-nano)" != "running" ] \
            && { [ "$(cur_override)" != "$MODE" ] || ! vop_only_hdmi || ! vop_win_active; }; then
            # 3DS DRM 后端会故意把 VOP 固定在 1024x768，不能抢回来。
            bad=$((bad + 1))
            if [ $bad -ge 2 ]; then
                now=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
                if [ $((now - last_try)) -ge 15 ]; then
                    log_msg "HDMI connected but vop=$(vop_conns)$(vop_mode) override=$(cur_override), re-apply"
                    last_try=$now
                    do_hdmi
                    bad=0
                fi
            fi
        else
            bad=0
        fi
        last=$cur
    done
}

case "$1" in
    boot)    do_boot ;;
    hdmi)    do_hdmi ;;
    panel)   do_panel ;;
    restore) do_restore ;;
    watch)   do_watch ;;
    status)
        echo "hdmi:      $(hdmi_state)"
        echo "display-0: $(panel_state)"
        echo "display-1: $(hdmi_hwc)"
        echo "physical:  $(wm size 2>/dev/null | sed -n 's/Physical size: *//p')"
        echo "override:  $(cur_override)"
        echo "vop:       $(vop_conns)"
        echo "mode:      $(vop_mode)"
        echo "azahar:    $(getprop $AZB)"
        ;;
    *)
        echo "usage: $0 {boot|hdmi|panel|restore|watch|status}"
        exit 1
        ;;
esac
