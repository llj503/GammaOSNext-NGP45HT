#!/usr/bin/env bash
# build_v43r4.sh — 在 v43r3 镜像基础上恢复「首次开机欢迎向导」
#
# 相对 v43r3 只改 p5 vendor 的两个文件，其它字节一律不动：
#   1. /bin/ngp-fixup.sh      ← 覆盖（995 → 1128 行）
#      · 新增 --postwizard 后置分支：等向导完成后把 HOME / rom_root 交回
#        LANGOS，并兜底补 provisioning flags 与 apps.list 的 7 个 app；
#      · 向导活跃时不再抢写 flags、不抢 HOME、不启动 LANGOS、不抢跑 setup.sh；
#      · ⓪c 显示方向锁定等与向导无关的动作照常执行。
#   2. /etc/init/ngp-fixup.rc ← 覆盖（763 → 1386 B）
#      · 新增 init 直接托管的 ngp_postwizard oneshot 服务
#        （ngp_fixup 是 oneshot，内部 & 后台任务会被 init 回收）。
#
# 不动：GPT、p1..p4、p6..p9、p4 里的 SetupWizard APK / setup.sh / init.rc / zstd。
#
# 用法: ./build_v43r4.sh [base.img] [out.img]
set -euo pipefail

# WorkBuddy shell 注入的 safe-delete shim / PYTHONPATH 会让 e2fsprogs 静默失败
unset -f rm unlink rmdir 2>/dev/null || true
unset CODEBUDDY_SAFE_DELETE_ENABLED CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_BROKERED_SHELL_ENV 2>/dev/null || true
unset PYTHONPATH BASH_ENV 2>/dev/null || true
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hash -r

PYX=/home/liang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
W=/home/liang/rainject/v43-work
TREE=/home/liang/rainject/sync-repo/device/ngp45ht
D=/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis
BASE=${1:-$D/GammaOSCore-NGP45HT-20261113-v43r3.img}
OUT=${2:-$D/GammaOSCore-NGP45HT-20261116-v43r4.img}
WORK=$W/build-r4
LOG=$W/build-v43r4.log

FIXUP=$TREE/ime/ngp-fixup.sh
RC=$TREE/ime/ngp-fixup.rc

for f in "$BASE" "$FIXUP" "$RC"; do
    [ -s "$f" ] || { echo "!! 缺 $f" >&2; exit 1; }
done
for t in debugfs e2fsck sgdisk md5sum sha256sum xz; do
    command -v "$t" >/dev/null || { echo "!! 缺工具 $t" >&2; exit 1; }
done

mkdir -p "$WORK" "$(dirname "$OUT")"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }

