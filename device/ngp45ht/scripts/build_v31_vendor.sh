#!/bin/bash
# build_v31_vendor.sh — v31：把今天的三个改动塞进 v30 的 /vendor（p5）。
#
# 用法: bash build_v31_vendor.sh <v30.img> <v31.img>
#
# 写入的东西：
#   /bin/ngp-fixup.sh          替换（502 行版，多了 azahar 汉化的 bind + 配置段名迁移）
#   /bin/azahar-nano-zh        新增（3DS 前端汉化版，546,624 B）
#   /bin/ngp-romguard.sh       新增（TF2 -> ROMs bind 常驻守护）
#   /etc/init/ngp-romguard.rc  新增（上面那个服务的 init 定义）
#
# 为什么都放 vendor：/system 是块设备级只读（p4），vendor（p5）是 ext4 rw，
# 而且这四个文件都是 root 自己用的脚本，不需要进 system。
#
# SELinux：debugfs 新建的 inode 没有 security.selinux，挂载后是 unlabeled。
# 本机是 permissive 跑得起来，但刷到别人的机器上就是隐患，统一按 vendor_file:s0
# 补（值必须 NUL 结尾，26 字节；用 ea_set -f 文件，不能写进命令行）。
set -euo pipefail

IN="${1:?用法: $0 <v30.img> <v31.img>}"
OUT="${2:?用法: $0 <v30.img> <v31.img>}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$DEV/../../.." && pwd)

FIXUP="$DEV/ime/ngp-fixup.sh"
# 汉化前端优先用仓库里的（azahar/azahar-nano-zh），没有就退回本地构建目录
AZH="$DEV/azahar/azahar-nano-zh"
[ -f "$AZH" ] || AZH="$ROOT/azahar-zh/azahar-nano.zh"
GUARD="$DEV/scripts/ngp-romguard.sh"
GUARDRC="$DEV/scripts/ngp-romguard.rc"

for f in "$FIXUP" "$AZH" "$GUARD" "$GUARDRC"; do
    [ -f "$f" ] || { echo "缺文件: $f" >&2; exit 1; }
done

[ "$IN" != "$OUT" ] || { echo "输入输出不能同名" >&2; exit 1; }
[ -f "$OUT" ] && { echo "输出已存在，先删掉: $OUT" >&2; exit 1; }

echo "== 复制镜像（sparse）"
cp --sparse=always "$IN" "$OUT"

echo "== 定位 p5(vendor) 偏移"
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

dbg5() { debugfs -w -R "$1" "$OUT?offset=$OFF5" >/dev/null 2>&1 || true; }

echo "== 剩余空间（写之前）"
debugfs -R "stat <2>" "$OUT?offset=$OFF5" 2>/dev/null | grep -i 'free blocks' || true

echo "== 写 /bin/ngp-fixup.sh"
dbg5 "rm /bin/ngp-fixup.sh"
dbg5 "write $FIXUP /bin/ngp-fixup.sh"
dbg5 "sif /bin/ngp-fixup.sh mode 0100755"
dbg5 "sif /bin/ngp-fixup.sh uid 0"

echo "== 写 /bin/azahar-nano-zh"
dbg5 "rm /bin/azahar-nano-zh"
dbg5 "write $AZH /bin/azahar-nano-zh"
dbg5 "sif /bin/azahar-nano-zh mode 0100755"
dbg5 "sif /bin/azahar-nano-zh uid 0"

echo "== 写 /bin/ngp-romguard.sh"
dbg5 "rm /bin/ngp-romguard.sh"
dbg5 "write $GUARD /bin/ngp-romguard.sh"
dbg5 "sif /bin/ngp-romguard.sh mode 0100755"
dbg5 "sif /bin/ngp-romguard.sh uid 0"

echo "== 写 /etc/init/ngp-romguard.rc"
dbg5 "rm /etc/init/ngp-romguard.rc"
dbg5 "write $GUARDRC /etc/init/ngp-romguard.rc"
dbg5 "sif /etc/init/ngp-romguard.rc mode 0100644"
dbg5 "sif /etc/init/ngp-romguard.rc uid 0"

echo "== SELinux 标签（vendor_file:s0，NUL 结尾）"
VALV=$(mktemp)
printf 'u:object_r:vendor_file:s0\0' > "$VALV"
TAGS=$(mktemp)
for p in /bin/ngp-fixup.sh /bin/azahar-nano-zh /bin/ngp-romguard.sh /etc/init/ngp-romguard.rc; do
    echo "ea_rm $p security.selinux" >> "$TAGS"
    echo "ea_set -f $VALV $p security.selinux" >> "$TAGS"
done
debugfs -w -f "$TAGS" "$OUT?offset=$OFF5" >/dev/null 2>&1 || true

echo "== 标签回查"
for p in /bin/ngp-fixup.sh /bin/azahar-nano-zh /bin/ngp-romguard.sh /etc/init/ngp-romguard.rc; do
    printf '  %-34s ' "$p"
    debugfs -R "ea_list $p" "$OUT?offset=$OFF5" 2>/dev/null | grep -o 'vendor_file:s0\\000' || echo "MISSING"
done

echo "== 回读校验（md5 三对照）"
T=$(mktemp -d)
trap 'rm -rf "$T" "$VALV" "$TAGS"' EXIT
rc=0
check() {
    local path="$1" src="$2" name="$3"
    debugfs -R "dump $path $T/$name" "$OUT?offset=$OFF5" >/dev/null 2>&1
    if [ ! -f "$T/$name" ]; then echo "  FAIL $name 回读失败"; rc=1; return; fi
    local a b
    a=$(md5sum "$T/$name" | cut -d' ' -f1)
    b=$(md5sum "$src" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "  OK   $name  $a"; else echo "  FAIL $name  $a != $b"; rc=1; fi
}
check /bin/ngp-fixup.sh          "$FIXUP"   ngp-fixup.sh
check /bin/azahar-nano-zh        "$AZH"     azahar-nano-zh
check /bin/ngp-romguard.sh       "$GUARD"   ngp-romguard.sh
check /etc/init/ngp-romguard.rc  "$GUARDRC" ngp-romguard.rc

echo "== e2fsck 校验"
e2fsck -fn "$OUT?offset=$OFF5" 2>&1 | tail -3

echo "== 剩余空间（写之后）"
debugfs -R "stat <2>" "$OUT?offset=$OFF5" 2>/dev/null | grep -i 'free blocks' || true

if [ $rc -ne 0 ]; then echo "!!! 有文件校验失败" >&2; exit 1; fi
echo "== 完成: $OUT"
