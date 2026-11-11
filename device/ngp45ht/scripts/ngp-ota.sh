#!/system/bin/sh
# NGP45HT 本地 OTA 应用器。由 /vendor/bin/ngp-fixup.sh 在开机时调用。
#
# 为什么不是官方 update.zip：本机没有 recovery 分区、没有 A/B 槽，镜像也不是
# 用发布密钥签的，update_engine 那套 payload 在这里无从谈起；整卡重刷又太重。
# 这里做的是"增量文件包"：把要替换的文件放进 /sdcard/OTA/update-<名字>/，
# 开机后校验 sha256 再写进 /system、/vendor，然后重启生效。/data 与 /sdcard
# 的用户数据完全不碰。
#
# 包目录：
#   /sdcard/OTA/update-20261108a/
#     manifest.txt
#     payload/system/app/LANGOS/LANGOS.apk
#     payload/vendor/bin/ngp-fixup.sh
#
# manifest.txt（| 分隔；路径不能含空格）：
#   format=1
#   pkg=update-20261108a
#   reboot=1
#   file|system/app/LANGOS/LANGOS.apk|0644|0|0|<sha256>
#
# 应用成功/失败都会在包目录写 STATUS.txt；带 STATUS.txt 的包不会再处理。
# 失败重试：删掉 STATUS.txt 再重启。
#
# 手动用法：
#   /vendor/bin/ngp-ota.sh --dry-run   只校验并打印计划，不写任何文件

TAG=ngp-ota
STATE_DIR=/data/ngp
LOG=$STATE_DIR/ota.log
DRY=0
[ "$1" = "--dry-run" ] && DRY=1

mkdir -p "$STATE_DIR" 2>/dev/null

say() {
    command -v log >/dev/null 2>&1 && log -t $TAG "$*" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
    [ "$DRY" = 1 ] && echo "$*"
}

# 优先走 /data/media/0（/sdcard 背后的真实 ext4 路径），root 读它不受 FUSE
# 的归属映射影响；两个路径是同一份内容，用户在文件管理里看到的仍是 /sdcard/OTA。
# NGP_OTA_DIR 只用于离线试跑（--dry-run），真机上不要设。
OTA_CANDS=${NGP_OTA_DIR:-"/data/media/0/OTA /storage/emulated/0/OTA"}

volume_ready() {
    sm list-volumes all 2>/dev/null | grep -q 'public:.*mounted'
}

find_ota_dir() {
    _i=0
    while [ "$_i" -lt 30 ]; do
        for _d in $OTA_CANDS; do
            # 目录存在还不够，SELinux 可能挡读；ls 失败就试下一个路径
            [ -d "$_d" ] || continue
            ls "$_d" >/dev/null 2>&1 || continue
            echo "$_d"
            return 0
        done
        # 卷已挂载却没有 OTA 目录 = 没有包，不要空等
        volume_ready && return 1
        _i=$((_i + 1))
        sleep 1
    done
    return 1
}

pending_pkg() {
    for _p in "$1"/update-*; do
        [ -d "$_p" ] || continue
        [ -e "$_p/STATUS.txt" ] && continue
        # /data 上的标记比 /sdcard 可靠：sdcard 写失败时也不能反复刷同一个包
        [ -e "$STATE_DIR/applied/$(basename "$_p")" ] && continue
        [ -f "$_p/manifest.txt" ] || continue
        echo "$_p"
        return 0
    done
    return 1
}

ROOT=$(find_ota_dir)
if [ -z "$ROOT" ]; then
    [ "$DRY" = 1 ] && say "no /sdcard/OTA directory"
    exit 0
fi
PKG=$(pending_pkg "$ROOT")
if [ -z "$PKG" ]; then
    [ "$DRY" = 1 ] && say "no pending package in $ROOT"
    exit 0
fi
NAME=$(basename "$PKG")
MF=$PKG/manifest.txt
say "found package: $NAME"

