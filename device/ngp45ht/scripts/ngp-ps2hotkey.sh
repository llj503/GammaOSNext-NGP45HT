#!/system/bin/sh
# NGP45HT: PS2 (NetherSX2 / AetherSX2) 退出热键守护
#
# 行为：
#   在 AetherSX2 前台时，同时按下 SELECT + START 两次（3 秒内），
#   force-stop 掉 AetherSX2 并回到 LANGOS。
#
# 为什么不用 AetherSX2 自带的 hotkey：
#   libemucore.so 里只有 Open Pause Menu / ToggleFrameLimit / SaveState 之类的动作，
#   没有任何 "Exit" 热键。退出只能在暂停菜单里手点，或者从外部 force-stop。
#   而且 force-stop 才能「彻底清掉后台」，普通 finish() 会留进程。
#
# 依赖：/dev/input/event4 是 gammapad 的虚拟手柄（物理手柄被它 re-hid 掉了），
#       按键走 evdev 广播，本脚本只读不影响模拟器。

DEV=/dev/input/event4
PKG=xyz.aethersx2.android
HOME_ACT=com.retrofront/com.retrofront.NativeActivity
TAG=ngp-ps2hotkey
WINDOW=3          # 两次组合键之间允许的最大间隔（秒）

log -t $TAG "hotkey daemon started (dev=$DEV)"

# 等设备就绪
while [ ! -e "$DEV" ]; do
    sleep 2
done

sel=0
start=0
count=0
last=0

getevent -l "$DEV" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *BTN_SELECT*DOWN*)
            sel=1
            ;;
        *BTN_SELECT*UP*)
            sel=0
            ;;
        *BTN_START*DOWN*)
            start=1
            if [ "$sel" = "1" ]; then
                now=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
                if [ $((now - last)) -le "$WINDOW" ] && [ "$last" != "0" ]; then
                    count=$((count + 1))
                else
                    count=1
                fi
                last=$now
                log -t $TAG "combo SELECT+START #$count"
                if [ "$count" -ge 2 ]; then
                    count=0
                    last=0
                    fg=$(getprop sys.gammaos.gamepad.fg_pkg)
                    if [ "$fg" = "$PKG" ]; then
                        log -t $TAG "exiting $PKG (force-stop) and returning home"
                        am force-stop "$PKG"
                        sleep 1
                        am start -n "$HOME_ACT" >/dev/null 2>&1
                        log -t $TAG "done"
                    else
                        log -t $TAG "combo ignored: foreground is $fg"
                    fi
                fi
            fi
            ;;
        *BTN_START*UP*)
            start=0
            ;;
    esac
done
