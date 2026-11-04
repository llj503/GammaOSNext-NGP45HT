#!/bin/bash
# build_v35.sh — v35：电量显示改用 OCV 查表 + 按键映射固化。
#
# 用法: bash build_v35.sh <v34.img> <v35.img>
#
# 相对 v34 改两个分区：
#
#   p3 dArkOS_Fat（启动分区）
#     /Image                    替换（rk817_battery.c 改 SoC 主来源为 OCV）
#     /rk3562-ngp45ht.dtb       替换（21 点 OCV 表换成 4.35V 曲线）
#
#   p5 vendor（/vendor）
#     /usr/keylayout/adc-keys-ngp.kl   新增（M=HOME / 音量键对调）
#     /usr/keylayout/adc-keys.kl       删除（文件名对不上设备名，从来没生效过）
#
# 为什么改这两处，见 doc/ngp45ht/v35-CHANGES.md。
# 一句话：
#   1) rk817 的 SoC 原来算的是 remain_cap/fcc（硬件 fuel gauge 的学习值），
#      掌机常年浅充浅放导致学习值漂移，实测 4.28V 只报 64~74%，且完全不看
#      电压 —— 改 OCV 表/内阻补偿都影响不到它，只能换主路径。
#   2) InputManager 按「设备名」找 .kl，本机设备名是 adc-keys-ngp，
#      而镜像里那个文件叫 adc-keys.kl，所以过去的按键修正全是空转。
#
# 输出后用 4 MiB 分块比对新旧镜像，确认差异只落在 p3/p5。

set -euo pipefail

IN="${1:?用法: $0 <v34.img> <v35.img>}"
OUT="${2:?用法: $0 <v34.img> <v35.img>}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)

KERNEL_IMAGE="${KERNEL_IMAGE:-/home/liang/gammaos-ngp45ht/kernel/arch/arm64/boot/Image}"
KERNEL_DTB="${KERNEL_DTB:-/home/liang/gammaos-ngp45ht/kernel/arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb}"
KEYLAYOUT="$DEV/keylayout/adc-keys-ngp.kl"

for f in "$KERNEL_IMAGE" "$KERNEL_DTB" "$KEYLAYOUT"; do
    [ -f "$f" ] || { echo "缺文件: $f" >&2; exit 1; }
done

[ "$IN" != "$OUT" ] || { echo "输入输出不能同名" >&2; exit 1; }
[ -f "$OUT" ] && { echo "输出已存在，先删掉: $OUT" >&2; exit 1; }

echo "== 复制镜像（sparse）"
cp --sparse=always "$IN" "$OUT"

# ── GPT 解析：按分区名取 offset/size ──────────────────────────────
read -r OFF3 OFF5 SIZE3 SIZE5 <<EOF
$(python3 - "$OUT" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb'); f.seek(512); h = f.read(92)
plba = struct.unpack_from('<Q', h, 72)[0]
num  = struct.unpack_from('<I', h, 80)[0]
esz  = struct.unpack_from('<I', h, 84)[0]
f.seek(plba * 512); data = f.read(num * esz)
found = {}
for i in range(num):
    e = data[i*esz:(i+1)*esz]
    if e[:16] == b'\x00'*16:
        continue
    name = e[56:128].decode('utf-16-le').rstrip('\x00')
    first = struct.unpack_from('<Q', e, 32)[0] * 512
    last  = struct.unpack_from('<Q', e, 40)[0] * 512
    found[name] = (first, last + 512 - first)
for n in ('dArkOS_Fat', 'vendor'):
    if n not in found:
        sys.exit(f"找不到分区 {n}")
(f3, s3) = found['dArkOS_Fat']
(f5, s5) = found['vendor']
print(f3, f5, s3, s5)
PY
)
EOF
echo "   dArkOS_Fat offset=$OFF3 size=$SIZE3"
echo "   vendor     offset=$OFF5 size=$SIZE5"

# ══════════════════════════════════════════════════════════════════
# 1) p3 dArkOS_Fat —— 内核与 DTB
# ══════════════════════════════════════════════════════════════════
echo "== [p3] 更新 FAT 里的 Image / DTB"

MTOOLSRC=$(mktemp)
export MTOOLSRC
cat > "$MTOOLSRC" <<EOF
drive z: file="$OUT" offset=$OFF3
mtools_skip_check=1
EOF

echo "   --- 原内容 ---"
mdir z:/ 2>/dev/null | grep -E "Image|dtb" || true

mdel z:/Image.bak-v35 2>/dev/null || true
mcopy -n z:/Image z:/Image.bak-v35 2>/dev/null || true
mdel z:/rk3562-ngp45ht.dtb.bak-v35 2>/dev/null || true
mcopy -n z:/rk3562-ngp45ht.dtb z:/rk3562-ngp45ht.dtb.bak-v35 2>/dev/null || true

mcopy -o "$KERNEL_IMAGE" z:/Image
mcopy -o "$KERNEL_DTB"   z:/rk3562-ngp45ht.dtb

echo "   --- 新内容 ---"
mdir z:/ 2>/dev/null | grep -E "Image|dtb" || true

