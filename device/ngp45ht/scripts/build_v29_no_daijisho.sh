#!/bin/bash
# v29：干掉 Daijishō —— 从 GammaOS 的首次开机安装清单里删除它，并删掉它的 APK 与
# 解压包，腾出约 47 MB system 空间。
#
# 背景：v27/v28 刷完首次开机仍会装上 Daijishō，因为它不在 /system/app 里，而是
# 由 /system/bin/setup.sh 的 install_apps 按 /system/etc/gammaos/apps.list 装的：
#
#   Daijisho|com.magneticchen.daijishou|/system/etc/daijisho||post_daijisho
#
# 源是 /system/etc/daijisho/ 目录（base.apk + 2 个 split，共 39 MB），装完还会
# 跑 post_daijisho：解 /system/etc/daijisho.tar.zst（9.7 MB）并把默认 home 设成
# Daijishō —— 正好和我们的 LANGOS 抢。
#
# 用法： bash build_v29_no_daijisho.sh <输入镜像> <输出镜像>
set -euo pipefail

IN="${1:?用法: $0 <输入镜像> <输出镜像>}"
OUT="${2:?用法: $0 <输入镜像> <输出镜像>}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)
LIST="$DEV/gammaos/apps.list"
[ -f "$LIST" ] || { echo "缺 $LIST" >&2; exit 1; }

[ "$IN" != "$OUT" ] && cp --sparse=always "$IN" "$OUT"

OFF4=$(python3 - "$OUT" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb'); f.seek(512); h = f.read(92)
plba, num, esz = struct.unpack_from('<Q', h, 72)[0], struct.unpack_from('<I', h, 80)[0], struct.unpack_from('<I', h, 84)[0]
f.seek(plba * 512); data = f.read(num * esz)
for i in range(num):
    e = data[i*esz:(i+1)*esz]
    if e[:16] == b'\x00'*16: continue
    if e[56:128].decode('utf-16-le').rstrip('\x00') == 'system':
        print(struct.unpack_from('<Q', e, 32)[0] * 512)
PY
)
echo "p4(system) offset=$OFF4"
dbg4() { debugfs -w -R "$1" "$OUT?offset=$OFF4" >/dev/null 2>&1 || true; }

echo "== 替换 apps.list"
dbg4 "rm /system/etc/gammaos/apps.list"
dbg4 "write $LIST /system/etc/gammaos/apps.list"
dbg4 "sif /system/etc/gammaos/apps.list mode 0100644"

echo "== 删 /system/etc/daijisho（base + 2 split）"
for f in base.apk split_config.en.apk split_config.xxxhdpi.apk; do
    dbg4 "rm /system/etc/daijisho/$f"
done
dbg4 "rmdir /system/etc/daijisho"

echo "== 删 /system/etc/daijisho.tar.zst"
dbg4 "rm /system/etc/daijisho.tar.zst"

echo "== 补 SELinux 标签"
VALS=$(mktemp); printf 'u:object_r:system_file:s0\0' > "$VALS"
C=$(mktemp)
echo "ea_rm /system/etc/gammaos/apps.list security.selinux" > "$C"
echo "ea_set -f $VALS /system/etc/gammaos/apps.list security.selinux" >> "$C"
debugfs -w -f "$C" "$OUT?offset=$OFF4" >/dev/null 2>&1
rm -f "$C" "$VALS"

echo "== 验证"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
debugfs -R "dump /system/etc/gammaos/apps.list $T/list" "$OUT?offset=$OFF4" 2>/dev/null
if grep -q '^Daijisho|' "$T/list"; then
    echo "  FAIL 清单里还有 Daijisho 行" >&2; exit 1
fi
echo "  OK   apps.list 已无 Daijisho 行"
if debugfs -R "ls /system/etc" "$OUT?offset=$OFF4" 2>/dev/null | grep -qi daijisho; then
    echo "  FAIL /system/etc 下还有 daijisho 残留" >&2; exit 1
fi
echo "  OK   /system/etc 已无 daijisho 残留"
printf '  %-42s ' /system/etc/gammaos/apps.list
debugfs -R "ea_list /system/etc/gammaos/apps.list" "$OUT?offset=$OFF4" 2>/dev/null \
    | grep -o 'system_file:s0\\000' || echo MISSING

echo "== 剩余空间"
debugfs -R "stats" "$OUT?offset=$OFF4" 2>/dev/null | grep -E "Free blocks|Free inodes" | sed 's/^/  /'

echo
echo "注意：整卡重刷后 /data 会清空，Daijishō 不会再有。"
echo "      若只替换分区（不重刷 userdata），旧的 /data/app 里那份还在，需要手动卸："
echo "      adb shell pm uninstall com.magneticchen.daijishou"
