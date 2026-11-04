#!/bin/bash
# build_v33.sh — v33：摇杆灯 + 电源状态灯 + 电量与按键语义修正 + 摇杆灯设置汉化。
#
# 用法: bash build_v33.sh <v32.img> <v33.img>
#
# 这一版相对 v32 改了三个分区：
#
#   p3 dArkOS_Fat（启动分区，extlinux 从这里读内核与 DTB）
#     /Image                      替换（内核：rk817 充电器 usb_in 初始化修复）
#     /rk3562-ngp45ht.dtb         替换（SPI0 摇杆灯 + gpio-leds 状态灯 + 按键修正）
#
#   p5 vendor（/vendor）
#     /bin/ngp-fixup.sh           替换（新增第 ⑩ 段：摇杆灯设置 apk 汉化 bind）
#     /bin/ngp-navkey.sh          替换（返回键长按退出游戏）
#     /etc/init/ngp-navkey.rc     替换
#     /bin/ngp-powerled.sh        新增（状态灯守护：充电红灯 / 充满蓝灯 / 拔线全灭）
#     /etc/init/ngp-powerled.rc   新增
#     /etc/ngp/JoystickLedPicker-zh.apk  新增（摇杆灯设置中文版，开机 bind 覆盖）
#
# 为什么灯要动 DTB + 加守护进程，见 powerled/ngp-powerled.sh 顶部注释。
# 一句话：红/蓝两颗灯挂在 GPIO3_C2/C1，rk817 芯片和驱动都不管这两根脚，
# 必须由 DTS 交给 leds-gpio 注册成 /sys/class/leds/charge-*，再由用户态点。
#
# FAT 分区的写法与 vendor 不同：vendor 是 ext4 用 debugfs，FAT 用 mtools
# 直接操作分区镜像（不挂载，避免 FAT 驱动行为和真实设备不一致）。
#
# 输出后用 4 MiB 分块比对新旧镜像，确认差异只落在 p3/p5 内。

set -euo pipefail

IN="${1:?用法: $0 <v32.img> <v33.img>}"
OUT="${2:?用法: $0 <v32.img> <v33.img>}"
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(cd "$HERE/.." && pwd)

KERNEL_IMAGE="${KERNEL_IMAGE:-/home/liang/gammaos-ngp45ht/kernel/arch/arm64/boot/Image}"
KERNEL_DTB="${KERNEL_DTB:-/home/liang/gammaos-ngp45ht/kernel/arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb}"

FIXUP="$DEV/ime/ngp-fixup.sh"
NAVKEY="$DEV/scripts/ngp-navkey.sh"
NAVRC="$DEV/scripts/ngp-navkey.rc"
PLED="$DEV/powerled/ngp-powerled.sh"
PLRC="$DEV/powerled/ngp-powerled.rc"
LEDAPK="$DEV/apps/JoystickLedPicker-zh.apk"

for f in "$KERNEL_IMAGE" "$KERNEL_DTB" "$FIXUP" "$NAVKEY" "$NAVRC" "$PLED" "$PLRC" "$LEDAPK"; do
    [ -f "$f" ] || { echo "缺文件: $f" >&2; exit 1; }
done

[ "$IN" != "$OUT" ] || { echo "输入输出不能同名" >&2; exit 1; }
[ -f "$OUT" ] && { echo "输出已存在，先删掉: $OUT" >&2; exit 1; }

echo "== 复制镜像（sparse）"
cp --sparse=always "$IN" "$OUT"

# ── GPT 解析：按分区名取 offset/size，不硬编码 ────────────────────
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
( f3, s3 ) = found['dArkOS_Fat']
( f5, s5 ) = found['vendor']
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

# mtools 直接操作"文件里的一段"：用 offset 指到分区起点。
# 不用 @@offset 语法（那个会连带把整个文件当 FAT 解析，越界）。
MTOOLSRC=$(mktemp)
export MTOOLSRC
cat > "$MTOOLSRC" <<EOF
drive z: file="$OUT" offset=$OFF3
mtools_skip_check=1
EOF

echo "   --- 原内容 ---"
mdir z:/ 2>/dev/null | grep -E "Image|dtb" || true

