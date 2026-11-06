#!/usr/bin/env bash
# build_v37.sh — 在 v36 镜像基础上产出 v37
#
# 相对 v36 的改动：
#   1. p5 vendor : /etc/ngp/LANGOS.apk   ← LANGOS 3.3-hdmi5col
#        getScreenRatio() 扫 DisplayManager，存在 displayId != 0 时返回 16:9；
#        getHomeColumns() 去掉硬编码 4，改为 ratio >= 1.7f → 5 列
#   2. p5 vendor : /bin/ngp-hdmi-ratio.sh ← 新增
#        HDMI 接入时 wm size 1366x768（16:9 逻辑分辨率），拔线复位
#   3. p5 vendor : /etc/init/ngp-hdmi-ratio.rc ← 新增
#        开机启动 watch 服务
#   4. p5 vendor : /bin/ngp-fixup.sh ← 覆盖更新
#        LANGOS 安装判据从「codePath 在不在 /data/app」改为「md5 是否一致」，
#        否则从 v36 覆盖升级的机器已有旧版 /data/app，新版永远装不上。
#
# 不动：p3 dArkOS_Fat（Image/DTB/extlinux.conf 全不变）、p4 system、其余分区
#
# 用法: ./build_v37.sh
set -euo pipefail

unset -f rm unlink rmdir 2>/dev/null || true
unset CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_BROKERED_SHELL_ENV 2>/dev/null || true
unset PYTHONPATH BASH_ENV 2>/dev/null || true
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hash -r

PYX=/home/liang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
D=/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis
SRC=$D/GammaOSCore-NGP45HT-20261105-v36.img
IMG=$D/GammaOSCore-NGP45HT-20261105-v37.img
TREE=/home/liang/rainject/sync-repo/device/ngp45ht
NEWLANGOS=$TREE/apps/LANGOS-3.3-hdmi5col.apk
NEWRATIO=$TREE/hdmi/ngp-hdmi-ratio.sh
NEWRATIORC=$TREE/hdmi/ngp-hdmi-ratio.rc
NEWFIXUP=$TREE/ime/ngp-fixup.sh
WORK=/tmp/v37
LOG=$WORK/build-v37.log

[ -f "$SRC" ]       || { echo "!! 缺 v36 基础镜像 $SRC"; exit 1; }
[ -f "$NEWLANGOS" ] || { echo "!! 缺新 LANGOS $NEWLANGOS"; exit 1; }
[ -f "$NEWRATIO" ]  || { echo "!! 缺 ngp-hdmi-ratio.sh $NEWRATIO"; exit 1; }
[ -f "$NEWRATIORC" ]|| { echo "!! 缺 ngp-hdmi-ratio.rc $NEWRATIORC"; exit 1; }
[ -f "$NEWFIXUP" ]  || { echo "!! 缺 ngp-fixup.sh $NEWFIXUP"; exit 1; }

mkdir -p "$WORK"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }

# 分区几何（GPT，v36 实测）
FAT_OFF=16777216;   FAT_SIZE=103809024
SYS_OFF=121634816;  SYS_SIZE=3565158400
VEN_OFF=3686793216; VEN_SIZE=602931200

say "### [1/6] 从 v36 复制出 v37"
command rm -f "$IMG"
cp --reflink=auto "$SRC" "$IMG"
ls -l "$IMG" | tee -a "$LOG"

say "### [2/6] 抽取 p5 vendor（p3/p4 不动）"
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

say "### [3/6] 注入 LANGOS.apk（体积一致，原地覆写）"
debugfs -w -R "rm /etc/ngp/LANGOS.apk" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write $NEWLANGOS /etc/ngp/LANGOS.apk" "$WORK/vendor.img" 2>&1 | tee -a "$LOG"

say "### [4/6] 注入 HDMI 16:9 脚本与 rc"
debugfs -w -R "rm /bin/ngp-hdmi-ratio.sh" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write $NEWRATIO /bin/ngp-hdmi-ratio.sh" "$WORK/vendor.img" 2>&1 | tee -a "$LOG"
debugfs -w -R "sif /bin/ngp-hdmi-ratio.sh mode 0100755" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /bin/ngp-hdmi-ratio.sh uid 0" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /bin/ngp-hdmi-ratio.sh gid 0" "$WORK/vendor.img" >/dev/null 2>&1

debugfs -w -R "rm /etc/init/ngp-hdmi-ratio.rc" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write $NEWRATIORC /etc/init/ngp-hdmi-ratio.rc" "$WORK/vendor.img" 2>&1 | tee -a "$LOG"
debugfs -w -R "sif /etc/init/ngp-hdmi-ratio.rc mode 0100644" "$WORK/vendor.img" >/dev/null 2>&1

say "### [4b/6] 覆盖 ngp-fixup.sh（LANGOS 升级判据修正）"
debugfs -w -R "rm /bin/ngp-fixup.sh" "$WORK/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write $NEWFIXUP /bin/ngp-fixup.sh" "$WORK/vendor.img" 2>&1 | tee -a "$LOG"
debugfs -w -R "sif /bin/ngp-fixup.sh mode 0100755" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /bin/ngp-fixup.sh uid 0" "$WORK/vendor.img" >/dev/null 2>&1
debugfs -w -R "sif /bin/ngp-fixup.sh gid 2000" "$WORK/vendor.img" >/dev/null 2>&1

say "### [5/6] 回写 p5 到镜像"
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

say "### [6/6] 断言：新内容确实落进镜像"
$PYX - "$IMG" "$NEWLANGOS" "$NEWRATIO" "$NEWRATIORC" "$NEWFIXUP" <<'PY' | tee -a "$LOG"
import sys, hashlib, subprocess, os
img, nl, nr, nrc, nfx = sys.argv[1:6]
md5 = lambda b: hashlib.md5(b).hexdigest()
VEN_OFF = 3686793216
ok = True
for path, src in (('/etc/ngp/LANGOS.apk', nl),
                  ('/bin/ngp-hdmi-ratio.sh', nr),
                  ('/etc/init/ngp-hdmi-ratio.rc', nrc),
                  ('/bin/ngp-fixup.sh', nfx)):
    tmp = '/tmp/v37/_chk'
    if os.path.exists(tmp): os.remove(tmp)
    subprocess.run(['debugfs','-R',f'dump {path} {tmp}',
                    f'{img}?offset={VEN_OFF}'], capture_output=True)
    if not os.path.exists(tmp):
        print(f"  p5 {path:30s} MISSING"); ok = False; continue
    g = md5(open(tmp,'rb').read()); w = md5(open(src,'rb').read())
    m = 'OK' if g == w else f'MISMATCH(want {w})'
    if g != w: ok = False
    os.remove(tmp)
    print(f"  p5 {path:30s} {g}  {m}")
if not ok:
    print("!! 校验失败"); sys.exit(1)
PY

say ""
say "镜像: $IMG"
ls -l "$IMG" | tee -a "$LOG"
md5sum "$IMG" | tee -a "$LOG"
say "BUILD_DONE"
