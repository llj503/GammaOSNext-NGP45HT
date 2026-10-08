#!/system/bin/sh
# Флаг пункта «Internal memory» в меню u-boot общей карты dArkOS + GammaOS.
#
# Меню выбора системы (универсальный u-boot, сессия dualboot) показывает пункт
# загрузки с внутренней памяти, только если в корне нашего загрузочного FAT
# (раздел dArkOS_Fat: на общей карте p5, на обычной p3) лежит файл
# bootmenu_emmc. Содержимое не важно, проверяется наличие. Управляет им тот же
# переключатель, что и пунктом «Reboot to eMMC» в меню кнопки питания:
# «Allow reboot to eMMC» в GammaOS Toolbox, свойство persist.rg52.reboot_emmc.
#
# Скрипт приводит наличие файла в соответствие со свойством и ничего не пишет,
# если они уже сходятся. Запускается при смене свойства и на каждой загрузке
# (rg52-bootmenu.rc): обновление по воздуху и пересборка образа записывают FAT
# целиком, и файл пропадает - на загрузке он возвращается. На обычной карте
# файл безвреден: меню там не включается.
#
# FAT монтируется сперва только для чтения; на запись - лишь при расхождении,
# и сразу размонтируется, чтобы u-boot читал чистую файловую систему.

DEV=/dev/block/by-name/dArkOS_Fat
MNT=/mnt/rg52-bootfat
FLAG=bootmenu_emmc

log -t rg52-bootmenu "start" 2>/dev/null
[ -b "$DEV" ] || { log -t rg52-bootmenu "no $DEV, nothing to do"; exit 0; }

want() { [ "$(getprop persist.rg52.reboot_emmc)" = 1 ] && echo 1 || echo 0; }

mkdir -p "$MNT" || exit 0
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT INT TERM

# Повтор: если переключатель дёрнули, пока скрипт работал, второй запуск службы
# init проглотит (oneshot уже идёт) - поэтому после записи свойство читается
# заново, пока не сойдётся. Три прохода с запасом.
i=0
while [ "$i" -lt 3 ]; do
    i=$((i + 1))
    W=$(want)
    mount -t vfat -o ro "$DEV" "$MNT" 2>/dev/null ||
        { log -t rg52-bootmenu "cannot mount $DEV"; exit 0; }
    H=0; [ -e "$MNT/$FLAG" ] && H=1
    umount "$MNT" 2>/dev/null
    if [ "$H" = "$W" ]; then
        log -t rg52-bootmenu "flag $FLAG=$H matches persist.rg52.reboot_emmc, nothing to write"
        exit 0
    fi
    [ "$(blockdev --getro "$DEV" 2>/dev/null)" = 1 ] && blockdev --setrw "$DEV" 2>/dev/null
    mount -t vfat -o rw,sync "$DEV" "$MNT" 2>/dev/null ||
        { log -t rg52-bootmenu "cannot mount $DEV read-write"; exit 0; }
    if [ "$W" = 1 ]; then
        echo "Show the Internal memory entry in the u-boot boot menu (GammaOS Toolbox: Allow reboot to eMMC)" > "$MNT/$FLAG"
    else
        rm -f "$MNT/$FLAG"
    fi
    sync
    umount "$MNT" 2>/dev/null || { sync; umount "$MNT"; }
    log -t rg52-bootmenu "flag $FLAG set to $W"
done
exit 0
