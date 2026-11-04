#!/system/bin/sh
#
# ngp-powerled —— 机身状态指示灯守护
#
# 为什么需要这个脚本：
#   板子上的红/蓝两颗状态灯挂在 GPIO3_C2 / GPIO3_C1，直接由 SoC 引脚驱动。
#   rk817 芯片只有充电管理，没有"驱动状态灯"的硬件逻辑；5.10 的 rk817 驱动
#   也不解析 DTS 里的 charge_red_gpio / charge_blue_gpio。所以灯不会自己亮。
#
#   DTS 里已经把这两根脚交给内核 leds-gpio 驱动，注册成
#       /sys/class/leds/charge-red/brightness
#       /sys/class/leds/charge-blue/brightness
#   本脚本就只做一件事：按充电状态去写这两个 brightness。
#
# 为什么不用内核 trigger：
#   CONFIG_LEDS_TRIGGER_* 在本机只开了 LEDS_TRIGGERS 框架，具体的
#   timer/heartbeat/default-on 全是 not set，没有现成的"充电指示"trigger。
#   自己轮询 /sys/class/power_supply 比重新编内核简单且可调。
#
# 状态机（判据以电流为准，不信 battery/status —— 详见 decide_state）：
#   真在充电   -> 红灯常亮        current_now > +150mA
#   已充满     -> 蓝灯常亮        Full 或容量>=99% 且电流接近 0
#   外部供电   -> 蓝灯常亮        插着线但电池没在充（OTG 口典型）
#   拔掉线     -> 全灭
#
# 停止方式：init 里 stop ngp_powerled。脚本对 TERM 做了 trap，
# 会先把两颗灯关掉再退出，不会留灯常亮。
# rc 里 on property:init.svc.ngp_powerled=stopped 会自动拉起。

TAG=ngp-powerled
POLL_SEC=3
RED=/sys/class/leds/charge-red/brightness
BLUE=/sys/class/leds/charge-blue/brightness
AC=/sys/class/power_supply/ac/online
USB=/sys/class/power_supply/usb/online
BAT=/sys/class/power_supply/battery

# 上一次设置过的状态，避免每轮都重复写（写 sysfs 会触发驱动回调）
LAST=""

log_msg() {
    log -t "$TAG" "$*" 2>/dev/null
}

# 写单个灯。灯不存在就静默跳过 —— 老 DTB 没有 leds 节点时脚本仍能运行，
# 只是什么也不做，不会因为 set -e 之类的把自己搞死。
set_led() {
    _path="$1"
    _val="$2"
    [ -w "$_path" ] || return 0
    printf '%s' "$_val" > "$_path" 2>/dev/null
}

all_off() {
    set_led "$RED" 0
    set_led "$BLUE" 0
}

read_val() {
    _f="$1"
    [ -r "$_f" ] || { echo ""; return; }
    cat "$_f" 2>/dev/null | tr -d ' \n\r'
}

# ── 是否接了外部电源（最重要的一处，别改回去）────────────────────
#
# 不能信 /sys/class/power_supply/ac/online 和 usb/online。实测：
#   什么都没插的时候，ac/online 依然报 1、ac/status 报 Charging，
#   而同一时刻所有硬件判据都说没插：
#     - 寄存器 0xF0 = 0x82  -> bit6 PLUG_IN_STS = 0   （芯片说没插）
#     - 寄存器 0xEB = 0x80  -> CHG_STS = 0 (OFF)      （充电没启动）
#     - gpio-103 rk817_dc_det 为 lo                   （DC 检测脚说没插）
#   这是 5.10 rk817_charger.c 的老问题：ac_in / usb_in 在某些路径上
#   不会被清零，sysfs 就一直是上次的值。用户态看到的 online=1 是假的。
#
# 所以判"有没有插线"要直接读 PMIC 寄存器里的 PLUG_IN_STS 位，
# 那是芯片自己采样的结果，不会残留。
#
# OTG 口的情况：能供电、能跑数据，但不给电池充电，PLUG_IN_STS 也可能是 0。
# 这种"插了也没充电"的场景，靠 current_now 为负来判断（见 decide_state），
# 而不是靠这里。
REGMAP=/sys/kernel/debug/regmap/0-0020/registers