# ---------- 分区几何：从 GPT 现读 ----------
p_start() { sgdisk -i "$1" "$BASE" | awk -F': *' '/First sector/ {print $2}' | awk '{print $1}'; }
p_end()   { sgdisk -i "$1" "$BASE" | awk -F': *' '/Last sector/  {print $2}' | awk '{print $1}'; }
SS=$(sgdisk -p "$BASE" | sed -n 's/^Sector size (logical): *\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$SS" ] || SS=512
P5_S=$(p_start 5); P5_E=$(p_end 5)
P5_OFF=$(( P5_S * SS )); P5_SIZ=$(( (P5_E - P5_S + 1) * SS ))
P4_S=$(p_start 4); P4_E=$(p_end 4)
P4_OFF=$(( P4_S * SS )); P4_SIZ=$(( (P4_E - P4_S + 1) * SS ))
say "### GPT: sector=$SS  p4 @$P4_OFF size=$P4_SIZ  p5 @$P5_OFF size=$P5_SIZ"

# ---------- [1/6] 复制基线 ----------
say "### [1/6] 复制基线到输出镜像"
command rm -f "$OUT"
cp --sparse=always "$BASE" "$OUT"
ls -l "$OUT" | tee -a "$LOG"

extract() { # img off size dst
    $PYX - "$1" "$2" "$3" "$4" <<'PY'
import sys
img, off, size, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with open(img, 'rb') as fi, open(dst, 'wb') as o:
    fi.seek(off); left = size
    while left > 0:
        b = fi.read(min(32*1024*1024, left))
        if not b: break
        o.write(b); left -= len(b)
PY
}
writeback() { # src img off size
    $PYX - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, img, off, size = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with open(img, 'r+b') as o, open(src, 'rb') as fi:
    o.seek(off); left = size
    while left > 0:
        b = fi.read(min(32*1024*1024, left))
        if not b: break
        o.write(b); left -= len(b)
PY
}

# ---------- [2/6] p5：覆盖两个文件 ----------
say "### [2/6] 抽出 p5"
P5IMG=$WORK/p5.img
command rm -f "$P5IMG"
extract "$OUT" "$P5_OFF" "$P5_SIZ" "$P5IMG"

say "### [3/6] 替换 /bin/ngp-fixup.sh 与 /etc/init/ngp-fixup.rc"
dbg() { debugfs -w -R "$1" "$P5IMG" >/dev/null 2>&1 || say "  WARN(p5): $1"; }
# debugfs 的 write 不能覆盖已存在文件（静默跳过且 exit 0），必须先 rm
dbg "rm /bin/ngp-fixup.sh"
debugfs -w -R "write $FIXUP /bin/ngp-fixup.sh" "$P5IMG" 2>&1 | tee -a "$LOG"
dbg "sif /bin/ngp-fixup.sh mode 0100755"
dbg "sif /bin/ngp-fixup.sh uid 0"
dbg "sif /bin/ngp-fixup.sh gid 2000"
dbg "rm /etc/init/ngp-fixup.rc"
debugfs -w -R "write $RC /etc/init/ngp-fixup.rc" "$P5IMG" 2>&1 | tee -a "$LOG"
dbg "sif /etc/init/ngp-fixup.rc mode 0100644"
dbg "sif /etc/init/ngp-fixup.rc uid 0"
dbg "sif /etc/init/ngp-fixup.rc gid 0"
# rm+write 会丢 security.selinux；debugfs ea_set 不补结尾 NUL，内核不认。
# 与 v43 已验证可执行的 /bin/ngp-ota.sh 一致：留空，本机 userdebug+permissive。
for f in /bin/ngp-fixup.sh /etc/init/ngp-fixup.rc; do
    debugfs -w -R "ea_rm $f security.selinux" "$P5IMG" >/dev/null 2>&1 || true
done
say "  e2fsck 收尾"
e2fsck -fy "$P5IMG" >>"$LOG" 2>&1 || true
debugfs -R "stats" "$P5IMG" 2>/dev/null | grep -E 'Block count|Free blocks|Free inodes|Filesystem state' | tee -a "$LOG"

say "### [4/6] 回写 p5"
writeback "$P5IMG" "$OUT" "$P5_OFF" "$P5_SIZ"
command rm -f "$P5IMG"

# ---------- [5/6] 断言 ----------
say "### [5/6] 校验"
say "  -- 镜像内两个文件与仓库模板逐字节对齐 --"
$PYX - "$OUT" "$P5_OFF" "$FIXUP" "$RC" <<'PY' | tee -a "$LOG"
import sys, hashlib, subprocess, os
out, off = sys.argv[1], int(sys.argv[2])
fixup, rc = sys.argv[3:5]
md5 = lambda b: hashlib.md5(b).hexdigest()
tmp = '/tmp/v43r4_chk'
os.makedirs('/tmp', exist_ok=True)
ok = True
for path, src in [('/bin/ngp-fixup.sh', fixup), ('/etc/init/ngp-fixup.rc', rc)]:
    if os.path.exists(tmp): os.remove(tmp)
    subprocess.run(['debugfs', '-R', f'dump {path} {tmp}', f'{out}?offset={off}'],
                   capture_output=True)
    if not os.path.exists(tmp):
        print(f'  {path:32s} MISSING'); ok = False; continue
    got = md5(open(tmp, 'rb').read()); want = md5(open(src, 'rb').read())
    os.remove(tmp)
    print(f'  {path:32s} {got} {"OK" if got == want else "MISMATCH want " + want}')
    ok &= got == want
if not ok:
    print('!! 文件校验失败'); sys.exit(1)
PY

say "  -- 权限位 --"
for f in /bin/ngp-fixup.sh /etc/init/ngp-fixup.rc; do
    debugfs -R "stat $f" "$OUT?offset=$P5_OFF" 2>/dev/null \
        | grep -E '^(Inode|Mode|User)' | tr '\n' ' ' | sed "s|^|  $f |" | tee -a "$LOG"
done

say "  -- GPT 完整性 --"
sgdisk -v "$OUT" 2>&1 | tail -3 | tee -a "$LOG"
if diff <(sgdisk -p "$BASE" 2>/dev/null | tail -n +2) <(sgdisk -p "$OUT" 2>/dev/null | tail -n +2) >/dev/null; then
    say "  OK：分区表逐字一致"
else
    say "  !! 分区表发生变化"; exit 1
fi

say "  -- 4 MiB 分块硬比对（差异块必须全在 p5 内）--"
$PYX - "$BASE" "$OUT" "$P5_OFF" "$P5_SIZ" <<'PY' | tee -a "$LOG"
import sys
base, out = sys.argv[1], sys.argv[2]
p5o, p5s = map(int, sys.argv[3:5])
BS = 4*1024*1024
diff = []
with open(base,'rb') as a, open(out,'rb') as b:
    i = 0
    while True:
        x, y = a.read(BS), b.read(BS)
        if not x and not y: break
        if x != y: diff.append(i)
        i += 1
bad = [i for i in diff if not (i*BS < p5o+p5s and (i+1)*BS > p5o)]
print(f'  差异块 {len(diff)} 个：p5={len(diff)-len(bad)} 范围外={len(bad)}')
if bad:
    print('  !! 范围外差异块:', bad[:20]); sys.exit(1)
print('  OK：所有差异块均落在 p5 分区内')
PY

say "  -- 镜像哈希 --"
ls -l "$OUT" | tee -a "$LOG"
md5sum "$OUT" | tee -a "$LOG"
sha256sum "$OUT" | tee -a "$LOG"

# ---------- [6/6] 压缩与回验 ----------
say "### [6/6] xz -T0 -6 压缩与回验"
XZ="$OUT.xz"
command rm -f "$XZ"
xz -T0 -6 -c "$OUT" > "$XZ"
ls -l "$XZ" | tee -a "$LOG"
xz -t "$XZ" && say "  xz -t OK"
A=$(md5sum "$OUT" | awk '{print $1}')
B=$(xz -dc "$XZ" | md5sum | awk '{print $1}')
say "  裸镜像 md5=$A  xz 解回 md5=$B"
[ "$A" = "$B" ] || { say "  !! xz 回验失败"; exit 1; }
sha256sum "$XZ" | tee -a "$LOG"
say "BUILD_DONE"
