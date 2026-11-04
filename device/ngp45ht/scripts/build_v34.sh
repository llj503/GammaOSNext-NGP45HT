#!/bin/bash
# build_v34.sh — v34：把摇杆灯修复真正固化进镜像。
#
# 用法: bash build_v34.sh <v33.img> <v34.img>
#
# 背景（为什么 v33 刷完摇杆灯还是调不动）
# ─────────────────────────────────────────────────────────────
# v33 修了 DTB 的 SPI0、写了 ngp-stickled.sh / ws2812-common / .rc，
# 但 build_v33.sh 的 vendor 写入清单里 **漏掉了 stickled/ 目录**，
# 所以设备 /vendor/bin/ 下只有 ngp-powerled.sh，没有 ws2812-common
# 和 ngp-stickled.sh，服务起不来。同时 v33 镜像里的 ngp-fixup.sh
# 也是打 ⑩a 补丁之前的旧版。
#
# 这一版只补这一件事，相对 v33 改动全在 p5 vendor 内：
#
#   /bin/ws2812-common          新增（WS2812 SPI 帧生成器，C 源码同目录）
#   /bin/ngp-stickled.sh        新增（读 persist.gammaos.rgb.* → 推帧）
#   /etc/init/ngp-stickled.rc   新增（init 服务，boot_completed 后启动）
#   /bin/ngp-fixup.sh           替换（补上 ⑩a 摇杆灯自检段）
#
# 不动 p3（内核与 DTB），不动 system。所以刷机后 DTB 保持 v33 的。
#
# 输出后用 4 MiB 分块比对新旧镜像，确认差异块全部落在 p5 内。

set -euo pipefail

IN="${1:?用法: $0 <v33.img> <v34.img>}"
OUT="${2:?用法: $0 <v33.img> <v34.img>}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)

FIXUP="$DEV/ime/ngp-fixup.sh"
SWSH="$DEV/stickled/ngp-stickled.sh"
SWBIN="$DEV/stickled/ws2812-common"
SWRC="$DEV/stickled/ngp-stickled.rc"

for f in "$FIXUP" "$SWSH" "$SWBIN" "$SWRC"; do
    [ -f "$f" ] || { echo "缺文件: $f" >&2; exit 1; }
done
[ -x "$SWBIN" ] || { echo "ws2812-common 没有可执行权限" >&2; exit 1; }

[ "$IN" != "$OUT" ] || { echo "输入输出不能同名" >&2; exit 1; }
[ -f "$OUT" ] && { echo "输出已存在，先删掉: $OUT" >&2; exit 1; }

echo "== 复制镜像（sparse）"
cp --sparse=always "$IN" "$OUT"

# ── GPT 解析：按分区名取 offset/size，不硬编码 ────────────────────
read -r OFF5 SIZE5 <<EOF
$(python3 - "$OUT" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb'); f.seek(512); h = f.read(92)
plba = struct.unpack_from('<Q', h, 72)[0]
num  = struct.unpack_from('<I', h, 80)[0]
esz  = struct.unpack_from('<I', h, 84)[0]
f.seek(plba * 512); data = f.read(num * esz)
for i in range(num):
    e = data[i*esz:(i+1)*esz]
    if e[:16] == b'\x00'*16:
        continue
    name = e[56:128].decode('utf-16-le').rstrip('\x00')
    if name == 'vendor':
        first = struct.unpack_from('<Q', e, 32)[0] * 512
        last  = struct.unpack_from('<Q', e, 40)[0] * 512
        print(first, last + 512 - first)
        break
else:
    sys.exit("找不到 vendor 分区")
PY
)
EOF
echo "   vendor offset=$OFF5 size=$SIZE5"

IMGV="$OUT?offset=$OFF5"
dbg() { debugfs -w -R "$1" "$IMGV" >/dev/null 2>&1 || true; }

echo "== [p5] 写入 vendor"
echo "   剩余空间（写之前）"
debugfs -R "stats" "$IMGV" 2>/dev/null | grep -iE "^Free blocks" || true

write() {  # write <本地文件> <镜像内路径> <mode>
    dbg "rm $2"
    dbg "write $1 $2"
    dbg "sif $2 mode $3"
    dbg "sif $2 uid 0"
    dbg "sif $2 gid 0"
}

