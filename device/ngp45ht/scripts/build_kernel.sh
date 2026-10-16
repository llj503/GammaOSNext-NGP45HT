#!/bin/bash
# Build NGP45HT kernel from mamaich tree + user's joystick patch + NGP45HT DTS
# --- shell hygiene: strip safe-delete hijack (kernel build does rm -rf on .tmp_*) ---
unset -f rm unlink rmdir 2>/dev/null
unset CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_BROKERED_SHELL_ENV 2>/dev/null
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hash -r
set -e
export PATH=$PATH:/home/liang/gammaos-ngp45ht/aarch64--glibc--stable-2024.02-1/bin:/home/liang/gammaos-ngp45ht/hostdeb/root/usr/bin
export CROSS_COMPILE=aarch64-linux-
export ARCH=arm64
export LOCALVERSION=-ngp45ht
cd /home/liang/gammaos-ngp45ht/kernel
make rg52mini_defconfig
echo "=== CONFIG CHECK ==="
grep -E "CONFIG_JOYSTICK_RK3562=|CONFIG_DRM_PANEL_SIMPLE=|CONFIG_SND_SOC_RK817=|CONFIG_BATTERY_RK817=|CONFIG_AIC8800_WLAN_SUPPORT=|CONFIG_USERFAULTFD=" .config
echo "=== BUILDING ==="
make -j16 Image dtbs
echo "=== ARTIFACTS ==="
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb
echo BUILD_DONE
