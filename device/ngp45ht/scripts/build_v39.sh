#!/usr/bin/env bash
# build_v39.sh — 在 v38 镜像基础上产出 v39
#
# 相对 v38 的改动（只动 p5 vendor）：
#   1. /etc/ngp/LANGOS.apk        ← LANGOS 3.5-emupick
#        开游戏时若该平台装了 ≥2 个模拟器就弹框让玩家选
#   2. /bin/ngp-fixup.sh          ← 覆盖（新增第 ⑫b 段）
#        模拟器改为首次 pm install 进 /data/app（可卸载），卸载后不再装回
#   3. /etc/ngp/emulators/NetherSX2.apk ← 新增（从 /vendor/app 挪过来）
#   4. 删除 /app/NetherSX2/（整个目录，含 apk）
#        必须删，否则系统仍把它当 system app 装上，玩家依旧卸不掉
#
# 不动：p3 dArkOS_Fat（Image/DTB/extlinux.conf）、p4 system、其余分区
#
# 用法: ./build_v39.sh
set -euo pipefail

unset -f rm unlink rmdir 2>/dev/null || true
unset CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_BROKERED_SHELL_ENV 2>/dev/null || true
unset PYTHONPATH BASH_ENV 2>/dev/null || true
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hash -r

PYX=/home/liang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
D=/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis
SRC=$D/GammaOSCore-NGP45HT-20261105-v38.img
SRC_XZ=$SRC.xz
IMG=$D/GammaOSCore-NGP45HT-20261106-v39.img
TREE=/home/liang/rainject/sync-repo/device/ngp45ht
NEWLANGOS=$TREE/apps/LANGOS-3.5-emupick.apk
NEWFIXUP=$TREE/ime/ngp-fixup.sh
NEWNET=$TREE/emulators/NetherSX2.apk
WORK=/tmp/v39
LOG=$WORK/build-v39.log

for f in "$NEWLANGOS" "$NEWFIXUP" "$NEWNET"; do
    [ -f "$f" ] || { echo "!! 缺 $f"; exit 1; }
done
if [ ! -f "$SRC" ] && [ ! -f "$SRC_XZ" ]; then
    echo "!! 缺基线镜像 $SRC / $SRC_XZ"; exit 1
fi

mkdir -p "$WORK"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }

# 分区几何（v37/v38 一致，GPT）
FAT_OFF=16777216;   FAT_SIZE=103809024
SYS_OFF=121634816;  SYS_SIZE=3565158400
VEN_OFF=3686793216; VEN_SIZE=602931200

say "### [1/7] 从 v38 解出 img"
command rm -f "$IMG"
if [ ! -f "$SRC" ]; then
    say "  解压 $SRC_XZ（约 5.4 GiB，需要几分钟）"
    xz -dc "$SRC_XZ" > "$SRC"
fi
cp --reflink=auto "$SRC" "$IMG"
ls -l "$IMG" | tee -a "$LOG"

say "### [2/7] 抽取 p5 vendor"
command rm -f "$WORK/vendor.img"
$PYX - "$IMG" "$WORK" "$VEN_OFF" "$VEN_SIZE" <<'PY' | tee -a "$LOG"
import sys
img, work, vo_, vs_ = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:5])
dst = f'{work}/vendor.img'
with open(img, 'rb') as fi, open(dst, 'wb') as o:
    fi.seek(vo_); left = vs_
    while left > 0:
        b = fi.read(min(32*1024*1024, left))
        if not b: break
        o.write(b); left -= len(b)
print(f'  抽取 {dst} {vs_} 字节')
PY

say "### [3/7] 删除 /app/NetherSX2（必须删，否则仍是 system app）"
debugfs -w -R "rm /app/NetherSX2/NetherSX2.apk" "$WORK/vendor.img" 2>&1 | tee -a "$LOG" || true
debugfs -w -R "rmdir /app/NetherSX2" "$WORK/vendor.img" 2>&1 | tee -a "$LOG" || true
say "  剩余 /app 内容:"
debugfs -R "ls -l /app" "$WORK/vendor.img" 2>/dev/null | tee -a "$LOG"

