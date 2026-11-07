#!/system/bin/sh
# NGP45HT: expose the EEROMS public volume under /storage/EEROMS.
# vold mounts FAT32 public volumes by volume UUID; LANGOS rom_root uses this
# short alias. /storage is recreated on every boot, so keep the symlink alive
# from an init service (also handles late card insertion/removal).

UUID=00000000-0000-0000-0000-000000000001
TAG=ngp-eeroms

while true; do
    if [ -d "/storage/$UUID" ] && [ ! -e /storage/EEROMS ]; then
        ln -s "/storage/$UUID" /storage/EEROMS 2>/dev/null && \
            log -t $TAG "linked /storage/EEROMS -> /storage/$UUID"
    fi
    sleep 5
done
