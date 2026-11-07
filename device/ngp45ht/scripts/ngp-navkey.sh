#!/system/bin/sh
# NGP45HT: 机身 M 键 / 返回键的多击与长按守护
#
# 键位表（2026-11-07 定版）：
#   M 键      单击 -> HOME        双击 -> 无动作    长按 -> MENU
#   返回键    单击 -> BACK        双击 -> 无动作    长按 -> 终止前台应用
#
# 为什么需要这个脚本：
#   adc-keys 驱动只报按下/松开（M=KEY_MUTE 113，返回=KEY_ESC 1），不认识
#   单击/双击/长按。keylayout 把这两个键改成了 UNKNOWN，Android 不会自己
#   发 HOME/BACK；所有动作都由这里计时后合成。
#
# 计时：
#   单击要等双击窗口（300ms）过去才能发，否则双击的第一下会先触发单击。
#   长按在松开时判定：M >= 600ms，返回 >= 1500ms（返回键会杀应用，留长一点）。
#
# 实现要点：
#   - getevent 是 FIFO 的唯一写者；主循环用 read -t 0.1 轮询，
#     到点检查 deadline 再发单击。不要用后台 sleep 往 FIFO 写超时消息：
#     多写者会把 getevent 的行切碎，实测会偶发丢 UP 事件/长按不触发。
#   - /proc/uptime 的秒字段是两位小数，去掉小数点就是厘秒；
#     不要再截掉最后两位（那会变成整秒，长按阈值永远到不了）。
#
# 依赖：
#   adc-keys-ngp（机身侧键）。不硬编码 event 号，按设备名查找。
#   该节点不会被 gammapad re-hid，找到后很稳。

DEV_NAME=adc-keys-ngp
HOME_ACT=com.retrofront/com.retrofront.NativeActivity
TAG=ngp-navkey
M_LONG=60          # centiseconds = 600ms
B_LONG=150         # centiseconds = 1500ms
DOUBLE_CS=30       # 300ms double-click window
POLL_S=0.1
FIFO=/data/local/tmp/ngp-navkey.fifo

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

now_cs() {
    _t=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
    printf '%s' "$_t"
}

reset_state() {
    DOWN_M=0; DOWN_B=0
    PENDING_M=0; PENDING_B=0
    DEADLINE_M=0; DEADLINE_B=0
    DOUBLE_M=0; DOUBLE_B=0
}

do_single() {
    log -t $TAG "single $1"
    case "$1" in
    m) input keyevent KEYCODE_HOME >/dev/null 2>&1 ;;
    b) input keyevent KEYCODE_BACK >/dev/null 2>&1 ;;
    esac
}

do_long() {
    case "$1" in
    m)
        log -t $TAG "long M -> MENU"
        input keyevent KEYCODE_MENU >/dev/null 2>&1
        ;;
    b)
        fg=$(getprop sys.gammaos.gamepad.fg_pkg)
        case "$fg" in
        ""|com.retrofront|android)
            log -t $TAG "long Back in launcher ($fg), ignored"
            ;;
        *)
            log -t $TAG "long Back -> force-stop $fg"
            am force-stop "$fg"
            sleep 1
            am start -n "$HOME_ACT" >/dev/null 2>&1
            ;;
        esac
        ;;
    esac
}

check_deadlines() {
    [ "$PENDING_M" -eq 0 ] && [ "$PENDING_B" -eq 0 ] && return
    _now=$(now_cs)
    if [ "$PENDING_M" -eq 1 ] && [ "$_now" -ge "$DEADLINE_M" ]; then
        PENDING_M=0
        DEADLINE_M=0
        do_single m
    fi
    if [ "$PENDING_B" -eq 1 ] && [ "$_now" -ge "$DEADLINE_B" ]; then
        PENDING_B=0
        DEADLINE_B=0
        do_single b
    fi
}