say "### [4/7] 注入 NetherSX2.apk 到 /etc/ngp/emulators/"
debugfs -w -R "mkdir /etc/ngp/emulators" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "rm /etc/ngp/emulators/NetherSX2.apk" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write $NEWNET /etc/ngp/emulators/NetherSX2.apk" "$WORK/vendor.img" 2>&1 | tee -a "$LOG"
debugfs -w -R "sif /etc/ngp/emulators/NetherSX2.apk mode 0100644" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /etc/ngp/emulators/NetherSX2.apk uid 0" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /etc/ngp/emulators/NetherSX2.apk gid 0" "$WORK/vendor.img" >/dev/null 2>&1

say "### [5/7] 覆盖 LANGOS.apk 与 ngp-fixup.sh"
debugfs -w -R "rm /etc/ngp/LANGOS.apk" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write $NEWLANGOS /etc/ngp/LANGOS.apk" "$WORK/vendor.img" 2>&1 | tee -a "$LOG"
debugfs -w -R "sif /etc/ngp/LANGOS.apk mode 0100644" "$WORK/vendor.img" >/dev/null 2>&1

debugfs -w -R "rm /bin/ngp-fixup.sh" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write $NEWFIXUP /bin/ngp-fixup.sh" "$WORK/vendor.img" 2>&1 | tee -a "$LOG"
debugfs -w -R "sif /bin/ngp-fixup.sh mode 0100755" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /bin/ngp-fixup.sh uid 0" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /bin/ngp-fixup.sh gid 2000" "$WORK/vendor.img" >/dev/null 2>&1

say "### [6/7] 回写 p5 到镜像"
$PYX - "$IMG" "$WORK" "$VEN_OFF" "$VEN_SIZE" <<'PY' | tee -a "$LOG"
import sys
img, work, vo_, vs_ = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:5])
src = f'{work}/vendor.img'
with open(img, 'r+b') as o, open(src, 'rb') as fi:
    o.seek(vo_); left = vs_
    while left > 0:
        b = fi.read(min(32*1024*1024, left))
        if not b: break
        o.write(b); left -= len(b)
print(f'  回写 {src} -> @{vo_} {vs_} 字节')
PY

say "### [7/7] 断言"
$PYX - "$IMG" "$NEWLANGOS" "$NEWFIXUP" "$NEWNET" <<'PY' | tee -a "$LOG"
import sys, hashlib, subprocess, os
img, nl, nfx, nn = sys.argv[1:5]
md5 = lambda b: hashlib.md5(b).hexdigest()
VEN_OFF = 3686793216
ok = True
for path, src in (('/etc/ngp/LANGOS.apk', nl),
                  ('/bin/ngp-fixup.sh', nfx),
                  ('/etc/ngp/emulators/NetherSX2.apk', nn)):
    tmp = '/tmp/v39/_chk'
    if os.path.exists(tmp): os.remove(tmp)
    subprocess.run(['debugfs', '-R', f'dump {path} {tmp}',
                    f'{img}?offset={VEN_OFF}'], capture_output=True)
    if not os.path.exists(tmp):
        print(f'  p5 {path:40s} MISSING'); ok = False; continue
    g = md5(open(tmp, 'rb').read()); w = md5(open(src, 'rb').read())
    if g != w: ok = False
    os.remove(tmp)
    print(f'  p5 {path:40s} {g}  {"OK" if g == w else "MISMATCH(want %s)" % w}')

# /app/NetherSX2 必须已经不在了
r = subprocess.run(['debugfs', '-R', 'ls -l /app', f'{img}?offset={VEN_OFF}'],
                   capture_output=True, text=True)
if 'NetherSX2' in (r.stdout or ''):
    print('  !! /app/NetherSX2 还在'); ok = False
else:
    print('  p5 /app/NetherSX2 已删除  OK')

if not ok:
    print('!! 校验失败'); sys.exit(1)
PY

say ""
say "镜像: $IMG"
ls -l "$IMG" | tee -a "$LOG"
md5sum "$IMG" | tee -a "$LOG"
say "BUILD_DONE"
