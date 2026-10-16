#!/system/bin/sh
# NGP45HT (RK3562) — 开机一次性加固：WiFi 设置 + 输入法 + AIC8800DC USB 电源管理
# 由 /vendor/etc/init/rg52-wifi-fix.rc 在 sys.boot_completed=1 时执行（oneshot，root）

LOG=/data/local/tmp/rg52-wifi-fix.log

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

log "=== start (pid $$) ==="

# ---- 1. WiFi 设置：永不休眠、允许后台扫描、国家码 CN ----
settings put global wifi_sleep_policy 2
settings put global wifi_scan_always_enabled 1
settings put global wifi_country_code CN
log "settings: sleep=$(settings get global wifi_sleep_policy)" \
    "scan_always=$(settings get global wifi_scan_always_enabled)" \
    "cc=$(settings get global wifi_country_code)"

# ---- 2. 输入法：默认改成 AOSP TV 键盘 ----
# 原默认的 LeanKeyKeyboard 在 WiFi 密码框里会崩（IME 窗口 invalid token），
# 密码输不进去、连接根本发不出去。AOSP leanback 键盘用方向键可导航，稳定。
AOSP_IME=com.android.inputmethod.leanback/.service.LeanbackImeService
ime enable "$AOSP_IME" 2>/dev/null
settings put secure default_input_method "$AOSP_IME"
log "ime default=$(settings get secure default_input_method)"

# ---- 3. AIC8800DC (USB a69c:88dc) 电源管理：禁止挂起 ----
# 驱动在链路挂起后会把自己 latch 成 "usb disconnected"，之后所有扫描返回 busy，
# 表现就是 WiFi 整个消失。这里把该设备的 runtime PM 永久关掉。
n=0
while [ $n -lt 30 ]; do
    for d in /sys/bus/usb/devices/*/; do
        if grep -q "a69c" "$d/idVendor" 2>/dev/null; then
            echo on       > "$d/power/control" 2>/dev/null
            echo disabled > "$d/power/wakeup"  2>/dev/null
            log "usb pm: ${d} vid=$(cat $d/idVendor 2>/dev/null):$(cat $d/idProduct 2>/dev/null)" \
                "control=$(cat $d/power/control 2>/dev/null)" \
                "wakeup=$(cat $d/power/wakeup 2>/dev/null)"
            n=99
            break
        fi
    done
    [ "$n" -eq 99 ] && break
    sleep 1
    n=$((n + 1))
done
[ "$n" -ne 99 ] && log "WARN: AIC usb device (vid a69c) not found"

log "=== done ==="
exit 0
