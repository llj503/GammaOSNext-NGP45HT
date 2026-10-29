#!/bin/bash
# 把内置应用（手柄拼音 IME、LANGOS 前端）写进 system 分区，
# 并把更新后的 ngp-fixup.sh 写进 vendor 分区。
#
# 用法： bash build_v27_apps.sh <输入镜像> <输出镜像>
#
# 分区偏移从 GPT 读，不写死：RK3562 GammaOS Core 的 p4=system、p5=vendor，
# 但换底座镜像时偏移会变，硬编码迟早出事。
set -euo pipefail

IN="${1:?用法: $0 <输入镜像> <输出镜像>}"
OUT="${2:?用法: $0 <输入镜像> <输出镜像>}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)
APPS="$DEV/apps"
FIXUP="$DEV/ime/ngp-fixup.sh"

for f in "$APPS/NgpIme.apk" "$APPS/LANGOS.apk" "$FIXUP"; do
    [ -f "$f" ] || { echo "缺文件: $f" >&2; exit 1; }
done

# --- 从 GPT 取 p4 / p5 的字节偏移 ---
read -r OFF4 OFF5 < <(python3 - "$IN" <<'PY'
import struct, sys
p = sys.argv[1]
f = open(p, 'rb')
f.seek(512)
h = f.read(92)
plba, num, esz = struct.unpack_from('<Q', h, 72)[0], struct.unpack_from('<I', h, 80)[0], struct.unpack_from('<I', h, 84)[0]
f.seek(plba * 512)
data = f.read(num * esz)
off = {}
for i in range(num):
    e = data[i*esz:(i+1)*esz]
    if e[:16] == b'\x00' * 16:
        continue
    name = e[56:128].decode('utf-16-le').rstrip('\x00')
    first = struct.unpack_from('<Q', e, 32)[0]
    off[name] = first * 512
print(off['system'], off['vendor'])
PY
)
echo "p4(system)=$OFF4  p5(vendor)=$OFF5"

[ "$IN" != "$OUT" ] && cp --sparse=always "$IN" "$OUT"

dbg4() { debugfs -w -R "$1" "$OUT?offset=$OFF4" 2>&1 | grep -v '^debugfs ' || true; }
dbg5() { debugfs -w -R "$1" "$OUT?offset=$OFF5" 2>&1 | grep -v '^debugfs ' || true; }

echo "== 写 /system/app/NgpIme/NgpIme.apk"
dbg4 "mkdir /system/app/NgpIme"
dbg4 "write $APPS/NgpIme.apk /system/app/NgpIme/NgpIme.apk"
dbg4 "sif /system/app/NgpIme/NgpIme.apk mode 0100644"
dbg4 "sif /system/app/NgpIme/NgpIme.apk uid 0"
dbg4 "sif /system/app/NgpIme/NgpIme.apk gid 0"

echo "== 写 /system/app/LANGOS/LANGOS.apk"
dbg4 "mkdir /system/app/LANGOS"
dbg4 "write $APPS/LANGOS.apk /system/app/LANGOS/LANGOS.apk"
dbg4 "sif /system/app/LANGOS/LANGOS.apk mode 0100644"
dbg4 "sif /system/app/LANGOS/LANGOS.apk uid 0"
dbg4 "sif /system/app/LANGOS/LANGOS.apk gid 0"

echo "== 替换 /vendor/bin/ngp-fixup.sh"
dbg5 "rm /bin/ngp-fixup.sh"
dbg5 "write $FIXUP /bin/ngp-fixup.sh"
dbg5 "sif /bin/ngp-fixup.sh mode 0100755"
dbg5 "sif /bin/ngp-fixup.sh uid 0"

# --- SELinux 标签 ---
#
# debugfs 新建的 inode 没有 security.selinux，挂载后是 u:object_r:unlabeled:s0。
# 缺了它 system app 能不能扫到看运气（实测 unlabeled 的 AzaharSf 也能被
# PackageManager 扫到，但那是踩对了，不是保证），vendor 的脚本同理。
# 这里按同类原生文件补：system 下 system_file，vendor 下 vendor_file。
#
# 值必须以 NUL 结尾 —— 镜像里原生值都是 26 字节（25 字符 + NUL）。
# 直接在命令文件里写 \000 不管用（debugfs 按行读，NUL 会被吃掉），
# 必须用 ea_set -f <值文件>。
VAL=$(mktemp); VALV=$(mktemp)
printf 'u:object_r:system_file:s0\0' > "$VAL"
printf 'u:object_r:vendor_file:s0\0' > "$VALV"

TAGS4=$(mktemp)
for p in /system/app/NgpIme /system/app/NgpIme/NgpIme.apk \
         /system/app/LANGOS /system/app/LANGOS/LANGOS.apk; do
    echo "ea_rm $p security.selinux" >> "$TAGS4"
    echo "ea_set -f $VAL $p security.selinux" >> "$TAGS4"
done
debugfs -w -f "$TAGS4" "$OUT?offset=$OFF4" >/dev/null 2>&1

TAGS5=$(mktemp)
echo "ea_rm /bin/ngp-fixup.sh security.selinux" > "$TAGS5"
echo "ea_set -f $VALV /bin/ngp-fixup.sh security.selinux" >> "$TAGS5"
debugfs -w -f "$TAGS5" "$OUT?offset=$OFF5" >/dev/null 2>&1

echo "== SELinux 标签"
for p in /system/app/NgpIme /system/app/NgpIme/NgpIme.apk \
         /system/app/LANGOS /system/app/LANGOS/LANGOS.apk; do
    printf '  %-40s ' "$p"
    debugfs -R "ea_list $p" "$OUT?offset=$OFF4" 2>/dev/null | grep -o 'system_file:s0\\000' || echo "MISSING"
done
printf '  %-40s ' /bin/ngp-fixup.sh
debugfs -R "ea_list /bin/ngp-fixup.sh" "$OUT?offset=$OFF5" 2>/dev/null | grep -o 'vendor_file:s0\\000' || echo "MISSING"

echo "== 回读校验"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
debugfs -R "dump /system/app/NgpIme/NgpIme.apk $T/NgpIme.apk" "$OUT?offset=$OFF4" 2>/dev/null
debugfs -R "dump /system/app/LANGOS/LANGOS.apk $T/LANGOS.apk" "$OUT?offset=$OFF4" 2>/dev/null
debugfs -R "dump /bin/ngp-fixup.sh $T/ngp-fixup.sh" "$OUT?offset=$OFF5" 2>/dev/null
rc=0
for f in NgpIme.apk LANGOS.apk; do
    a=$(md5sum "$T/$f" | cut -d' ' -f1); b=$(md5sum "$APPS/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "  OK   $f  $a" || { echo "  FAIL $f  $a != $b"; rc=1; }
done
a=$(md5sum "$T/ngp-fixup.sh" | cut -d' ' -f1); b=$(md5sum "$FIXUP" | cut -d' ' -f1)
[ "$a" = "$b" ] && echo "  OK   ngp-fixup.sh  $a" || { echo "  FAIL ngp-fixup.sh  $a != $b"; rc=1; }

echo "== 剩余空间"
debugfs -R "stats" "$OUT?offset=$OFF4" 2>/dev/null | grep -E "Free blocks|Free inodes" | sed 's/^/  p4 /'
debugfs -R "stats" "$OUT?offset=$OFF5" 2>/dev/null | grep -E "Free blocks|Free inodes" | sed 's/^/  p5 /'

exit $rc
