#!/bin/bash
# build_v32.sh — v32：在 v31 基础上补 PS2 全链路 + 快捷键 + app 预装。
#
# 用法: bash build_v32.sh <v31.img> <v32.img>
#
# 只动 /vendor(p5)，不碰 system —— LANGOS 是 system app，直接换
# /system/app 里的 apk 要过 verity 和签名一致性，风险高；改成放
# /vendor/etc/ngp/LANGOS.apk + 开机 pm install -r 装成 /data/app 更新版。
#
# 写入内容：
#   /bin/ngp-fixup.sh            替换（570 行，第 ⑩ remap + 第 ⑪ 预装）
#   /bin/ngp-ps2hotkey.sh        新增（SELECT+START 双击退出 NetherSX2）
#   /etc/init/ngp-ps2hotkey.rc   新增
#   /bin/ngp-azahar-exit.sh      新增（3DS 退出后焦点为空就拉回 LANGOS）
#   /etc/init/ngp-azahar-exit.rc 新增
#   /etc/ngp/LANGOS.apk          新增（LANGOS 3.2：PS2→NetherSX2、N64/DC 映射修正）
#   /etc/ngp/ps2prefs.xml        新增（AetherSX2 首启配置模板：OpenGL + Pad1）
#   /app/NetherSX2/NetherSX2.apk 新增（vendor app，开机自动扫描安装）
set -euo pipefail

IN="${1:?用法: $0 <v31.img> <v32.img>}"
OUT="${2:?用法: $0 <v31.img> <v32.img>}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)

FIXUP="$DEV/ime/ngp-fixup.sh"
HK="$DEV/scripts/ngp-ps2hotkey.sh"
HKRC="$DEV/scripts/ngp-ps2hotkey.rc"
AX="$DEV/scripts/ngp-azahar-exit.sh"
AXRC="$DEV/scripts/ngp-azahar-exit.rc"
LANGOS="$DEV/apps/LANGOS-3.2-n64-dc.apk"
PREFS="$DEV/ps2/ps2prefs.xml"
NSX2="${NSX2_APK:-/home/liang/rainject/nethersx2/NetherSX2-v2.2n-4248.apk}"

for f in "$FIXUP" "$HK" "$HKRC" "$AX" "$AXRC" "$LANGOS" "$PREFS" "$NSX2"; do
    [ -f "$f" ] || { echo "缺文件: $f" >&2; exit 1; }
done

[ "$IN" != "$OUT" ] || { echo "输入输出不能同名" >&2; exit 1; }
[ -f "$OUT" ] && { echo "输出已存在，先删掉: $OUT" >&2; exit 1; }

echo "== 复制镜像（sparse）"
cp --sparse=always "$IN" "$OUT"

echo "== 定位 vendor 分区"
OFF5=$(python3 - "$OUT" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb'); f.seek(512); h = f.read(92)
plba, num, esz = struct.unpack_from('<Q', h, 72)[0], struct.unpack_from('<I', h, 80)[0], struct.unpack_from('<I', h, 84)[0]
f.seek(plba * 512); data = f.read(num * esz)
for i in range(num):
    e = data[i*esz:(i+1)*esz]
    if e[:16] == b'\x00'*16: continue
    if e[56:128].decode('utf-16-le').rstrip('\x00') == 'vendor':
        print(struct.unpack_from('<Q', e, 32)[0] * 512)
PY
)
[ -n "$OFF5" ] || { echo "找不到 vendor 分区" >&2; exit 1; }
echo "   vendor offset=$OFF5"

IMGV="$OUT?offset=$OFF5"
dbg() { debugfs -w -R "$1" "$IMGV" >/dev/null 2>&1 || true; }

echo "== 剩余空间（写之前）"
debugfs -R "stats" "$IMGV" 2>/dev/null | grep -iE "^Free blocks" || true

echo "== 建目录 /etc/ngp /app/NetherSX2"
dbg "mkdir /etc/ngp"
dbg "sif /etc/ngp mode 040755"
dbg "mkdir /app/NetherSX2"
dbg "sif /app/NetherSX2 mode 040755"

