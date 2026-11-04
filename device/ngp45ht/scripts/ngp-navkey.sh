#!/system/bin/sh
# NGP45HT: 机身返回键「短按 BACK / 长按退出游戏」守护
#
# 为什么需要它：
#   adc-keys 驱动只做一件事 —— 在 ADC 读数跨过阈值时报按下、回落时报松开
#   （KEY_ESC 1）。它不认识"长按"这个概念，内核也不会替你做计时。
#   所以"长按 1.5 秒退出当前游戏"只能在 userspace 用一个 getevent 监听 +
#   自己数时间来补。
#
# 行为：
#   短按（< HOLD_MS） -> 什么都不做（BACK 事件本身已经由 keylayout 正常发出，
#                        本脚本只读不写，绝不吞掉模拟器的返回操作）
#   长按（>= HOLD_MS）-> force-stop 当前前台游戏，然后回 LANGOS 主界面
#
# 判定"当前前台是不是游戏"：
#   优先用 gammapad 维护的 sys.gammaos.gamepad.fg_pkg（ngp-ps2hotkey.sh 同款）；
#   这个属性为空或等于桌面自身时，长按才回桌面。这样在 LANGOS 里长按返回键
#   不会莫名其妙 force-stop 桌面。
#
# 依赖：
#   adc-keys-ngp（机身侧键：返回 / M / 音量）。
#   **不硬编码 event 号** —— event 号取决于设备枚举顺序，换内核/换 DTB/
#   插拔 USB 都可能变。按 /sys/class/input/event*/device/name 找名字。
#   这个节点不像物理手柄那样会被 gammapad re-hid 掉，所以找到之后很稳。

DEV_NAME=adc-keys-ngp
HOME_ACT=com.retrofront/com.retrofront.NativeActivity
TAG=ngp-navkey
HOLD_MS=1500

find_dev() {
    for d in /sys/class/input/event*; do
        [ -r "$d/device/name" ] || continue
        if [ "$(cat "$d/device/name" 2>/dev/null)" = "$DEV_NAME" ]; then
            echo "/dev/input/$(basename "$d")"
            return 0
        fi
    done
    return 1
}

DEV=$(find_dev)
if [ -n "$DEV" ]; then
    log -t $TAG "navkey daemon started (dev=$DEV, hold=${HOLD_MS}ms)"
else
    log -t $TAG "navkey daemon started, $DEV_NAME not found yet (will retry)"
fi

# 等设备就绪（adc-keys 正常早就注册好了，这里主要是兜底）
i=0
while [ -z "$DEV" ]; do
    sleep 1
    i=$((i + 1))
    DEV=$(find_dev)
    if [ "$i" -gt 60 ]; then
        log -t $TAG "gave up waiting for $DEV_NAME"
        exit 0
    fi
done
log -t $TAG "using $DEV"

# 外层循环：getevent 万一因为节点消失而退出（比如 USB 重枚举导致
# /dev/input 重新排列），重新找设备再接上，而不是默默死掉。
while true; do
    DEV=$(find_dev)
    if [ -z "$DEV" ]; then
        log -t $TAG "$DEV_NAME gone, waiting"
        sleep 3
        continue
    fi

    # getevent -l 的输出形如：
    #   /dev/input/event2: EV_KEY       KEY_ESC          DOWN
    #   /dev/input/event2: EV_KEY       KEY_ESC          UP
    # 我们只关心 KEY_ESC 的 DOWN/UP 配对，并在 DOWN 时记下 uptime，
    # 在 UP 时算差值决定是不是长按。
    #
    # ⚠ 这里必须用 FIFO，不能用 `exec 3< <(getevent ...)`：
    #   Android 的 /system/bin/sh（toybox）**不支持进程替换**，实测报
    #       sh: syntax error: unexpected '< '
    #   之前这版脚本因此在设备上根本起不来（服务 running 但立即退出）。
    # 也不能用 `getevent | while read`：管道右侧是子 shell，
    # press_ms 的赋值带不出来，长按永远算成 0ms。
    # FIFO + 后台 getevent 是唯一两头都满足的写法。
    FIFO=/data/local/tmp/ngp-navkey.fifo
    rm -f "$FIFO"
    mkfifo "$FIFO" 2>/dev/null || { log -t $TAG "mkfifo failed"; sleep 3; continue; }

    getevent -l "$DEV" > "$FIFO" 2>/dev/null &
    GE_PID=$!

    press_ms=0
    while IFS= read -r line < "$FIFO"; do
        case "$line" in
            *KEY_ESC*DOWN*)
                now=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
                now=${now%??}
                press_ms=$now
                ;;
            *KEY_ESC*UP*)
                if [ "$press_ms" != "0" ]; then
                    now=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
                    now=${now%??}
                    held=$(( (now - press_ms) * 100 ))
                    press_ms=0
                    if [ "$held" -ge "$HOLD_MS" ]; then
                        fg=$(getprop sys.gammaos.gamepad.fg_pkg)
                        case "$fg" in
                            ""|com.retrofront|android)
                                log -t $TAG "long-press ${held}ms in launcher ($fg), ignored"
                                ;;
                            *)
                                log -t $TAG "long-press ${held}ms -> exiting $fg"
                                am force-stop "$fg"
                                sleep 1
                                am start -n "$HOME_ACT" >/dev/null 2>&1
                                log -t $TAG "returned to launcher"
                                ;;
                        esac
                    fi
                fi
                ;;
        esac
    done

    kill "$GE_PID" 2>/dev/null
    wait "$GE_PID" 2>/dev/null
    rm -f "$FIFO"

    log -t $TAG "getevent exited on $DEV, reconnecting"
    sleep 2
done
