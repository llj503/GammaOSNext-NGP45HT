#!/system/bin/sh
# 摇杆灯（WS2812 on SPI0）—— 接管「设置 → 掌机设置 → joystick led」。
#
# ═══ 为什么需要这个脚本 ═══
#
# 上游 mamaich 的 RG52Mini 用 /system/bin/rg52-ledd 驱动摇杆灯，但那个
# 程序写死了 RG52Mini 的接线：串口 UART1。本机 NGP45HT 的灯带挂在 SPI0，
# 开机日志里它自己就放弃了：
#
#     rg52-ledd: no /dev/ttyS1: UART1 is not enabled in the device tree,
#                LEDs unavailable
#
# 于是设置界面（com.gammaos.joystickled）无论怎么调，值只是被写进
# persist 属性，没有任何人去读 —— 这就是「调节无效」的根因。
# rg52-ledd 现在只剩一个空壳在跑，本脚本负责把它不干的活接过来。
#
# ═══ 属性来源（设置界面写的，不能改名字）═══
#
#   persist.gammaos.rgb.enable        0/1    总开关
#   persist.gammaos.rgb.effect        none|effect1|effect2|effect3
#   persist.gammaos.primary.rgb_hex   #RRGGBB  当前生效色
#   persist.gammaos.primary.rgb_hex_custom   用户自定义色
#   persist.gammaos.primary.rgb_hex_follow   跟随色
#   persist.gammaos.rgb.fade.enable   呼吸
#   persist.gammaos.rgb.color_split   两圈不同色
#   persist.gammaos.rgb.fps           动画帧率
#
# 早期版本这里用的是自造的 persist.gammaos.stickled.* 命名空间，
# 和设置界面写的对不上，等于永远读不到用户的选择。已废弃。
#
# ═══ 灯珠数量 ═══
#
# 两个摇杆圈各 8 颗 = 16，另有左上角长条（数量待确认）。
# SPI 是 daisy-chain，一条链上所有灯珠一起发；多发几颗没影响，
# 少发会导致后面的灯不出色。默认 16，可用 persist 覆盖。
#
# 用法：ngp-stickled.sh {watch|apply|off|status}
#   watch  常驻，监听属性变化并实时刷新（服务用这个）
#   apply  按当前属性推一帧就退出（开机兜底）
TAG=ngp-stickled
DEV=/dev/spidev0.0
BIN=/vendor/bin/ws2812-common

LEDS=$(getprop persist.gammaos.stickled.leds)
[ -n "$LEDS" ] || LEDS=16

if [ ! -e "$DEV" ]; then
    log -t $TAG "no $DEV: SPI0 is not enabled in the device tree"
    exit 0
fi
if [ ! -x "$BIN" ]; then
    log -t $TAG "missing $BIN"
    exit 0
fi

# 属性变化触发重刷的指纹。只有这些变了才重新推帧，
# 免得每轮都刷 SPI（参数没变时 SPI 有传输计数可查，便于排障）。
fingerprint() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s' \
        "$(getprop persist.gammaos.rgb.enable)" \
        "$(getprop persist.gammaos.rgb.effect)" \
        "$(getprop persist.gammaos.primary.rgb_hex)" \
        "$(getprop persist.gammaos.primary.rgb_hex_custom)" \
        "$(getprop persist.gammaos.rgb.fade.enable)" \
        "$(getprop persist.gammaos.rgb.color_split)" \
        "$(getprop persist.gammaos.rgb.led_brightness)" \
        "$(getprop persist.gammaos.rgb.fps)"
}

# 去掉 # 前缀，并校验是 6 位十六进制。属性值带 '#'（#9D1200），
# 直接喂给 ws2812-common 会被 strtoul 解析成 0 → 灯变黑。
sanitize_color() {
    _c="$1"
    _c=${_c#\#}
    case "$_c" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
        printf '%s' "$_c" ;;
    *)
        printf '%s' "" ;;
    esac
}

