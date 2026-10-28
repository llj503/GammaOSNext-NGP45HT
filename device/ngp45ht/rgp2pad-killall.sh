#!/system/bin/sh
# 双按 Select+Start 时关掉后台的其它应用。
#
# 逻辑来自原始的 /vendor/bin/rgp2pad —— 那里全塞在 system() 的一行长命令里。
# 做法：先回桌面，再把所有非保活的应用都停掉。
#
# 保活列表沿用原移植作者的那一份。

KEEP='systemui|inputmethod|ext.services|process.acore|process.media|providers.|lineageos|protonaosp|daijishou|retrofront|launcher|home$|storageresize'

log() { echo "rgp2pad2: $*" > /dev/kmsg; }

input keyevent 3          # KEYCODE_HOME
sleep 0.5

PIDS=$(ps -A -o PID,UID,NAME | awk -v keep="$KEEP" 'NR>1 && $2>=10000 && $3 !~ keep {print $1}')

PKGS=""
for p in $PIDS; do
    pkg=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' '\n' | head -n1 | sed 's/:.*//')
    if [ -n "$pkg" ]; then
        case " $PKGS " in
            *" $pkg "*) ;;      # 已经停过
            *)
                PKGS="$PKGS $pkg"
                cmd activity force-stop "$pkg" && log "force-stop $pkg"
                ;;
        esac
    else
        kill -9 "$p" 2>/dev/null && log "kill9 $p (无包名)"
    fi
done
