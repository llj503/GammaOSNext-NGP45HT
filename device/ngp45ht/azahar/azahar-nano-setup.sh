#!/system/bin/sh
# Stage the 3DS core and AdrenoTools hooks from /vendor into /data.
#
# Why /data instead of loading straight from /vendor:
#   libazahar-nano-core.so is dlopen()ed by absolute path from the property
#   below. /vendor/lib64 is in the linker's permitted paths, but a custom
#   directory such as /vendor/azahar is not -- a symlink there is rejected
#   (realpath not in permitted paths). /data works because the frontend takes
#   the path from the property verbatim.
#   The core is also 38 MB, which does not fit in /system (under 5 MB free).
#
# v28 moved the source from the boot partition (p3, /mnt/boot/azahar) to
# /vendor/azahar: p5 was grown 254 MiB -> 575 MiB for exactly this, so the
# core now lives in an ext4 system partition instead of a FAT one.
#
# The frontend derives its hook-library directory from the core's dirname, so
# the 4 AdrenoTools hooks must sit next to the core -- in both SRC and DST.
SRC=/vendor/azahar
DST=/data
LOG=/data/system/azahar-setup.log
: > "$LOG"
exec >>"$LOG" 2>&1
echo "azahar setup $(date)"

if [ ! -d "$SRC" ]; then
    echo "no $SRC, nothing to stage"
    exit 0
fi

# Copy when missing OR when the size differs -- the latter makes an image
# upgrade replace a stale core left in /data by a previous version.
stage() {
    _src="$SRC/$1"; _dst="$DST/$2"
    if [ -s "$_dst" ] && [ "$(wc -c < "$_dst")" -eq "$(wc -c < "$_src")" ]; then
        return 0
    fi
    cp -f "$_src" "$_dst" || return 1
    chmod 0644 "$_dst"
    chown root:root "$_dst" 2>/dev/null
    echo "staged $2"
}

stage libazahar-nano-core.so azahar-core.so || exit 0
for f in libhook_impl.so libmain_hook.so libfile_redirect_hook.so libgsl_alloc_hook.so; do
    stage "$f" "$f" || exit 0
done

setprop persist.gammaos.azahar_nano.core "$DST/azahar-core.so"
echo "core property: $(getprop persist.gammaos.azahar_nano.core)"