echo "== 写脚本与服务"
write() {  # write <本地文件> <镜像内路径> <mode>
    dbg "rm $2"
    dbg "write $1 $2"
    dbg "sif $2 mode $3"
    dbg "sif $2 uid 0"
    dbg "sif $2 gid 0"
}
write "$FIXUP"  /bin/ngp-fixup.sh        0100755
write "$HK"     /bin/ngp-ps2hotkey.sh    0100755
write "$HKRC"   /etc/init/ngp-ps2hotkey.rc   0100644
write "$AX"     /bin/ngp-azahar-exit.sh  0100755
write "$AXRC"   /etc/init/ngp-azahar-exit.rc 0100644
write "$LANGOS" /etc/ngp/LANGOS.apk      0100644
write "$PREFS"  /etc/ngp/ps2prefs.xml    0100644
write "$NSX2"   /app/NetherSX2/NetherSX2.apk 0100644

echo "== SELinux 标签"
VALB=$(mktemp); printf 'u:object_r:vendor_file:s0\0' > "$VALB"
VALC=$(mktemp); printf 'u:object_r:vendor_configs_file:s0\0' > "$VALC"
VALA=$(mktemp); printf 'u:object_r:vendor_app_file:s0\0' > "$VALA"
TAGS=$(mktemp)
for p in /bin/ngp-fixup.sh /bin/ngp-ps2hotkey.sh /bin/ngp-azahar-exit.sh; do
    echo "ea_rm $p security.selinux" >> "$TAGS"
    echo "ea_set -f $VALB $p security.selinux" >> "$TAGS"
done
for p in /etc/init/ngp-ps2hotkey.rc /etc/init/ngp-azahar-exit.rc /etc/ngp/LANGOS.apk /etc/ngp/ps2prefs.xml; do
    echo "ea_rm $p security.selinux" >> "$TAGS"
    echo "ea_set -f $VALC $p security.selinux" >> "$TAGS"
done
for p in /app/NetherSX2 /app/NetherSX2/NetherSX2.apk; do
    echo "ea_rm $p security.selinux" >> "$TAGS"
    echo "ea_set -f $VALA $p security.selinux" >> "$TAGS"
done
debugfs -w -f "$TAGS" "$IMGV" >/dev/null 2>&1 || true

echo "== 标签回查"
for p in /bin/ngp-fixup.sh /bin/ngp-ps2hotkey.sh /bin/ngp-azahar-exit.sh \
         /etc/init/ngp-ps2hotkey.rc /etc/init/ngp-azahar-exit.rc \
         /etc/ngp/LANGOS.apk /etc/ngp/ps2prefs.xml \
         /app/NetherSX2 /app/NetherSX2/NetherSX2.apk; do
    printf '  %-36s ' "$p"
    debugfs -R "ea_list $p" "$IMGV" 2>/dev/null | grep -oE 'vendor_(app|configs)?_?file:s0\\000' || echo "MISSING"
done

echo "== 回读校验"
T=$(mktemp -d)
trap 'rm -rf "$T" "$VALB" "$VALC" "$VALA" "$TAGS"' EXIT
rc=0
check() {
    local path="$1" src="$2" name="$3"
    debugfs -R "dump $path $T/$name" "$IMGV" >/dev/null 2>&1
    if [ ! -f "$T/$name" ]; then echo "  FAIL $name 回读失败"; rc=1; return; fi
    local a b
    a=$(md5sum "$T/$name" | cut -d' ' -f1)
    b=$(md5sum "$src" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "  OK   $name  $a"; else echo "  FAIL $name  $a != $b"; rc=1; fi
}
check /bin/ngp-fixup.sh                    "$FIXUP"  ngp-fixup.sh
check /bin/ngp-ps2hotkey.sh                "$HK"     ngp-ps2hotkey.sh
check /etc/init/ngp-ps2hotkey.rc           "$HKRC"   ngp-ps2hotkey.rc
check /bin/ngp-azahar-exit.sh              "$AX"     ngp-azahar-exit.sh
check /etc/init/ngp-azahar-exit.rc         "$AXRC"   ngp-azahar-exit.rc
check /etc/ngp/LANGOS.apk                  "$LANGOS" LANGOS.apk
check /etc/ngp/ps2prefs.xml                "$PREFS"  ps2prefs.xml
check /app/NetherSX2/NetherSX2.apk         "$NSX2"   NetherSX2.apk

echo "== e2fsck"
e2fsck -fn "$IMGV" 2>&1 | tail -3

echo "== 剩余空间（写之后）"
debugfs -R "stats" "$IMGV" 2>/dev/null | grep -iE "^Free blocks" || true

if [ $rc -ne 0 ]; then echo "!!! 有文件校验失败" >&2; exit 1; fi
echo "== 完成: $OUT"
