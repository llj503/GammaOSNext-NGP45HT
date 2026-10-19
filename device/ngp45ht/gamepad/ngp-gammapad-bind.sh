#!/system/bin/sh
# 开机把打过补丁的 gammapad 绑到 /system/bin/gammapad 上
# 补丁内容：ABXY swap 只交换 A/B（304↔305），X/Y（307/308）保持原样
SRC=/vendor/bin/gammapad.abonly
DST=/system/bin/gammapad
[ -f "$SRC" ] || { log -t ngp-gammapad "no patched binary"; exit 0; }
mount --bind "$SRC" "$DST" 2>/dev/null
log -t ngp-gammapad "bind $(cat /proc/mounts | grep -c " $DST ") "