# 按百分比缩放 RGB。纯 shell 没有浮点，用整数乘除（四舍五入）。
# 亮度 0 时要真的变 0，别留个 1 —— 低亮度下 1 也很显眼。
scale_color() {
    _r=$(printf '%d' "0x$(printf '%s' "$1" | cut -c1-2)" 2>/dev/null)
    _g=$(printf '%d' "0x$(printf '%s' "$1" | cut -c3-4)" 2>/dev/null)
    _b=$(printf '%d' "0x$(printf '%s' "$1" | cut -c5-6)" 2>/dev/null)
    [ -n "$_r" ] && [ -n "$_g" ] && [ -n "$_b" ] || { echo "$1"; return; }
    _r=$(( (_r * $2 + 50) / 100 ))
    _g=$(( (_g * $2 + 50) / 100 ))
    _b=$(( (_b * $2 + 50) / 100 ))
    printf '%02X%02X%02X' "$_r" "$_g" "$_b"
}

# 动画子进程的开关。动画靠 ws2812-common run 常驻刷帧，
# 换档/关灯时必须先收掉旧的，否则两个进程抢同一个 spidev，
# 后者的灭灯帧会被前者下一帧覆盖 —— 「关不灭」就是这么来的。
kill_anim() {
    if [ -n "$ANIM_PID" ]; then
        kill "$ANIM_PID" 2>/dev/null
        wait "$ANIM_PID" 2>/dev/null
        ANIM_PID=
    fi
    # 兜底：守护被重启过、ANIM_PID 丢了的情况下，上一个动画进程会变成
    # 孤儿继续刷帧（它的父进程变成 init）。这里扫一遍全收掉，
    # 只杀 run 模式，不碰正在执行的单帧命令。
    #
    # 注意不能写成 `[ -n "$ANIM_PID" ] || return 0` —— 那样 ANIM_PID 为空的
    # 时候（正是最需要兜底的时候）反而直接返回，孤儿永远收不掉。
    for _p in $(pgrep -f "ws2812-common.*run" 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        kill "$_p" 2>/dev/null
    done
}

push_frame() {
    _enable=$(getprop persist.gammaos.rgb.enable)
    _effect=$(getprop persist.gammaos.rgb.effect)
    _color=$(getprop persist.gammaos.primary.rgb_hex)

    # 总开关关掉就是真灭 —— 必须发全零帧。
    # WS2812 会锁存上一帧，不发帧等于保持常亮（这是最常见的坑）。
    #
    # ⚠ 必须先杀动画子进程再灭灯。踩过的坑：这里原来直接 return，
    #   动画进程还在后台继续刷新，灭灯帧两秒内就被它覆盖回来，
    #   表现为「关了总开关灯还亮着」。
    if [ "$_enable" = "0" ]; then
        kill_anim
        "$BIN" --device "$DEV" --leds "$LEDS" off
        log -t $TAG "disabled, all off"
        return
    fi

    _hex=$(sanitize_color "$_color")
    if [ -z "$_hex" ]; then
        # 颜色读不出来时用自定义色兜底，再不行才给个默认橙红。
        _hex=$(sanitize_color "$(getprop persist.gammaos.primary.rgb_hex_custom)")
    fi
    [ -n "$_hex" ] || _hex=FF5000

    # ── effect 的真实取值（实机点出来的，别再猜）──────────────
    #
    #   界面按钮         persist.gammaos.rgb.effect    其他
    #   ─────────────────────────────────────────────────────
    #   跟随屏幕 RGB     follow
    #   纯色             none
    #   关闭             none                         颜色被置 #000000
    #   效果 1           "1"
    #   效果 2           "2"
    #   效果 3           "3"
    #
    # ⚠ 早期写的是 effect1/effect2/effect3，跟 app 实际写的 "1"/"2"/"3"
    #   对不上，导致点「效果1」灯毫无反应 —— 界面改了、属性改了、
    #   守护读不到匹配项 → 落到静态分支，看起来像"调节无效"。
    #
    # 三个效果映射到观感差别明显的动画，方便肉眼确认切换生效。
    case "$_effect" in
    1)        _eff=breath ;;
    2)        _eff=rainbow ;;
    3)        _eff=scroll ;;
    follow)   _eff="" ;;   # 跟随屏幕取色：没有屏幕取色后端，退化为静态色
    *)        _eff="" ;;
    esac

    # 「关闭」不是靠 enable=0，而是把颜色写成 #000000。
    # 全黑帧照样要发 —— WS2812 锁存上一帧，不发就一直是亮的。
    if [ "$_hex" = "000000" ]; then
        kill_anim
        "$BIN" --device "$DEV" --leds "$LEDS" off
        log -t $TAG "color is black, all off"
        return
    fi

    # 灯珠亮度：0-100。界面「颜色亮度」滑块。
    # 实测属性名 persist.gammaos.rgb.led_brightness（写进去 UI 会实时变暗），
    # 没设过就按 100 处理。
    _bright=$(getprop persist.gammaos.rgb.led_brightness)
    case "$_bright" in
    ''|*[!0-9]*) _bright=100 ;;
    esac
    [ "$_bright" -gt 100 ] && _bright=100
    _hex=$(scale_color "$_hex" "$_bright")

    if [ -n "$_eff" ]; then
        # 动画：run 会常驻并按帧刷新。放后台，父进程继续守着属性，
        # 属性一变就杀掉重开（否则会两个进程抢同一个 spidev）。
        kill_anim
        "$BIN" --device "$DEV" --leds "$LEDS" run "$_eff" "$_hex" &
        ANIM_PID=$!
        log -t $TAG "anim $_eff $LEDS leds, pid=$ANIM_PID"
    else
        kill_anim
        "$BIN" --device "$DEV" --leds "$LEDS" color "$_hex"
        log -t $TAG "solid #$_hex, $LEDS leds"
    fi
}

