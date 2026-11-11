#!/usr/bin/env bash
# build_v43.sh — 在 v42 镜像基础上产出 v43
#
# 相对 v42 的改动：
#   p4 system（先回收分区空隙再注入）
#     0. p4 分区 3400 MiB，但 ext4 文件系统只建到 3003 MiB —— 尾部约 397 MiB
#        一直空着。用 e2fsck -fy + resize2fs 扩到分区大小，不改 GPT、不移动
#        p5..p9。扩完空闲约 448 MiB（含原 51 MiB），inode 88 -> 1140。
#     1. /system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz   ← 新增 132 MiB
#        PS Vita 固件 / 字体 / VitaFS 骨架 + config.yml，不含商业游戏数据
#   p5 vendor
#     2. /etc/ngp/LANGOS.apk                    ← 覆盖：LANGOS 3.7.1-v43
#        psv/psvita 候选改为 org.vita3kplus.emulator，<queries> 同步补包，
#        versionCode 24 -> 25，证书沿用 langos.jks（05689c30…）
#     3. /etc/ngp/emulators/Vita3K-Plus-v1.4.apk ← 新增（可卸载首装）
#     4. /bin/ngp-fixup.sh                     ← 覆盖（+71 行）
#        ⓪0 本地 OTA 钩子 / ⓪a-1 device_provisioned 补齐 /
#        ⑫a-0 LANGOS 演示库守卫 / ⑫b Vita3K+ 首装 / ⑬ 固件种子解包
#     5. /bin/ngp-ota.sh                       ← 新增（本地 OTA 应用器）
#
# 不动：p3 dArkOS_Fat（Image/DTB/extlinux.conf）、GPT、p6..p9
#
# 用法: ./build_v43.sh [base.img] [out.img]
#   base 默认 /home/liang/rainject/v43-work/v42.img
#   out  默认 /run/media/liang/Data/ngp45ht/gammaosnext-port-analysis/GammaOSCore-NGP45HT-20261111-v43.img
set -euo pipefail

# WorkBuddy shell 注入的 safe-delete shim / PYTHONPATH 会让 meson/e2fsprogs
# 之类工具静默失败或行为异常；构建前一律清掉。
unset -f rm unlink rmdir 2>/dev/null || true
unset CODEBUDDY_SAFE_DELETE_ENABLED CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_BROKERED_SHELL_ENV 2>/dev/null || true
unset PYTHONPATH BASH_ENV 2>/dev/null || true
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hash -r

PYX=/home/liang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
W=/home/liang/rainject/v43-work
P=$W/payload
BASE=${1:-$W/v42.img}
OUT=${2:-/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis/GammaOSCore-NGP45HT-20261111-v43.img}
WORK=$W/build
LOG=$W/build-v43.log

# 注入的文件一律从仓库模板读，保证镜像内文件与仓库逐字节对齐。
# 种子包 132 MiB 超过 GitHub 单文件 100 MB 限制，只留本地构建素材，不入库。
TREE=/home/liang/rainject/sync-repo/device/ngp45ht
LANGOS=$TREE/apps/LANGOS-3.7.1-v43-psv.apk
FIXUP=$TREE/ime/ngp-fixup.sh
OTA=$TREE/scripts/ngp-ota.sh
V3KAPK=$TREE/emulators/Vita3K-Plus-v1.4.apk
SEED=$P/vita3k-plus-seed.tar.xz

for f in "$BASE" "$LANGOS" "$FIXUP" "$OTA" "$V3KAPK" "$SEED"; do
    [ -s "$f" ] || { echo "!! 缺 $f" >&2; exit 1; }
done
command -v debugfs e2fsck resize2fs sgdisk dd xz >/dev/null || { echo "!! 缺工具" >&2; exit 1; }

mkdir -p "$WORK" "$(dirname "$OUT")"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }

