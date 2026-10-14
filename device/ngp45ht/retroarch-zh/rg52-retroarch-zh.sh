#!/system/bin/sh
# rg52-retroarch-zh.sh — deploy RetroArch zh-CN font + cfg into the app's
# external files dir. Idempotent: runs on every boot, acts only when missing.
SRC=/vendor/etc/retroarch-zh
DST=/data/media/0/Android/data/com.retroarch.aarch64/files
CFG=$DST/retroarch.cfg
FONT=$DST/zh-CN.ttf

# wait for PackageManager to create the app's external files dir (max ~2 min)
i=0
while [ ! -d "$DST" ]; do
    [ "$i" -ge 24 ] && exit 1
    sleep 5
    i=$((i + 1))
done

[ -f "$FONT" ] || cp -f "$SRC/zh-CN.ttf" "$FONT"
if [ ! -f "$CFG" ] || ! grep -q "zh-CN.ttf" "$CFG"; then
    cp -f "$SRC/retroarch.cfg" "$CFG"
fi
chmod 666 "$CFG"
chmod 644 "$FONT"
log -t rg52_retroarch_zh "zh-CN font+cfg deployed to $DST"
