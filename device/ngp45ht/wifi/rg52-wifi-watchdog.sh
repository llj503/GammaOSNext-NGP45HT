#!/system/bin/sh
# NGP45HT (RK3562) — WiFi 看门狗
# AIC8800DC 的 USB 驱动被挂起后会把自己 latch 成 "usb disconnected"：
# 之后所有扫描返回 busy，界面上 WiFi 整个消失（模块其实还在，是假死）。
# 判据：WiFi 处于开启状态，但连续两次驱动层扫描拿不到任何 BSS → 自动重载驱动。
#
# 由 /vendor/etc/init/rg52-wifi-fix.rc 在 sys.boot_completed=1 时拉起，常驻循环。

LOG=/data/local/tmp/rg52-wifi-watchdog.log
MODDIR=/vendor/lib/modules
FWPATH=/vendor/etc/firmware/aic8800
CHECK_INTERVAL=300
CONFIRM_INTERVAL=20

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# WiFi 是否处于开启状态（用户主动关掉时不干预）
wifi_on() {
    dumpsys wifi 2>/dev/null | grep -qi "Wi-Fi is enabled"
}

# 驱动层扫描能否拿到 BSS
scan_ok() {
    [ -e /sys/class/net/wlan0 ] || return 1
    n=$(iw dev wlan0 scan 2>/dev/null | grep -c "^BSS")
    [ "$n" -gt 0 ]
}

log "=== watchdog start (pid $$) interval=${CHECK_INTERVAL}s ==="

while true; do
    sleep "$CHECK_INTERVAL"

    # 用户关了 WiFi 就不要自作主张拉起来
    if ! wifi_on; then continue; fi

    if scan_ok; then continue; fi
    sleep "$CONFIRM_INTERVAL"
    if scan_ok; then continue; fi
    if ! wifi_on; then continue; fi

    log "wifi latched (no BSS twice), recovering"
    svc wifi disable
    sleep 3
    setprop ctl.restart vendor.wifi_hal_legacy
    sleep 3
    ip link set wlan0 down 2>/dev/null
    rmmod aic8800_fdrv_usb 2>/dev/null
    rmmod aic_load_fw_usb 2>/dev/null
    sleep 1
    insmod "$MODDIR/aic_load_fw_usb.ko" aic_fw_path="$FWPATH"
    sleep 1
    insmod "$MODDIR/aic8800_fdrv_usb.ko"
    sleep 3
    svc wifi enable
    sleep 6
    log "recovery done: wlan0=$(ip link show wlan0 2>/dev/null | grep -o 'state [A-Z]*')" \
        "bss=$(iw dev wlan0 scan 2>/dev/null | grep -c '^BSS')"
done