# 先把原版备份成 .bak-v34（从旧镜像里 copy，重复构建时先删旧的）
mdel z:/Image.bak-v34 2>/dev/null || true
mcopy -n z:/Image z:/Image.bak-v34 2>/dev/null || true
mdel z:/rk3562-ngp45ht.dtb.bak-v34 2>/dev/null || true
mcopy -n z:/rk3562-ngp45ht.dtb z:/rk3562-ngp45ht.dtb.bak-v34 2>/dev/null || true

mcopy -o "$KERNEL_IMAGE" z:/Image
mcopy -o "$KERNEL_DTB"   z:/rk3562-ngp45ht.dtb

echo "   --- 新内容 ---"
mdir z:/ 2>/dev/null | grep -E "Image|dtb" || true

# ══════════════════════════════════════════════════════════════════
# 2) p5 vendor —— 脚本、服务、汉化 apk
# ══════════════════════════════════════════════════════════════════
echo "== [p5] 写入 vendor"
IMGV="$OUT?offset=$OFF5"
dbg() { debugfs -w -R "$1" "$IMGV" >/dev/null 2>&1 || true; }

echo "   剩余空间（写之前）"
debugfs -R "stats" "$IMGV" 2>/dev/null | grep -iE "^Free blocks" || true

dbg "mkdir /etc/ngp"

write() {  # write <本地文件> <镜像内路径> <mode>
    dbg "rm $2"
    dbg "write $1 $2"
    dbg "sif $2 mode $3"
    dbg "sif $2 uid 0"
    dbg "sif $2 gid 0"
}
write "$FIXUP"  /bin/ngp-fixup.sh          0100755
write "$NAVKEY" /bin/ngp-navkey.sh         0100755
write "$NAVRC"  /etc/init/ngp-navkey.rc    0100644
write "$PLED"   /bin/ngp-powerled.sh       0100755
write "$PLRC"   /etc/init/ngp-powerled.rc  0100644
write "$LEDAPK" /etc/ngp/JoystickLedPicker-zh.apk 0100644

echo "   SELinux 标签"
VALB=$(mktemp); printf 'u:object_r:vendor_file:s0\0' > "$VALB"
VALC=$(mktemp); printf 'u:object_r:vendor_configs_file:s0\0' > "$VALC"
TAGS=$(mktemp)
for p in /bin/ngp-fixup.sh /bin/ngp-navkey.sh /bin/ngp-powerled.sh; do
    echo "ea_rm $p security.selinux" >> "$TAGS"
    echo "ea_set -f $VALB $p security.selinux" >> "$TAGS"
done
for p in /etc/init/ngp-navkey.rc /etc/init/ngp-powerled.rc /etc/ngp/JoystickLedPicker-zh.apk; do
    echo "ea_rm $p security.selinux" >> "$TAGS"
    echo "ea_set -f $VALC $p security.selinux" >> "$TAGS"
done
debugfs -w -f "$TAGS" "$IMGV" >/dev/null 2>&1 || true
rm -f "$VALB" "$VALC" "$TAGS"

echo "   标签回查"
for p in /bin/ngp-fixup.sh /bin/ngp-navkey.sh /bin/ngp-powerled.sh \
         /etc/init/ngp-navkey.rc /etc/init/ngp-powerled.rc \
         /etc/ngp/JoystickLedPicker-zh.apk; do
    printf '     %-42s ' "$p"
    debugfs -R "ea_list $p" "$IMGV" 2>/dev/null | grep -oE 'vendor_(configs)?_?file:s0\\000' || echo "MISSING"
done

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
check /bin/ngp-fixup.sh        "$FIXUP"  ngp-fixup.sh
check /bin/ngp-navkey.sh       "$NAVKEY" ngp-navkey.sh
check /etc/init/ngp-navkey.rc  "$NAVRC"  ngp-navkey.rc
check /bin/ngp-powerled.sh     "$PLED"   ngp-powerled.sh
check /etc/init/ngp-powerled.rc "$PLRC"  ngp-powerled.rc
check /etc/ngp/JoystickLedPicker-zh.apk "$LEDAPK" JoystickLedPicker-zh.apk

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
echo "== 完成: $OUT"
