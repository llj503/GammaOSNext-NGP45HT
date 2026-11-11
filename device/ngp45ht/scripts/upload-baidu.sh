#!/bin/bash
# 上传 NGP45HT 发布物到百度网盘固定目录 /NGP45HT
#
# 凭据：/run/media/liang/Data/ngp45ht/baidupan.txt
#   格式随意，含 BDUSS 与 STOKEN 两个关键字即可
#   （只给 BDUSS 会报 "-6 请重新登录"，列目录/上传全失败）
#
# 用法：
#   bash upload-baidu.sh 20261106-v39            # 上传（小文件同步 + 镜像后台）
#   bash upload-baidu.sh 20261106-v39 --verify   # 只校验字节数，不上传
#
# 说明：
#   - 实测上行 ~5.8 MB/s（16 核机器），1.65 GB 约 5 分钟，不必按 250 KB/s 预估
#   - 同名文件 --policy overwrite 覆盖
#   - **判据只看字节数**：网盘 meta 里的 md5 标注「可能不正确」，不能当验证依据
set -uo pipefail

PCS=/home/liang/tools/baidupcs/BaiduPCS-Go-v4.0.2-linux-amd64/BaiduPCS-Go
D=/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis
REPO=/home/liang/rainject/sync-repo/doc/ngp45ht
CRED=/run/media/liang/Data/ngp45ht/baidupan.txt
REMOTE=/NGP45HT
VER="${1:-20261019-v9}"
MODE="${2:-upload}"
SHORT="${VER#*-}"            # 20261106-v39 -> v39
LOG=/tmp/baidu-upload-${VER}.log

FILES=()      # collect_files 填
IMG=""

[ -x "$PCS" ] || { echo "缺 BaiduPCS-Go: $PCS"; exit 1; }
[ -f "$CRED" ] || { echo "缺凭据文件: $CRED"; exit 1; }

pick() {
    python3 - "$CRED" "$1" <<'PY'
import re, sys
raw = open(sys.argv[1], errors='ignore').read()
m = re.search(sys.argv[2] + r'\s*[:=]\s*"?([^";\s,]+)"?', raw)
print(m.group(1) if m else '')
PY
}

# 组出这一版要传/要验的文件清单。
# CHANGES 平时只在仓库 doc 里，不在 $D，两边都找。
collect_files() {
    local chg="$D/${SHORT}-CHANGES.md"
    [ -f "$chg" ] || chg="$REPO/${SHORT}-CHANGES.md"
    FILES=(
        "$D/SHA256SUMS-${SHORT}.txt"
        "$D/SHA256SUMS-${VER}.txt"
        "$D/release-notes-${SHORT}.md"
        "$chg"
    )
    local z f
    for z in "$D"/ngp45ht-*-kit-*.zip; do
        [ -f "$z" ] && FILES+=("$z")
    done
    f=$(ls -1 "$D"/GammaOSCore-NGP45HT-*"${VER}".img.xz 2>/dev/null | head -1)
    [ -n "$f" ] && IMG="$f" || IMG=""
}

remote_size() {  # 打印远端字节数，取不到就空
    "$PCS" meta "$REMOTE/$1" 2>/dev/null \
        | sed -n 's/.*文件大小  *\([0-9][0-9]*\),.*/\1/p' | head -1
}

verify() {
    local f b sz r ok=0 total=0
    echo "=== 校验字节数（本机 vs 网盘）"
    for f in "${FILES[@]}" ${IMG:+"$IMG"}; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        sz=$(stat -c%s "$f")
        r=$(remote_size "$b")
        total=$((total + 1))
        if [ "$sz" = "$r" ]; then
            printf '  OK    %-46s %12d\n' "$b" "$sz"
        else
            printf '  DIFF  %-46s local=%-12s remote=%s\n' "$b" "$sz" "${r:-未找到}"
            ok=1
        fi
    done
    return $ok
}

BDUSS=$(pick BDUSS)
STOKEN=$(pick STOKEN)
[ -n "$BDUSS" ] || { echo "凭据里没找到 BDUSS"; exit 1; }

echo "=== 登录"
"$PCS" login -bduss="$BDUSS" -stoken="$STOKEN" || exit 1
"$PCS" who || exit 1

collect_files

if [ "$MODE" = "--verify" ]; then
    verify && { echo "全部一致"; exit 0; } || { echo "有差异"; exit 1; }
fi

echo "=== 确认固定目录 $REMOTE"
"$PCS" mkdir "$REMOTE" >/dev/null 2>&1
"$PCS" ls "$REMOTE" | tail -3

echo "=== 小文件"
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    printf '  %-46s %10d B\n' "$(basename "$f")" "$(stat -c%s "$f")"
    "$PCS" upload -p 4 --retry 3 --policy overwrite "$f" "$REMOTE" \
        | grep -E "上传文件成功|失败" | head -1
done

# 小文件是同步传的，立刻能校验
echo ""
verify || echo "  （镜像若还在传，上面 DIFF 属正常）"

echo ""
echo "=== 镜像（后台，日志 $LOG）"
if [ -n "$IMG" ]; then
    setsid nohup "$PCS" upload -p 8 --retry 5 --policy overwrite "$IMG" "$REMOTE" > "$LOG" 2>&1 &
    echo "  已启动: $(basename "$IMG")  pid=$!"
    echo "  查看进度: tail -f $LOG"
    echo "  传完后校验: bash $0 $VER --verify"
else
    echo "  未找到 $VER 的 .img.xz"
fi