# 光有「呼吸」勾选但 effect=none 时，UI 期望的是静态色带亮度起伏。
# ws2812-common 的 breath 支持自定义色，直接复用。
apply() {
    push_frame
}

case "$1" in
watch)
    # ── 单实例保护 ──────────────────────────────────────────────
    #
    # 踩过的坑：调试时手工起过几次 watch，加上 init 拉的一份，同时跑着
    # 三四个守护进程。每个都自己 spawn 一个 ws2812-common run，互相抢
    # 同一个 spidev，表现为「效果乱跳 / 关不灭 / 进程越积越多」。
    #
    # 用 PID 锁文件保证只有一个守护在跑。锁里记的进程还活着就直接退出，
    # 死了就覆盖 —— 不需要 flock（Android toybox 没有）。
    LOCK=/data/local/tmp/ngp-stickled.pid
    if [ -f "$LOCK" ]; then
        _old=$(cat "$LOCK" 2>/dev/null)
        if [ -n "$_old" ] && [ "$_old" != "$$" ] && [ -d "/proc/$_old" ]; then
            log -t $TAG "another instance running (pid=$_old), exiting"
            exit 0
        fi
    fi
    echo $$ > "$LOCK"

    trap 'kill_anim; rm -f "$LOCK"; log -t $TAG "stopped, LEDs off"; "$BIN" --device "$DEV" --leds "$LEDS" off 2>/dev/null; exit 0' TERM INT
    LAST=
    while true; do
        NOW=$(fingerprint)
        if [ "$NOW" != "$LAST" ]; then
            LAST=$NOW
            push_frame
        fi
        # 500ms 够跟手（点完设置 1 秒内见效果），又不至于空转耗电。
        sleep 0.5
    done
    ;;
apply)
    apply
    ;;
off)
    kill_anim
    "$BIN" --device "$DEV" --leds "$LEDS" off
    ;;
status)
    echo "enable=$(getprop persist.gammaos.rgb.enable)"
    echo "effect=$(getprop persist.gammaos.rgb.effect)"
    echo "color=$(getprop persist.gammaos.primary.rgb_hex)"
    echo "leds=$LEDS  dev=$DEV  bin=$BIN"
    ;;
*)
    echo "usage: $0 {watch|apply|off|status}" >&2
    exit 2
    ;;
esac
