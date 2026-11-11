#!/usr/bin/env bash
# 生成 NGP45HT 本地 OTA 包（目录格式，整个拷进掌机 /sdcard/OTA/）。
#
# 用法:
#   ./make_ota_package.sh <out-root> <pkg-name> [payload...]
#     <out-root>   输出根目录，例如 /sdcard/OTA 的挂载点
#     <pkg-name>   包目录名，必须以 update- 开头，例如 update-20261111a
#     [payload...] 逻辑载荷名（见 dest_of）；省略则打包全部
#
# 载荷来源（按候选顺序找第一个存在的文件）：
#   1. $NGP_PAYLOAD_DIR（本地构建素材目录，例如 v43-work/payload）
#   2. 脚本同目录
#   3. 仓库 device/ngp45ht/ 下的 apps / emulators / ime / scripts
# vita3k-plus-seed.tar.xz 有 132 MiB，超过 GitHub 单文件 100 MB，未入库；
# 要打全量包请先生成种子包，并设 NGP_PAYLOAD_DIR 指向它所在目录。
#
# 载荷到系统路径的映射必须与 scripts/build_v43.sh 的落盘路径一致。
#
# 例：
#   ./make_ota_package.sh /tmp/OTA update-20261111a ngp-fixup.sh ngp-ota.sh
#   NGP_PAYLOAD_DIR=~/rainject/v43-work/payload \
#     ./make_ota_package.sh /tmp/OTA update-20261111b
#
# 环境变量 OTA_REBOOT=0 生成的包应用后不自动重启（默认 1）。
set -euo pipefail
IB=${NGP_PAYLOAD_DIR:-$(cd "$(dirname "$0")" && pwd)}
TREE=$(cd "$(dirname "$0")/.." && pwd)
OUT_ROOT=${1:?out root}
PKG=${2:?package name (update-...)}
shift 2
case "$PKG" in update-*) ;; *) echo "package name must start with 'update-'" >&2; exit 1 ;; esac
case "$PKG" in *[!A-Za-z0-9._-]*) echo "illegal package name: $PKG" >&2; exit 1 ;; esac
REBOOT=${OTA_REBOOT:-1}

ALL="LANGOS.apk Vita3K-Plus-v1.4.apk ngp-fixup.sh ngp-ota.sh vita3k-plus-seed.tar.xz"

# 逻辑载荷名 -> "系统内相对路径 mode uid gid"
dest_of() {
    case "$1" in
        LANGOS.apk)               echo "vendor/etc/ngp/LANGOS.apk 0644 0 0" ;;
        Vita3K-Plus-v1.4.apk)     echo "vendor/etc/ngp/emulators/Vita3K-Plus-v1.4.apk 0644 0 0" ;;
        ngp-fixup.sh)             echo "vendor/bin/ngp-fixup.sh 0755 0 2000" ;;
        ngp-ota.sh)               echo "vendor/bin/ngp-ota.sh 0755 0 2000" ;;
        vita3k-plus-seed.tar.xz)  echo "system/etc/ngp/vita3k/vita3k-plus-seed.tar.xz 0644 0 0" ;;
        *) return 1 ;;
    esac
}

# 逻辑载荷名 -> 实际文件。仓库里的文件名带版本号，与逻辑名不同，逐个候选找。
src_of() {
    local c
    case "$1" in
        LANGOS.apk)
            for c in "$IB/LANGOS.apk" "$IB/LANGOS-v43.apk" \
                     "$IB/langos/LANGOS-v43.apk" "$(dirname "$IB")/langos/LANGOS-v43.apk" \
                     "$TREE/apps/LANGOS-3.7.1-v43-psv.apk" "$TREE/apps/LANGOS.apk"; do
                [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
            done ;;
        Vita3K-Plus-v1.4.apk)
            for c in "$IB/Vita3K-Plus-v1.4.apk" "$TREE/emulators/Vita3K-Plus-v1.4.apk"; do
                [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
            done ;;
        ngp-fixup.sh)
            for c in "$IB/ngp-fixup.sh" "$IB/ngp-fixup-v43.sh" \
                     "$TREE/ime/ngp-fixup.sh"; do
                [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
            done ;;
        ngp-ota.sh)
            for c in "$IB/ngp-ota.sh" "$TREE/scripts/ngp-ota.sh"; do
                [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
            done ;;
        vita3k-plus-seed.tar.xz)
            for c in "$IB/vita3k-plus-seed.tar.xz" "$TREE/scripts/vita3k-plus-seed.tar.xz"; do
                [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
            done ;;
    esac
    return 1
}

FILES=${*:-$ALL}
PKG_DIR=$OUT_ROOT/$PKG
[ -e "$PKG_DIR" ] && { echo "package already exists: $PKG_DIR" >&2; exit 1; }
mkdir -p "$PKG_DIR/payload"
MF=$PKG_DIR/manifest.txt
{
    echo "# NGP45HT local OTA package"
    echo "format=1"
    echo "pkg=$PKG"
    echo "reboot=$REBOOT"
} > "$MF"

total=0
for f in $FILES; do
    map=$(dest_of "$f") || { echo "no destination mapping for: $f" >&2; exit 1; }
    read -r rel mode uid gid <<<"$map"
    src=$(src_of "$f") || {
        echo "missing payload: $f" >&2
        echo "  找过 \$NGP_PAYLOAD_DIR、脚本同目录、$TREE 下的 apps/emulators/ime/scripts" >&2
        exit 1
    }
    mkdir -p "$PKG_DIR/payload/${rel%/*}"
    cp -f "$src" "$PKG_DIR/payload/$rel"
    chmod "$mode" "$PKG_DIR/payload/$rel" 2>/dev/null || true
    sha=$(sha256sum "$src" | awk '{print $1}')
    echo "file|$rel|$mode|$uid|$gid|$sha" >> "$MF"
    sz=$(stat -c %s "$src")
    total=$((total + sz))
    printf '%-64s %10s bytes\n' "$rel" "$sz"
done

cat > "$PKG_DIR/README.txt" <<EOF
NGP45HT 本地 OTA 包
包名: $PKG
生成: $(date '+%Y-%m-%d %H:%M:%S')

用法:
  1. 把这个目录整个复制到掌机的 /sdcard/OTA/ 下（即 /sdcard/OTA/$PKG/）；
  2. 重启掌机，开机时会自动应用并再次重启；
  3. 结果看本目录的 STATUS.txt，或 adb shell cat /data/ngp/ota.log。

只替换 /system 和 /vendor 里的文件，不会动 /data 里的应用数据和 /sdcard 上的游戏。
不要修改 manifest.txt；重新生成请用 scripts/make_ota_package.sh。
EOF
echo
echo "package: $PKG_DIR"
echo "files:   $(printf '%s\n' $FILES | wc -l), total $((total / 1024 / 1024)) MiB"
echo "reboot:  $REBOOT"