fail() {
    if [ "$DRY" = 1 ]; then
        say "WOULD FAIL: $*"
        exit 1
    fi
    say "FAILED $NAME: $*"
    printf 'failed: %s\ndate: %s\n' "$*" "$(date '+%Y-%m-%d %H:%M:%S')" \
        > "$PKG/STATUS.txt" 2>/dev/null
    mkdir -p "$STATE_DIR/failed" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$STATE_DIR/failed/$NAME" 2>/dev/null
    exit 1
}

# ---------- 1. 校验：manifest 合法 + 每个载荷 sha256 对得上 ----------
fmt=""
rb=1
bad=""
nfiles=0
need_sys=0
need_ven=0

while IFS= read -r line; do
    case "$line" in
        ''|'#'*) continue ;;
        format=*) fmt=${line#format=} ;;
        # pkg= 只作记录，标记与日志一律用目录名，避免改名字段把标记带偏
        pkg=*)
            _pn=${line#pkg=}
            case "$_pn" in
                update-*) ;;
                *) bad="bad pkg name: $_pn" ;;
            esac
            case "$_pn" in
                *[!A-Za-z0-9._-]*) bad="bad pkg name: $_pn" ;;
            esac
            ;;
        reboot=*) rb=${line#reboot=} ;;
        file\|*)
            rest=${line#file|}
            rel=${rest%%|*}; rest=${rest#*|}
            mode=${rest%%|*}; rest=${rest#*|}
            uid=${rest%%|*}; rest=${rest#*|}
            gid=${rest%%|*}; rest=${rest#*|}
            sha=${rest%%|*}

            _ok=1
            case "$rel" in
                system/*|vendor/*) ;;
                *) bad="destination not allowed: $rel"; _ok=0 ;;
            esac
            case "$rel" in
                *..*|*[[:space:]]*) bad="bad destination: $rel"; _ok=0 ;;
            esac
            case "$mode" in
                0[0-7][0-7][0-7]) ;;
                *) bad="bad mode: $mode"; _ok=0 ;;
            esac
            case "$uid" in ''|*[!0-9]*) bad="bad uid: $uid"; _ok=0 ;; esac
            case "$gid" in ''|*[!0-9]*) bad="bad gid: $gid"; _ok=0 ;; esac
            case "$sha" in
                *[!0-9a-fA-F]*) bad="bad sha256: $sha"; _ok=0 ;;
            esac
            [ ${#sha} -eq 64 ] || { bad="bad sha256 length: $sha"; _ok=0; }
            [ "$_ok" = 1 ] || break

            _src=$PKG/payload/$rel
            [ -f "$_src" ] || { bad="missing payload: $rel"; break; }
            _want=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
            _have=$(sha256sum "$_src" 2>/dev/null | awk '{print $1}')
            [ "$_have" = "$_want" ] || \
                { bad="sha256 mismatch: $rel (have $_have)"; break; }

            _sz=$(stat -c %s "$_src" 2>/dev/null)
            case "$rel" in
                system/*) need_sys=$((need_sys + _sz / 1024 + 1)) ;;
                vendor/*) need_ven=$((need_ven + _sz / 1024 + 1)) ;;
            esac
            nfiles=$((nfiles + 1))
            [ "$DRY" = 1 ] && say "OK  $rel  ${_sz}B"
            ;;
        *) bad="unknown manifest line: $line" ;;
    esac
done < "$MF"

[ "$fmt" = "1" ] || fail "unsupported manifest format: ${fmt:-none}"
[ -z "$bad" ] || fail "$bad"
[ "$nfiles" -gt 0 ] || fail "package has no files"
case "$NAME" in
    update-*) ;;
    *) fail "package name must start with update-: $NAME" ;;
esac
case "$NAME" in
    *[!A-Za-z0-9._-]*) fail "bad package name: $NAME" ;;
esac

if [ "$DRY" = 1 ]; then
    say "dry-run OK: $nfiles files, ${need_sys}KB system + ${need_ven}KB vendor, reboot=$rb"
    exit 0
fi

# ---------- 2. 前置条件 ----------
free_kb() { df -k "$1" 2>/dev/null | awk 'NR > 1 { v = $4 } END { print (v == "" ? 0 : v) }'; }

if [ "$need_sys" -gt 0 ]; then
    _fs=$(free_kb /)
    [ "$_fs" -ge $((need_sys + 4096)) ] || \
        fail "not enough space on /system: ${_fs}KB free, need $((need_sys + 4096))KB"
fi
if [ "$need_ven" -gt 0 ]; then
    _fv=$(free_kb /vendor)
    [ "$_fv" -ge $((need_ven + 512)) ] || \
        fail "not enough space on /vendor: ${_fv}KB free, need $((need_ven + 512))KB"
fi

# verity 开着的话写进去也不会生效（读回时哈希对不上），直接拒绝。
vm=$(getprop ro.boot.veritymode 2>/dev/null)
case "$vm" in
    disabled) ;;
    "") say "warning: ro.boot.veritymode is empty, assuming disabled" ;;
    *) fail "dm-verity is '$vm'; local OTA needs verity disabled" ;;
esac

is_rw() {
    mount 2>/dev/null | grep " on $1 " | grep -q '(rw,'
}

remount_rw() {
    _m=$1
    mount -o rw,remount "$_m" >/dev/null 2>&1
    is_rw "$_m" && return 0
    mount -o rw,remount -t auto "$_m" >/dev/null 2>&1
    is_rw "$_m" && return 0
    return 1
}

[ "$need_sys" -gt 0 ] && { remount_rw / || remount_rw /system || fail "cannot remount /system rw"; }
[ "$need_ven" -gt 0 ] && { remount_rw /vendor || fail "cannot remount /vendor rw"; }

# ---------- 3. 逐个替换：同目录临时文件 + rename，避免写一半被看到 ----------
n=0
while IFS= read -r line; do
    case "$line" in file\|*) ;; *) continue ;; esac
    rest=${line#file|}
    rel=${rest%%|*}; rest=${rest#*|}
    mode=${rest%%|*}; rest=${rest#*|}
    uid=${rest%%|*}; rest=${rest#*|}
    gid=${rest%%|*}
    src=$PKG/payload/$rel
    dst=/$rel
    dstdir=${dst%/*}
    mkdir -p "$dstdir" 2>/dev/null
    tmp=$dstdir/.ngp-ota.tmp

    cp -f "$src" "$tmp" 2>/dev/null || fail "copy failed: $rel"
    chmod "$mode" "$tmp" 2>/dev/null || say "warning: chmod $mode failed: $rel"
    chown "$uid:$gid" "$tmp" 2>/dev/null || say "warning: chown $uid:$gid failed: $rel"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$tmp" >/dev/null 2>&1
    else
        case "$rel" in
            system/*) chcon u:object_r:system_file:s0 "$tmp" 2>/dev/null ;;
            vendor/*) chcon u:object_r:vendor_file:s0 "$tmp" 2>/dev/null ;;
        esac
    fi
    mv -f "$tmp" "$dst" 2>/dev/null || fail "replace failed: $rel"

    # 换掉 /system/app 里的 APK 时清掉旧的 dexopt 产物，下次开机重新编译
    case "$rel" in
        system/app/*/*) rm -rf "$dstdir/oat" 2>/dev/null ;;
    esac

    n=$((n + 1))
    say "installed $rel"
done < "$MF"

sync

# ---------- 4. 标记 + 重启 ----------
{
    echo "applied $NAME"
    echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "files=$n"
} > "$PKG/STATUS.txt" 2>/dev/null
mkdir -p "$STATE_DIR/applied" "$STATE_DIR/history" 2>/dev/null
: > "$STATE_DIR/applied/$NAME" 2>/dev/null
cp -f "$MF" "$STATE_DIR/history/$NAME.manifest" 2>/dev/null
say "applied $n files from $NAME"

if [ "$rb" = "1" ]; then
    say "rebooting to activate"
    sync
    setprop sys.powerctl reboot
else
    say "reboot=0: changes take effect on next boot"
fi
exit 0