# ══════════════════════════════════════════════════════════════════
# 2) p5 vendor —— keylayout
# ══════════════════════════════════════════════════════════════════
echo "== [p5] 写入 vendor keylayout"
IMGV="$OUT?offset=$OFF5"
dbg() { debugfs -w -R "$1" "$IMGV" >/dev/null 2>&1 || true; }

echo "   剩余空间（写之前）"
debugfs -R "stats" "$IMGV" 2>/dev/null | grep -iE "^Free blocks" || true

dbg "mkdir /usr"
dbg "mkdir /usr/keylayout"

write() {  # write <本地文件> <镜像内路径> <mode>
    dbg "rm $2"
    dbg "write $1 $2"
    dbg "sif $2 mode $3"
    dbg "sif $2 uid 0"
    dbg "sif $2 gid 0"
}

write "$KEYLAYOUT" /usr/keylayout/adc-keys-ngp.kl 0100644

# 删掉那个文件名对不上、从未被加载过的旧文件
echo "   删除无效的 adc-keys.kl"
dbg "rm /usr/keylayout/adc-keys.kl"

echo "   SELinux 标签"
VALK=$(mktemp); printf 'u:object_r:vendor_keylayout_file:s0\0' > "$VALK"
TAGS=$(mktemp)
echo "ea_rm /usr/keylayout/adc-keys-ngp.kl security.selinux" >> "$TAGS"
echo "ea_set -f $VALK /usr/keylayout/adc-keys-ngp.kl security.selinux" >> "$TAGS"
debugfs -w -f "$TAGS" "$IMGV" >/dev/null 2>&1 || true
rm -f "$VALK" "$TAGS"

echo "   标签回查"
printf '     %-42s ' "/usr/keylayout/adc-keys-ngp.kl"
debugfs -R "ea_list /usr/keylayout/adc-keys-ngp.kl" "$IMGV" 2>/dev/null \
    | grep -oE 'vendor_keylayout_file:s0\\000' || echo "MISSING"

echo "   确认 adc-keys.kl 已不存在"
if debugfs -R "stat /usr/keylayout/adc-keys.kl" "$IMGV" 2>/dev/null | grep -q "Inode:"; then
    echo "     FAIL 仍然存在"
else
    echo "     OK  已删除"
fi

# ══════════════════════════════════════════════════════════════════
# 3) 回读校验
# ══════════════════════════════════════════════════════════════════
echo "== 回读校验"
T=$(mktemp -d)
trap 'rm -rf "$T"; rm -f "$MTOOLSRC"' EXIT
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
check /usr/keylayout/adc-keys-ngp.kl "$KEYLAYOUT" adc-keys-ngp.kl

echo "   FAT 侧回读"
mcopy -o z:/Image "$T/Image.chk" 2>/dev/null || rc=1
mcopy -o z:/rk3562-ngp45ht.dtb "$T/dtb.chk" 2>/dev/null || rc=1
for pair in "Image.chk:$KERNEL_IMAGE" "dtb.chk:$KERNEL_DTB"; do
    n=${pair%%:*}; s=${pair#*:}
    if [ -f "$T/$n" ]; then
        a=$(md5sum "$T/$n" | cut -d' ' -f1); b=$(md5sum "$s" | cut -d' ' -f1)
        if [ "$a" = "$b" ]; then echo "  OK   $n  $a"; else echo "  FAIL $n $a != $b"; rc=1; fi
    else
        echo "  FAIL $n 回读失败"; rc=1
    fi
done

echo "== e2fsck (vendor)"
e2fsck -fn "$IMGV" 2>&1 | tail -3

echo "   剩余空间（写之后）"
debugfs -R "stats" "$IMGV" 2>/dev/null | grep -iE "^Free blocks" || true

if [ $rc -ne 0 ]; then echo "!!! 有文件校验失败" >&2; exit 1; fi

# ══════════════════════════════════════════════════════════════════
# 4) 4 MiB 分块比对
# ══════════════════════════════════════════════════════════════════
echo "== 4 MiB 分块比对（v34 vs v35）"
python3 - "$IN" "$OUT" "$OFF3" "$SIZE3" "$OFF5" "$SIZE5" <<'PY'
import sys
a, b = sys.argv[1], sys.argv[2]
o3, s3, o5, s5 = (int(x) for x in sys.argv[3:7])
BLK = 4 * 1024 * 1024
r3 = (o3, o3 + s3)
r5 = (o5, o5 + s5)
diff_in3 = diff_in5 = diff_out = 0
with open(a, 'rb') as fa, open(b, 'rb') as fb:
    pos = 0
    while True:
        x = fa.read(BLK); y = fb.read(BLK)
        if not x and not y:
            break
        if x != y:
            end = pos + len(y)
            if r3[0] <= pos and end <= r3[1]:
                diff_in3 += 1
            elif r5[0] <= pos and end <= r5[1]:
                diff_in5 += 1
            else:
                diff_out += 1
                print(f'  !! 差异块在目标分区外: offset={pos} (0x{pos:x})')
        pos += BLK
print(f'  差异块: dArkOS_Fat 内 {diff_in3}，vendor 内 {diff_in5}，分区外 {diff_out}')
sys.exit(1 if diff_out else 0)
PY
if [ $? -ne 0 ]; then echo "!!! 有差异落在目标分区之外" >&2; exit 1; fi

echo "== 完成: $OUT"
ls -la "$OUT"
md5sum "$OUT"
