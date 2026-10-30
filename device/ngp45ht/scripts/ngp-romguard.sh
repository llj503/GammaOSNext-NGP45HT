#!/system/bin/sh
# NGP45HT: 守住 TF2 -> ROMs 的两层 bind mount。
#
# 为什么需要常驻守护：
#   system_server 崩溃或被 Watchdog 打死之后会软重启，vold 随之重新初始化，
#   把 /data/media/0/ROMs 和 /storage/emulated/0/ROMs 上的 bind mount 清掉。
#   2026-10-30 实测：SurfaceFlinger 在 02:09:42 SIGSEGV（TransactionCallbackInvoker
#   ::addCallbackHandle 空指针），HWC 随后也崩，system_server 跟着重启（pid
#   882 -> 8686 -> 10882），两个 bind 全丢。后果是 /sdcard/ROMs 变成空目录
#   （甚至一度 "Transport endpoint is not connected"），所有从 /sdcard 读 ROM
#   的模拟器读不到文件 —— 表现就是"玩完一个游戏，再开别的就黑屏"。
#
#   ngp-fixup.sh 只在 boot_completed 跑一次，救不了之后发生的重启，所以单独
#   起一个常驻服务。判据用 /proc/self/mountinfo（精确），而不是"目录是否为空"
#   （空也可能是 TF2 没插），避免无谓的重复 mount。

TAG=ngp-romguard
T2=/storage/00000000-0000-0000-0000-000000000001
DST_BUILTIN=/data/media/0/ROMs          # MediaProvider 读这里，决定 /sdcard/ROMs 的内容
DST_SDCARD=/storage/emulated/0/ROMs     # azahar 等 root 进程读这里（FUSE 下 root 受限）

bound() { grep -q " $1 " /proc/self/mountinfo 2>/dev/null; }

log -t $TAG "start $(date +%H:%M:%S) tf2=$T2"

# 等 TF2 挂上来（开机早期 /storage/... 还没 ready）
i=0
while [ $i -lt 60 ]; do
    [ -d "$T2" ] && [ -n "$(ls "$T2" 2>/dev/null | head -1)" ] && break
    i=$((i + 1))
    sleep 2
done

while true; do
    if [ -d "$T2" ] && [ -n "$(ls "$T2" 2>/dev/null | head -1)" ]; then
        if ! bound "$DST_BUILTIN"; then
            if mount --bind "$T2" "$DST_BUILTIN" 2>/dev/null; then
                log -t $TAG "rebind $DST_BUILTIN"
            fi
        fi
        if [ -d "$DST_SDCARD" ] && ! bound "$DST_SDCARD"; then
            if mount --bind "$T2" "$DST_SDCARD" 2>/dev/null; then
                log -t $TAG "rebind $DST_SDCARD"
            fi
        fi
    fi
    sleep 5
done