handle_down() {
    check_deadlines
    case "$1" in
    m)
        [ "$DOWN_M" -ne 0 ] && return
        DOWN_M=$(now_cs)
        log -t $TAG "down m at $DOWN_M"
        if [ "$PENDING_M" -eq 1 ]; then
            PENDING_M=0
            DEADLINE_M=0
            DOUBLE_M=1
        else
            DOUBLE_M=0
        fi
        ;;
    b)
        [ "$DOWN_B" -ne 0 ] && return
        DOWN_B=$(now_cs)
        log -t $TAG "down b at $DOWN_B"
        if [ "$PENDING_B" -eq 1 ]; then
            PENDING_B=0
            DEADLINE_B=0
            DOUBLE_B=1
        else
            DOUBLE_B=0
        fi
        ;;
    esac
}

handle_up() {
    check_deadlines
    case "$1" in
    m)
        [ "$DOWN_M" -eq 0 ] && return
        _now=$(now_cs)
        _held=$((_now - DOWN_M))
        DOWN_M=0
        log -t $TAG "up m held=$_held double=$DOUBLE_M"
        if [ "$DOUBLE_M" -eq 1 ]; then
            DOUBLE_M=0
            [ "$_held" -ge "$M_LONG" ] && do_long m
        elif [ "$_held" -ge "$M_LONG" ]; then
            do_long m
        else
            PENDING_M=1
            DEADLINE_M=$((_now + DOUBLE_CS))
        fi
        ;;
    b)
        [ "$DOWN_B" -eq 0 ] && return
        _now=$(now_cs)
        _held=$((_now - DOWN_B))
        DOWN_B=0
        log -t $TAG "up b held=$_held double=$DOUBLE_B"
        if [ "$DOUBLE_B" -eq 1 ]; then
            DOUBLE_B=0
            [ "$_held" -ge "$B_LONG" ] && do_long b
        elif [ "$_held" -ge "$B_LONG" ]; then
            do_long b
        else
            PENDING_B=1
            DEADLINE_B=$((_now + DOUBLE_CS))
        fi
        ;;
    esac
}

DEV=$(find_dev)
if [ -n "$DEV" ]; then
    log -t $TAG "side-key daemon started (dev=$DEV, M_long=${M_LONG}0ms, Back_long=${B_LONG}0ms)"
else
    log -t $TAG "side-key daemon started, $DEV_NAME not found yet (will retry)"
fi

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

while true; do
    DEV=$(find_dev)
    if [ -z "$DEV" ]; then
        log -t $TAG "$DEV_NAME gone, waiting"
        sleep 3
        continue
    fi

    reset_state
    rm -f "$FIFO"
    mkfifo "$FIFO" 2>/dev/null || { log -t $TAG "mkfifo failed"; sleep 3; continue; }

    getevent -l "$DEV" > "$FIFO" 2>/dev/null &
    GE_PID=$!

    # 一个不发数据的常驻写者，保证主循环每次 read 打开 FIFO 时不会因为
    # 短暂没有写者而阻塞在 open() 上；getevent 死掉后仍能靠 kill -0 发现。
    sleep 3600 > "$FIFO" &
    DUMMY_PID=$!

    while true; do
        if IFS= read -r -t "$POLL_S" line < "$FIFO"; then
            case "$line" in
            *KEY_MUTE*DOWN*) handle_down m ;;
            *KEY_MUTE*UP*)   handle_up m ;;
            *KEY_ESC*DOWN*)  handle_down b ;;
            *KEY_ESC*UP*)    handle_up b ;;
            esac
        fi
        check_deadlines
        kill -0 "$GE_PID" 2>/dev/null || break
    done

    kill "$GE_PID" "$DUMMY_PID" 2>/dev/null
    wait "$GE_PID" 2>/dev/null
    wait "$DUMMY_PID" 2>/dev/null
    rm -f "$FIFO"

    log -t $TAG "getevent exited on $DEV, reconnecting"
    sleep 2
done
