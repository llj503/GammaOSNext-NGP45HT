#!/system/bin/sh
# NGP45HT BT 栈启动部署（eMMC/TF 通用，需 adb root）
# 效果: WiFi 正常 + Android BT 栈完全启动 (state ON)
# 限制: BootROM BT 核不支持扫描命令(0x0C1A/0x0401/0x200B/0x200C 均 0x11/无应答)，
#       设置里点扫描会显示"未找到设备"，不会崩溃。
set -e
D=/data/local/tmp
mount --bind $D/out-libbt-vendor-v14.so /vendor/lib64/libbt-vendor.so
mount --bind $D/out-libbt-vendor-v14.so /vendor/lib64/libbt-vendor-seekwave.so
insmod $D/ng_load_fw.ko aic_fw_path=$D/fw-all 2>/dev/null || true
sleep 2
insmod $D/mama_fdrv.ko 2>/dev/null || true
sleep 3
svc wifi enable
sleep 4
svc bluetooth enable
sleep 15
dumpsys bluetooth_manager | grep -E "^  (state|address)"
