#!/system/bin/sh
# Флаги для меню u-boot общей карты dArkOS + GammaOS.
#
# Меню выбора системы (u-boot rg52mini-1.4 и новее) читает два файла
# в корне нашего загрузочного FAT (раздел dArkOS_Fat: на общей карте p5, на
# обычной p3). Содержимое не важно, проверяется наличие.
#
#   bootmenu_ready  меню вообще показывается. Есть, только когда GammaOS
#                   подготовила карту: мастер настройки дошёл до конца, и
#                   setup.sh создал /data/setupcompleted (папки ROMs, стартовые
#                   ромы). До этого u-boot сразу грузит GammaOS: иначе dArkOS
#                   увидел бы userdata без ROMs, а setup.sh после него стёр бы
#                   автосохранения *state.auto в ROMs. После сброса к заводским
#                   /data/setupcompleted нет - флаг снимается.
#   bootmenu_emmc   в меню есть пункт «Internal memory». Следует за тем же
#                   переключателем, что и «Reboot to eMMC» в меню кнопки питания:
#                   «Allow reboot to eMMC» в GammaOS Toolbox,
#                   persist.rg52.reboot_emmc.
#
# Скрипт приводит наличие файлов в соответствие с источниками и ничего не пишет,
# если они уже сходятся. Запускается на каждой загрузке, при смене переключателя
# и по окончании setup.sh (rg52-bootmenu.rc): обновление по воздуху и пересборка
# образа записывают FAT целиком, и файлы пропадают - на загрузке они
# возвращаются. На обычной карте файлы безвредны: меню там не включается.
#
# FAT монтируется сперва только для чтения; на запись - лишь при расхождении,
# и сразу размонтируется, чтобы u-boot читал чистую файловую систему.

DEV=/dev/block/by-name/dArkOS_Fat
MNT=/mnt/rg52-bootfat

log -t rg52-bootmenu "start" 2>/dev/null
[ -b "$DEV" ] || { log -t rg52-bootmenu "no $DEV, nothing to do"; exit 0; }

# Нужное состояние флагов: "<ready> <emmc>", по 0 или 1.
want() {
    r=0; [ -d /data/setupcompleted ] && r=1
    e=0; [ "$(getprop persist.rg52.reboot_emmc)" = 1 ] && e=1
    echo "$r $e"
}
have() {
    r=0; [ -e "$MNT/bootmenu_ready" ] && r=1
    e=0; [ -e "$MNT/bootmenu_emmc" ] && e=1
    echo "$r $e"
}
put() {   # $1 - файл, $2 - 0 или 1, $3 - текст
    if [ "$2" = 1 ]; then
        [ -e "$MNT/$1" ] || echo "$3" > "$MNT/$1"
    else
        rm -f "$MNT/$1"
    fi
}

mkdir -p "$MNT" || exit 0
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT INT TERM

# Повтор: если источник поменялся, пока скрипт работал, второй запуск службы
# init проглотит (oneshot уже идёт) - поэтому после записи всё читается
# заново, пока не сойдётся. Три прохода с запасом.
i=0
while [ "$i" -lt 3 ]; do
    i=$((i + 1))
    W=$(want)
    mount -t vfat -o ro "$DEV" "$MNT" 2>/dev/null ||
        { log -t rg52-bootmenu "cannot mount $DEV"; exit 0; }
    H=$(have)
    umount "$MNT" 2>/dev/null
    if [ "$H" = "$W" ]; then
        log -t rg52-bootmenu "flags ready/emmc = $H match, nothing to write"
        exit 0
    fi
    [ "$(blockdev --getro "$DEV" 2>/dev/null)" = 1 ] && blockdev --setrw "$DEV" 2>/dev/null
    mount -t vfat -o rw,sync "$DEV" "$MNT" 2>/dev/null ||
        { log -t rg52-bootmenu "cannot mount $DEV read-write"; exit 0; }
    set -- $W
    put bootmenu_ready "$1" "Show the u-boot boot menu: GammaOS has finished first-time setup (/data/setupcompleted)"
    put bootmenu_emmc "$2" "Show the Internal memory entry in the u-boot boot menu (GammaOS Toolbox: Allow reboot to eMMC)"
    sync
    umount "$MNT" 2>/dev/null || { sync; umount "$MNT"; }
    log -t rg52-bootmenu "flags ready/emmc: $H -> $W"
done
exit 0
