#!/bin/bash
# v28：把 vendor 分区从 254 MiB 扩到 575 MiB，把 3DS core 搬进 /vendor/azahar。
#
# 用法： bash build_v28_p5.sh <输入镜像> <输出镜像> [stage114 目录]
#
# 空间从 cache 拿：原 cache 384 MiB 里只有 lost+found，缩到 64 MiB 足够
# （非 A/B 设备上 cache 只放 OTA 包和 tombstone，本机不做 OTA）。
#
# 新布局（扇区，均 2048 对齐）：
#   p5 vendor  7200768-8378367  575 MiB   （原 7200768-7722343  254.7 MiB）
#   p6 cache   8378368-8509439   64 MiB   （原 7723008-8509439  384.0 MiB）
#   p7 及其后不动
set -euo pipefail

IN="${1:?用法: $0 <输入镜像> <输出镜像> [stage114 目录]}"
OUT="${2:?用法: $0 <输入镜像> <输出镜像> [stage114 目录]}"
STAGE="${3:-/run/media/liang/Data/ngp45ht/rg52mini-src/stage114/system/lib64}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)
AZ="$DEV/azahar"

CORE_FILES="libazahar-nano-core.so libhook_impl.so libmain_hook.so libfile_redirect_hook.so libgsl_alloc_hook.so"
for f in $CORE_FILES; do
    [ -f "$STAGE/$f" ] || { echo "缺 $STAGE/$f" >&2; exit 1; }
done
for f in "$AZ/azahar-nano-setup.sh" "$AZ/azahar-nano.rc"; do
    [ -f "$f" ] || { echo "缺 $f" >&2; exit 1; }
done

P5_START=7200768
P5_END=8378367      # 575 MiB
P6_START=8378368    # 2048 对齐
P6_END=8509439      # 64 MiB，紧接 p7
P5_BYTES=$(( (P5_END - P5_START + 1) * 512 ))
P6_BYTES=$(( (P6_END - P6_START + 1) * 512 ))

[ "$IN" != "$OUT" ] && cp --sparse=always "$IN" "$OUT"

echo "== 备份 GPT"
sgdisk --backup="${OUT}.gpt.bak" "$OUT" >/dev/null

echo "== 改 cache：$P6_START-$P6_END ($((P6_BYTES/1024/1024)) MiB)"
sgdisk -d 6 -n 6:${P6_START}:${P6_END} -t 6:8300 \
       -u 6:0A5AE0EC-26F2-42B0-8F1A-38B9D2F27A63 -c 6:cache "$OUT" >/dev/null

echo "== 改 vendor：$P5_START-$P5_END ($((P5_BYTES/1024/1024)) MiB)"
# 注意：-d 和 -n 放同一条命令里会报 "Could not change partition N's type code"，
# 必须分三步做（实测 sgdisk 1.0.9）。
UUID5=$(sgdisk -i 5 "$OUT" | sed -n 's/^Partition unique GUID: //p')
sgdisk -d 5 "$OUT" >/dev/null
sgdisk -n 5:${P5_START}:${P5_END} "$OUT" >/dev/null
sgdisk -t 5:8300 -u 5:"$UUID5" -c 5:vendor "$OUT" >/dev/null
sgdisk -v "$OUT" | tail -2

echo "== 重建 cache 文件系统（$((P6_BYTES/1024/1024)) MiB）"
UUID6=$(debugfs -R "stats" "$OUT?offset=$((7700480*512))" 2>/dev/null \
        | sed -n 's/^Filesystem UUID: *//p' | head -1)
dd if=/dev/zero of="$OUT" bs=512 seek=$P6_START count=$((P6_BYTES/512)) conv=notrunc status=none
mke2fs -t ext4 -F -L cache ${UUID6:+-U "$UUID6"} -E offset=$((P6_START*512)) "$OUT" \
       $((P6_BYTES/1024/1024))M >/dev/null 2>&1
debugfs -R "stats" "$OUT?offset=$((P6_START*512))" 2>/dev/null | grep -E "Block count|Filesystem state"

echo "== 扩容 vendor 文件系统"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
dd if="$OUT" of="$T/p5.img" bs=1M skip=$((P5_START/2048)) count=$((P5_BYTES/1024/1024)) status=none
e2fsck -fy "$T/p5.img" >/dev/null 2>&1 || true
resize2fs "$T/p5.img" >/dev/null 2>&1
e2fsck -fy "$T/p5.img" >/dev/null 2>&1 || true
dd if="$T/p5.img" of="$OUT" bs=1M seek=$((P5_START/2048)) conv=notrunc status=none
dumpe2fs -h "$T/p5.img" 2>/dev/null | grep -E "Block count|Free blocks"