write "$SWBIN"  /bin/ws2812-common        0100755
write "$SWSH"   /bin/ngp-stickled.sh      0100755
write "$SWRC"   /etc/init/ngp-stickled.rc 0100644
write "$FIXUP"  /bin/ngp-fixup.sh         0100755

echo "   SELinux 标签"
VALB=$(mktemp); printf 'u:object_r:vendor_file:s0\0' > "$VALB"
VALC=$(mktemp); printf 'u:object_r:vendor_configs_file:s0\0' > "$VALC"
TAGS=$(mktemp)
for p in /bin/ws2812-common /bin/ngp-stickled.sh /bin/ngp-fixup.sh; do
    echo "ea_rm $p security.selinux" >> "$TAGS"
    echo "ea_set -f $VALB $p security.selinux" >> "$TAGS"
done
echo "ea_rm /etc/init/ngp-stickled.rc security.selinux" >> "$TAGS"
echo "ea_set -f $VALC /etc/init/ngp-stickled.rc security.selinux" >> "$TAGS"
debugfs -w -f "$TAGS" "$IMGV" >/dev/null 2>&1 || true
rm -f "$VALB" "$VALC" "$TAGS"

echo "   标签回查"
for p in /bin/ws2812-common /bin/ngp-stickled.sh /bin/ngp-fixup.sh \
         /etc/init/ngp-stickled.rc; do
    printf '     %-38s ' "$p"
    debugfs -R "ea_list $p" "$IMGV" 2>/dev/null \
        | grep -oE 'vendor_(configs)?_?file:s0\\000' || echo "MISSING"
done

# ══════════════════════════════════════════════════════════════════
# 回读校验
# ══════════════════════════════════════════════════════════════════
echo "== 回读校验"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
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
check /bin/ws2812-common        "$SWBIN" ws2812-common
check /bin/ngp-stickled.sh      "$SWSH"  ngp-stickled.sh
check /etc/init/ngp-stickled.rc "$SWRC"  ngp-stickled.rc
check /bin/ngp-fixup.sh         "$FIXUP" ngp-fixup.sh

echo "   可执行位回查"
for p in /bin/ws2812-common /bin/ngp-stickled.sh /bin/ngp-fixup.sh; do
    printf '     %-32s ' "$p"
    debugfs -R "stat $p" "$IMGV" 2>/dev/null | grep -oE "Mode: *[0-7]+" | head -1 || echo "?"
done

echo "== e2fsck (vendor)"
e2fsck -fn "$IMGV" 2>&1 | tail -3

echo "   剩余空间（写之后）"
debugfs -R "stats" "$IMGV" 2>/dev/null | grep -iE "^Free blocks" || true

if [ $rc -ne 0 ]; then echo "!!! 有文件校验失败" >&2; exit 1; fi

# ══════════════════════════════════════════════════════════════════
# 4 MiB 分块比对：差异必须全部落在 vendor 内
# ══════════════════════════════════════════════════════════════════
echo "== 4 MiB 分块比对（v33 vs v34）"
python3 - "$IN" "$OUT" "$OFF5" "$SIZE5" <<'PY'
import sys
a, b, off, size = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
BLK = 4 * 1024 * 1024
end_v = off + size
diff_in = diff_out = 0
with open(a, 'rb') as fa, open(b, 'rb') as fb:
    pos = 0
    while True:
        x = fa.read(BLK); y = fb.read(BLK)
        if not x and not y: break
        if x != y:
            if off <= pos and pos + len(y) <= end_v:
                diff_in += 1
            else:
                diff_out += 1
                print(f'  !! 差异块在 vendor 外: offset={pos} (0x{pos:x})')
        pos += BLK
print(f'  差异块总数: vendor 内 {diff_in}，vendor 外 {diff_out}')
sys.exit(1 if diff_out else 0)
PY
cmp_rc=$?
if [ $cmp_rc -ne 0 ]; then echo "!!! 有差异落在 vendor 之外" >&2; exit 1; fi

echo "== 完成: $OUT"
ls -la "$OUT"
md5sum "$OUT"