# 读一个 8bit 寄存器，输出十进制。读不到输出空。
read_reg() {
    _addr="$1"
    _line=$(grep "^${_addr}:" "$REGMAP" 2>/dev/null | head -1)
    [ -n "$_line" ] || { echo ""; return; }
    _hex=${_line#*: }
    # 只取前两个 hex 字符（寄存器表每行是一个字节）
    _hex=$(printf '%s' "$_hex" | cut -c1-2)
    printf '%d' "0x$_hex" 2>/dev/null
}

# PLUG_IN_STS = 0xF0 的 bit6
power_plugged() {
    _f0=$(read_reg "f0")
    if [ -n "$_f0" ]; then
        # (_f0 >> 6) & 1
        _bit=$(( (_f0 / 64) % 2 ))
        [ "$_bit" = "1" ] && return 0 || return 1
    fi
    # 寄存器读不到（debugfs 没挂）时退回 sysfs，并且要求电流为正才算，
    # 宁可少亮也不要在没插线时瞎亮。
    _cur=$(battery_current)
    [ "$_cur" -gt 50000 ] 2>/dev/null && return 0
    return 1
}

battery_status() {
    read_val "$BAT/status"
}

battery_capacity() {
    read_val "$BAT/capacity"
}

# 电流单位 uA，正数=充电。清洗成纯整数，非法值一律当 0。
battery_current() {
    _c=$(read_val "$BAT/current_now")
    case "$_c" in
        ''|*[!0-9-]*) echo 0 ;;
        *) echo "$_c" ;;
    esac
}

# 判断该显示哪一种状态，输出 chg / full / ext / off
decide_state() {
    _status=$(battery_status)
    _cap=$(battery_capacity)
    _cur=$(battery_current)

    # 完全没插电
    if ! power_plugged; then
        echo off
        return
    fi

    # ── 判据说明（重要，别改回只看 status）──────────────────────
    # 本机 rk817 的 battery/status 会骗人。实测遇到过：
    #     status=Charging  但 current_now = -785000 uA（在放电）
    # 也就是"报告在充电，实际在耗电"。原因是 rk817 的充电状态机
    # 由 CHG_STS 寄存器推出来，而 OTG 口供电时 PLUG_IN_STS 为 0，
    # 充电器根本没真正启动，状态位却卡在 Charging。
    #
    # 所以：**电流方向才是唯一可靠判据**。
    #   current_now > 150mA  -> 真在充电（CC/CV 阶段典型 1.2~1.9A）
    #   -150 ~ 150mA         -> 基本静止，结合容量判是否充满
    #   < -150mA             -> 在放电
    #
    # status 只用来辅助区分"充满"，不作为"在充电"的依据。

    case "$_cur" in
        ''|*[!0-9-]*) _cur=0 ;;
    esac

    # 真在充电：电流明确为正且够大
    if [ "$_cur" -gt 150000 ] 2>/dev/null; then
        echo chg
        return
    fi

    # 电流很小：可能是充满后的涓流/截止，也可能是插了线但没充
    if [ "$_cur" -ge -150000 ] 2>/dev/null; then
        # 容量接近满 + 状态是 Full，认作充满
        if [ "$_status" = "Full" ] || [ "$_cap" -ge 99 ] 2>/dev/null; then
            echo full
        else
            # 插着线却几乎没电流：外部供电但没在给电池充（OTG 口典型）
            echo ext
        fi
        return
    fi

    # 明确在放电（插线也白插）
    echo ext
}

apply_state() {
    _st="$1"
    case "$_st" in
        chg)
            set_led "$BLUE" 0
            set_led "$RED" 1
            ;;
        full)
            set_led "$RED" 0
            set_led "$BLUE" 1
            ;;
        ext)
            # 插着线但没在给电池充电：蓝灯常亮表示"有外部供电"。
            # 最常见的是插在 OTG 口 —— 那个口能供电、能跑数据，
            # 但不给电池充电（PLUG_IN_STS 一直是 0）。
            set_led "$RED" 0
            set_led "$BLUE" 1
            ;;
        off)
            all_off
            ;;
        flash)
            # 只在状态变化时闪三下，不常驻闪烁，避免长期占用
            _i=0
            while [ $_i -lt 3 ]; do
                set_led "$RED" 1
                sleep 0.3
                set_led "$RED" 0
                sleep 0.3
                _i=$((_i + 1))
            done
            ;;
    esac
}

# 主循环。用 trap 保证收到 TERM 时把灯关掉 ——
# 否则 stop 服务之后灯会停在最后一个状态上，看起来像又常亮了。
trap 'all_off; log_msg "stopped, leds off"; exit 0' TERM INT

log_msg "start (red=$RED blue=$BLUE poll=${POLL_SEC}s)"

# 等 leds 节点出现（leds-gpio 是 platform driver，通常很早就 probe 完了，
# 但 boot 早期启动时仍可能没就绪，最多等 30 秒）
_wait=0
while [ ! -w "$RED" ] && [ ! -w "$BLUE" ] && [ $_wait -lt 30 ]; do
    sleep 1
    _wait=$((_wait + 1))
done
if [ ! -w "$RED" ] && [ ! -w "$BLUE" ]; then
    log_msg "no charge-red/charge-blue in /sys/class/leds, exiting"
    exit 0
fi

all_off

while true; do
    _st=$(decide_state)
    if [ "$_st" != "$LAST" ]; then
        apply_state "$_st"
        log_msg "state=$_st status=$(battery_status) cap=$(battery_capacity)% cur=$(battery_current)uA"
        LAST="$_st"
    fi
    sleep "$POLL_SEC"
done