echo "== 写 /vendor/azahar"
OFF5=$((P5_START*512))
dbg5() { debugfs -w -R "$1" "$OUT?offset=$OFF5" >/dev/null 2>&1 || true; }
dbg5 "mkdir /azahar"
for f in $CORE_FILES; do
    dbg5 "write $STAGE/$f /azahar/$f"
    dbg5 "sif /azahar/$f mode 0100644"
done

echo "== 写新 setup 脚本与 rc 到 system"
# system 的起点从 GPT 读，p4 在 v28 里没动
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
dbg4() { debugfs -w -R "$1" "$OUT?offset=$OFF4" >/dev/null 2>&1 || true; }
dbg4 "rm /system/bin/azahar-nano-setup.sh"
dbg4 "write $AZ/azahar-nano-setup.sh /system/bin/azahar-nano-setup.sh"
dbg4 "sif /system/bin/azahar-nano-setup.sh mode 0100755"
dbg4 "rm /system/etc/init/azahar-nano.rc"
dbg4 "write $AZ/azahar-nano.rc /system/etc/init/azahar-nano.rc"
dbg4 "sif /system/etc/init/azahar-nano.rc mode 0100644"

echo "== 补 SELinux 标签"
# 值必须 26 字节含 NUL；\000 直接写进命令文件会被 debugfs 吃掉，必须 ea_set -f
VALV=$(mktemp); VALS=$(mktemp)
printf 'u:object_r:vendor_file:s0\0' > "$VALV"
printf 'u:object_r:system_file:s0\0' > "$VALS"
C=$(mktemp)
{ echo "ea_rm /azahar security.selinux"; echo "ea_set -f $VALV /azahar security.selinux"
  for f in $CORE_FILES; do
    echo "ea_rm /azahar/$f security.selinux"; echo "ea_set -f $VALV /azahar/$f security.selinux"
  done; } > "$C"
debugfs -w -f "$C" "$OUT?offset=$OFF5" >/dev/null 2>&1
{ echo "ea_rm /system/bin/azahar-nano-setup.sh security.selinux"
  echo "ea_set -f $VALS /system/bin/azahar-nano-setup.sh security.selinux"
  echo "ea_rm /system/etc/init/azahar-nano.rc security.selinux"
  echo "ea_set -f $VALS /system/etc/init/azahar-nano.rc security.selinux"; } > "$C"
debugfs -w -f "$C" "$OUT?offset=$OFF4" >/dev/null 2>&1
rm -f "$C" "$VALV" "$VALS"

echo "== 删 p3 里重复的 core（v26/v27 遗留，现在 vendor 里有了）"
P3=$(python3 - "$OUT" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb'); f.seek(512); h = f.read(92)
plba, num, esz = struct.unpack_from('<Q', h, 72)[0], struct.unpack_from('<I', h, 80)[0], struct.unpack_from('<I', h, 84)[0]
f.seek(plba * 512); data = f.read(num * esz)
for i in range(num):
    e = data[i*esz:(i+1)*esz]
    if e[:16] == b'\x00'*16: continue
    if e[56:128].decode('utf-16-le').rstrip('\x00') == 'dArkOS_Fat':
        print(struct.unpack_from('<Q', e, 32)[0] * 512)
PY
)
if mdir -i "$OUT@@$P3" ::/azahar >/dev/null 2>&1; then
    for f in libazahar-nano-core.so libhook_impl.so libmain_hook.so \
             libfile_redirect_hook.so libgsl_alloc_hook.so; do
        mdel -i "$OUT@@$P3" "::/azahar/$f" >/dev/null 2>&1 || true
    done
    mrd -i "$OUT@@$P3" ::/azahar >/dev/null 2>&1 || true
    echo "  已删"
fi
mdir -i "$OUT@@$P3" ::/ 2>/dev/null | tail -2

echo "== 回读校验"
T2=$(mktemp -d)
for f in $CORE_FILES; do
    debugfs -R "dump /azahar/$f $T2/$f" "$OUT?offset=$OFF5" 2>/dev/null
    a=$(md5sum "$T2/$f" 2>/dev/null | cut -d' ' -f1); b=$(md5sum "$STAGE/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "  OK   $f" || { echo "  FAIL $f"; exit 1; }
done
rm -rf "$T2"

echo "== 分区表"
sgdisk -p "$OUT" | tail -11
