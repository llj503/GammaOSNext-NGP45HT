#!/system/bin/sh
# RG52 Mini: растянуть userdata на всю SD-карту при первой загрузке.
#
# Заменяет собой rg52-resize-{grow,expand}.sh и APK RG52StorageResize из порта
# Android 13 — они лежали на /system и вместе с ним исчезают. Две ступени,
# потому что таблицу разделов ядро перечитывает только после перезагрузки:
#   ступень 1  растянуть раздел userdata до конца карты (sgdisk), перезагрузиться
#   ступень 2  дорастить файловую систему на уже смонтированном /data (resize2fs)
#
# Метки лежат на /metadata, чтобы стирание /data не заставляло всё повторять.
# Метка первой ступени пишется ДО перезагрузки: даже если sgdisk отработает
# неудачно, устройство не уйдёт в бесконечную перезагрузку, а просто останется
# с маленьким /data.
#
# Разбор вывода sgdisk намеренно сделан на sed + tr без классов и \x27:
# в Android sed от toybox, и расширенные конструкции GNU там не гарантированы.

GROWN=/metadata/rg52_resize_stage1_grown
DONE=/metadata/rg52_resize_done
LOG=/metadata/rg52_resize.log

log() { echo "rg52-resize: $*" > /dev/kmsg; echo "$(date) $*" >> "$LOG"; }

[ -e "$DONE" ] && exit 0

# Раздел userdata ищется по имени, а не по номеру: на общей карте dArkOS + GammaOS
# (сессия dualboot, 08.10.2026) у него другой номер, чем на нашей (p9), и номер
# может поменяться при любой перестановке разделов. Диск - родитель раздела в
# sysfs, номер - его атрибут partition.
PART=$(readlink -f /dev/block/by-name/userdata 2>/dev/null)
PNAME=${PART##*/}
[ -n "$PNAME" ] && [ -b "$PART" ] && [ -e "/sys/class/block/$PNAME/partition" ] ||
    { log "no userdata partition by name, nothing to do"; exit 0; }
NUM=$(cat "/sys/class/block/$PNAME/partition" 2>/dev/null)
DNAME=$(readlink -f "/sys/class/block/$PNAME/.." 2>/dev/null); DNAME=${DNAME##*/}
DEV=/dev/block/$DNAME
[ -n "$NUM" ] && [ -b "$DEV" ] || { log "cannot resolve disk of $PART"; exit 0; }

TOTAL=$(blockdev --getsz "$DEV" 2>/dev/null)
START=$(cat "/sys/class/block/$PNAME/start" 2>/dev/null)
SIZE=$(cat "/sys/class/block/$PNAME/size" 2>/dev/null)
[ -z "$TOTAL" ] || [ "$TOTAL" = "0" ] && { log "blockdev returned nothing"; exit 0; }
[ -z "$START" ] || [ -z "$SIZE" ] && { log "sysfs empty"; exit 0; }
CUREND=$((START + SIZE - 1))

# Растягивать можно только последний по расположению раздел: если за userdata
# лежит ещё какой-то, свободного места за ним нет, а пересоздание раздела было
# бы впустую. Тогда первая ступень пропускается целиком.
LAST=1
for q in /sys/class/block/${DNAME}p*; do
    [ -e "$q/start" ] || continue
    [ "$(cat "$q/start" 2>/dev/null)" -gt "$START" ] 2>/dev/null && { LAST=; break; }
done
if [ -z "$LAST" ] && [ ! -e "$GROWN" ]; then
    log "userdata ($PNAME) is not the last partition on $DEV, not growing it"
    : > "$GROWN"; : > "$DONE"; sync
    exit 0
fi

if [ ! -e "$GROWN" ]; then
    if [ "$CUREND" -ge $((TOTAL - 34)) ]; then
        log "partition already fills the card ($CUREND of $TOTAL)"
        : > "$GROWN"; sync
    else
        log "stage 1: growing $PNAME (partition $NUM) from $CUREND to $((TOTAL - 34)) (card $TOTAL sectors)"
        INFO=$(sgdisk --info=$NUM "$DEV" 2>/dev/null)
        TYPE=$(echo "$INFO" | sed -n "s/^Partition GUID code: //p" | cut -d' ' -f1)
        GUID=$(echo "$INFO" | sed -n "s/^Partition unique GUID: //p" | cut -d' ' -f1)
        NAME=$(echo "$INFO" | sed -n "s/^Partition name: //p" | tr -d "'")
        [ -z "$TYPE" ] && TYPE=0FC63DAF-8483-4772-8E79-3D69D8477DE4
        [ -z "$NAME" ] && NAME=userdata
        log "type=$TYPE guid=$GUID name=$NAME"

        # метку пишем первой: одна попытка, и никакого бутлупа
        : > "$GROWN"; sync

        sgdisk --move-second-header "$DEV" 2>&1 | while read -r l; do log "sgdisk-e: $l"; done
        if [ -n "$GUID" ]; then
            sgdisk --delete=$NUM --new=$NUM:${START}:0 --typecode=$NUM:${TYPE} \
                   --partition-guid=$NUM:${GUID} --change-name=$NUM:${NAME} "$DEV" 2>&1 |
                while read -r l; do log "sgdisk: $l"; done
        else
            log "WARNING: partition GUID unreadable, by-partuuid may break"
            sgdisk --delete=$NUM --new=$NUM:${START}:0 --typecode=$NUM:${TYPE} \
                   --change-name=$NUM:${NAME} "$DEV" 2>&1 |
                while read -r l; do log "sgdisk: $l"; done
        fi
        sync

        NEWEND=$(sgdisk --info=$NUM "$DEV" 2>/dev/null | sed -n "s/^Last sector: //p" | cut -d' ' -f1)
        if [ -n "$NEWEND" ] && [ "$NEWEND" -gt "$CUREND" ]; then
            log "stage 1 done: $CUREND -> $NEWEND, rebooting"
            sync
            setprop sys.powerctl reboot,resize
            exit 0
        fi
        log "stage 1 FAILED: end $NEWEND, was $CUREND; /data stays small"
    fi
fi

# ступень 2
BEFORE=$(df -k /data 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f2)
OUT=$(resize2fs -f "$PART" 2>&1); RC=$?
echo "$OUT" | while IFS= read -r l; do log "resize2fs: $l"; done
AFTER=$(df -k /data 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f2)
log "stage 2, rc=$RC, /data was ${BEFORE}K now ${AFTER}K"
: > "$DONE"; sync
exit 0