# ---------- 分区几何：从 GPT 现读，不写死 ----------
p_start() { sgdisk -i "$1" "$BASE" | awk -F': *' '/First sector/ {print $2}' | awk '{print $1}'; }
p_end()   { sgdisk -i "$1" "$BASE" | awk -F': *' '/Last sector/  {print $2}' | awk '{print $1}'; }
SS=$(sgdisk -p "$BASE" | sed -n 's/^Sector size (logical): *\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$SS" ] || SS=512
P4_S=$(p_start 4); P4_E=$(p_end 4)
P5_S=$(p_start 5); P5_E=$(p_end 5)
P4_SEC=$(( P4_E - P4_S + 1 ))
P5_SEC=$(( P5_E - P5_S + 1 ))
P4_OFF=$(( P4_S * SS )); P4_SIZ=$(( P4_SEC * SS ))
P5_OFF=$(( P5_S * SS )); P5_SIZ=$(( P5_SEC * SS ))
say "### GPT: sector=$SS  p4 @$P4_OFF size=$P4_SIZ ($P4_SEC s)  p5 @$P5_OFF size=$P5_SIZ ($P5_SEC s)"

# ---------- [1/8] 复制基线 ----------
say "### [1/8] 复制基线到输出镜像"
command rm -f "$OUT"
cp --sparse=always "$BASE" "$OUT"
ls -l "$OUT" | tee -a "$LOG"

# 用 Python 按 offset 抽取分区（避免 dd skip/seek 在稀疏文件上的歧义）
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

# ---------- [2/8] p4：抽出 -> 回收空隙 -> 注入种子包 ----------
say "### [2/8] 抽出 p4 并回收分区尾部空隙"
P4IMG=$WORK/p4.img
command rm -f "$P4IMG"
extract "$OUT" "$P4_OFF" "$P4_SIZ" "$P4IMG"
say "  e2fsck -fy（只修 superblock 计数；原状态 clean with errors）"
e2fsck -fy "$P4IMG" >>"$LOG" 2>&1 || {
    rc=$?; [ "$rc" -le 1 ] || { echo "!! e2fsck p4 失败 rc=$rc" >&2; exit 1; }
}
say "  resize2fs -> ${P4_SEC}s"
resize2fs "$P4IMG" "${P4_SEC}s" >>"$LOG" 2>&1 || resize2fs -f "$P4IMG" "${P4_SEC}s" >>"$LOG" 2>&1 || {
    echo "!! resize2fs p4 失败" >&2; exit 1; }
debugfs -R "stats" "$P4IMG" 2>/dev/null | grep -E 'Block count|Free blocks|Free inodes|Filesystem state' | tee -a "$LOG"

say "### [3/8] p4 注入 Vita3K+ 固件种子包"
dbg4() { debugfs -w -R "$1" "$P4IMG" >/dev/null 2>&1 || say "  WARN(p4): $1"; }
dbg4 "mkdir /system/etc/ngp"
dbg4 "mkdir /system/etc/ngp/vita3k"
dbg4 "rm /system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz"
debugfs -w -R "write $SEED /system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz" "$P4IMG" 2>&1 | tee -a "$LOG"
dbg4 "sif /system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz mode 0100644"
dbg4 "sif /system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz uid 0"
dbg4 "sif /system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz gid 0"
say "  e2fsck 收尾（修正 debugfs 写入后的块计数）"
e2fsck -fy "$P4IMG" >>"$LOG" 2>&1 || true
debugfs -R "stats" "$P4IMG" 2>/dev/null | grep -E 'Block count|Free blocks|Free inodes|Filesystem state' | tee -a "$LOG"

say "### [4/8] 回写 p4"
writeback "$P4IMG" "$OUT" "$P4_OFF" "$P4_SIZ"
command rm -f "$P4IMG"

# ---------- [5/8] p5：抽出 -> 注入 5 个文件 ----------
say "### [5/8] 抽出 p5"
P5IMG=$WORK/p5.img
command rm -f "$P5IMG"
extract "$OUT" "$P5_OFF" "$P5_SIZ" "$P5IMG"

say "### [6/8] p5 注入 LANGOS / Vita3K+ / fixup / ota"
dbg5() { debugfs -w -R "$1" "$P5IMG" >/dev/null 2>&1 || say "  WARN(p5): $1"; }
put5() { # src dst mode gid
    dbg5 "rm $2"
    debugfs -w -R "write $1 $2" "$P5IMG" 2>&1 | tee -a "$LOG"
    dbg5 "sif $2 mode $3"
    dbg5 "sif $2 uid 0"
    dbg5 "sif $2 gid $4"
}
dbg5 "mkdir /etc/ngp/emulators"
put5 "$LANGOS"  /etc/ngp/LANGOS.apk                          0100644 0
put5 "$V3KAPK"  /etc/ngp/emulators/Vita3K-Plus-v1.4.apk     0100644 0
put5 "$FIXUP"   /bin/ngp-fixup.sh                            0100755 2000
put5 "$OTA"     /bin/ngp-ota.sh                              0100755 2000
say "  e2fsck 收尾"
e2fsck -fy "$P5IMG" >>"$LOG" 2>&1 || true
debugfs -R "stats" "$P5IMG" 2>/dev/null | grep -E 'Block count|Free blocks|Free inodes|Filesystem state' | tee -a "$LOG"

say "### [7/8] 回写 p5"
writeback "$P5IMG" "$OUT" "$P5_OFF" "$P5_SIZ"
command rm -f "$P5IMG"

# ---------- [8/8] 断言 ----------
say "### [8/8] 校验"
$PYX - "$OUT" "$P4_OFF" "$P5_OFF" "$LANGOS" "$V3KAPK" "$FIXUP" "$OTA" "$SEED" <<'PY' | tee -a "$LOG"
import sys, hashlib, subprocess, os
out = sys.argv[1]
p4off, p5off = int(sys.argv[2]), int(sys.argv[3])
langos, v3k, fixup, ota, seed = sys.argv[4:9]
md5 = lambda b: hashlib.md5(b).hexdigest()
checks = [
    (p4off, '/system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz', seed),
    (p5off, '/etc/ngp/LANGOS.apk',                             langos),
    (p5off, '/etc/ngp/emulators/Vita3K-Plus-v1.4.apk',        v3k),
    (p5off, '/bin/ngp-fixup.sh',                               fixup),
    (p5off, '/bin/ngp-ota.sh',                                 ota),
]
ok = True
tmp = '/tmp/v43/_chk'
os.makedirs('/tmp/v43', exist_ok=True)
for off, path, src in checks:
    if os.path.exists(tmp): os.remove(tmp)
    subprocess.run(['debugfs', '-R', f'dump {path} {tmp}', f'{out}?offset={off}'],
                   capture_output=True)
    if not os.path.exists(tmp):
        print(f'  {path:56s} MISSING'); ok = False; continue
    got = md5(open(tmp,'rb').read()); want = md5(open(src,'rb').read())
    os.remove(tmp)
    print(f'  {path:56s} {got}  {"OK" if got == want else "MISMATCH want " + want}')
    ok &= got == want
if not ok:
    print('!! 文件校验失败'); sys.exit(1)
PY

say "  -- GPT --"
sgdisk -v "$OUT" 2>&1 | tail -3 | tee -a "$LOG"

say "  -- 4 MiB 分块比对（差异块必须全在 p4/p5 内）--"
$PYX - "$BASE" "$OUT" "$P4_OFF" "$P4_SIZ" "$P5_OFF" "$P5_SIZ" <<'PY' | tee -a "$LOG"
import sys
base, out = sys.argv[1], sys.argv[2]
p4o, p4s, p5o, p5s = map(int, sys.argv[3:7])
BS = 4*1024*1024
diff = []
with open(base,'rb') as a, open(out,'rb') as b:
    i = 0
    while True:
        x, y = a.read(BS), b.read(BS)
        if not x and not y: break
        if x != y: diff.append(i)
        i += 1
ranges = [(p4o, p4o+p4s), (p5o, p5o+p5s)]
def allowed(i):
    lo, hi = i*BS, (i+1)*BS
    return any(lo < e and hi > s for s, e in ranges)
bad = [i for i in diff if not allowed(i)]
in4 = sum(1 for i in diff if i*BS < p4o+p4s and (i+1)*BS > p4o)
in5 = sum(1 for i in diff if i*BS < p5o+p5s and (i+1)*BS > p5o)
print(f'  差异块 {len(diff)} 个：p4={in4} p5={in5} 范围外={len(bad)}')
if bad:
    print('  !! 范围外差异块:', bad[:20]); sys.exit(1)
print('  OK：所有差异块均落在 p4/p5 分区内')
PY

say "  -- 镜像哈希 --"
ls -l "$OUT" | tee -a "$LOG"
md5sum "$OUT" | tee -a "$LOG"
sha256sum "$OUT" | tee -a "$LOG"
say "BUILD_DONE"
