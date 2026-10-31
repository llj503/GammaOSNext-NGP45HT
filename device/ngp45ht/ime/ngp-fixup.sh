#!/system/bin/sh
# NGP45HT 开机修正：默认桌面、默认输入法、显示方向等一次性收尾
#
# 输入法这块的背景（三层叠加，缺一不可）：
#   1. 镜像默认把两个输入法包都禁用了 —— com.android.inputmethod.leanback
#      和 com.liskovsoft.leankeyboard 都在 `pm list packages -d` 里，
#      包被禁用 => IME 服务起不来 => InputMethodManager 报 mCurId=null /
#      mHaveConnection=false => 任何应用调键盘都失败。
#   2. /system/bin/rg52-ime.sh（上游 RG52 的脚本）在 boot_completed 后
#      每 2 秒刷一次、连刷 30 次，把 default_input_method 强制设成
#      com.liskovsoft.leankeyboard —— 正好是启不来的那个。
#   3. 该脚本自带逃生门：读 persist.rg52.ime，设了它就用它。
#
# 这里：① 启用内置的手柄拼音 ngp-pinyin 并设成默认；
#       ② 用 persist.rg52.ime 改掉 rg52-ime.sh 的强制目标；
#       ③ 等它的 60 秒循环跑完，再收尾设置一次（双保险）。

TAG=ngp-fixup

# 内置输入法：手柄拼音 ngp-pinyin（见 github.com/llj503/ngp-pinyin-ime）。
# 镜像里放在 /system/app/NgpIme/NgpIme.apk，刷完即存在，不需要用户再装。
NGP_IME=com.llj.ngpime/.NgpImeService
NGP_PKG=com.llj.ngpime
AOSP_IME=com.android.inputmethod.leanback/.service.LeanbackImeService
LEANKEY_IME=com.liskovsoft.leankeyboard/.ime.LeanbackImeService

# 默认取 ngp-pinyin；persist.rg52.ime 是上游 rg52-ime.sh 的逃生门，
# 用户显式设过就尊重它 —— 但设的包已经不存在时（比如换过输入法），
# 继续沿用只会让 rg52-ime.sh 反复指向一个空组件，这时回落到 ngp-pinyin。
IME_ID=$(getprop persist.rg52.ime)
if [ -n "$IME_ID" ] && ! pm path "${IME_ID%%/*}" >/dev/null 2>&1; then
    log -t $TAG "stale persist.rg52.ime=$IME_ID, falling back"
    IME_ID=
fi
if [ -z "$IME_ID" ]; then
    if pm path $NGP_PKG >/dev/null 2>&1; then
        IME_ID=$NGP_IME
    else
        IME_ID=$AOSP_IME
    fi
fi

log -t $TAG "start"

# ⓪a 默认桌面：固定为 LANGOS（com.retrofront）。
#
# LANGOS 已内置在 /system/app/LANGOS，刷完即是默认桌面，不依赖 Daijishō。
# 上游 /system/bin/rg52-home.sh 守的是 Daijishō —— 包不在时只打一条 warning
# 就退出，等于没人兜底，home 偏好一丢就停在选择框。这里每次开机都显式指定
# 一次（幂等，成本一条 cmd）。
# 注意：必须确认包存在再设，指向不存在的组件会让 home 永久解析失败。
if pm path com.retrofront >/dev/null 2>&1; then
    cmd package set-home-activity --user 0 com.retrofront/.NativeActivity >/dev/null 2>&1
    log -t $TAG "home -> com.retrofront/.NativeActivity"

    # MANAGE_EXTERNAL_STORAGE 是 LANGOS 扫 ROM 目录用的。
    # 内置到 /system/app 后它仍需要这条授权，否则读不到存储卡。
    appops set com.retrofront MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1
fi

# ⓪a-2 存储竞态：LANGOS 作为桌面会比 vold 先起，那时 TF2 还没挂上，
#   它读不到上次记下的 rom_root 就直接拉起 SAF 目录选择框（开机必现）。
#   等 public 卷挂载完成后，如果前台仍是 documentsui 的选择页，重启一次
#   LANGOS —— 实测重启后直接进游戏库，不再弹框。
if pm path com.retrofront >/dev/null 2>&1; then
    _i=0
    while [ "$_i" -lt 15 ]; do
        sm list-volumes all 2>/dev/null | grep -q 'public:.*mounted' && break
        sleep 2
        _i=$((_i + 1))
    done
    # 选择框可能在存储挂上后几秒才弹，轮询 5 次（10 秒）
    _j=0
    while [ "$_j" -lt 5 ]; do
        if dumpsys window 2>/dev/null | grep -q 'documentsui.*PickActivity'; then
            am force-stop com.android.documentsui >/dev/null 2>&1
            am force-stop com.retrofront >/dev/null 2>&1
            sleep 1
            am start -n com.retrofront/com.retrofront.NativeActivity >/dev/null 2>&1
            log -t $TAG "storage came late: launcher relaunched"
            break
        fi
        sleep 2
        _j=$((_j + 1))
    done
fi

# ⓪c 锁定显示方向：让 WindowManager 忽略应用自己请求的 screenOrientation。
#
# 现象：首次开机向导、系统设置、RetroArch 等界面整个转 180 度（上下颠倒），
#   而 nano 自己的界面是正的。
# 根因：这些应用在 manifest 里请求 REVERSE_LANDSCAPE(8)，而本机
#   ro.surface_flinger.primary_display_orientation 是 ORIENTATION_0，
#   DisplayRotation 按 8 算出 ROTATION_180：
#     mLastOrientation=8 / mRotation=2   （颠倒）
#   nano 不受影响，是因为它读的是 DRM 硬件的 physical=2，自己再转 2 次抵消。
#
# 修法要两条一起用（实测对照）：
#   1) `wm set-ignore-orientation-request true`
#      在这台 ROM 上设完 1 秒内就会被复位 —— dumpsys 里的
#      `mSetIgnoreOrientationRequest=true` 只是"最后一次调用值"的记录，
#      `mRotation` 始终是 2。单靠它没用。
#   2) `wm fixed-to-user-rotation enabled`  ← 真正生效的那条
#      设完立刻：mFixedToUserRotation=true / mLastOrientation=-1 / mRotation=0，
#      10 秒后仍然保持，启动 RetroArch 后也保持。
#      它是把 display 固定跟随 user_rotation（本机 0），彻底不理会 app 请求。
#
# 与 nano 不冲突：nano 的 physical 读的是 DRM 层，不受 WM rotation 影响，
#   rotation 变 0 之后 nano 仍然 physical=2 / renderSelfRot=2，界面照样正。
#
# 只在开机执行一次，不做循环。
wm fixed-to-user-rotation enabled 2>/dev/null
wm set-ignore-orientation-request true 2>/dev/null
log -t $TAG "display rotation locked: fixed=$(dumpsys window 2>/dev/null | grep -o 'mFixedToUserRotation=[a-z]*' | head -n 1)"

# ⓪b 鼠标模式（gammapad）屏幕尺寸同步 —— 只做一次，不做常驻轮询。
#
# 现象：`wm size 640x480` 之后鼠标指针能看见，但点击落点整体偏移，越往
#       右下偏得越多。
#
# 根因（反汇编 gammapad + 运行时验证）：
#   1. MouseMode 的屏幕尺寸只在 loadConfig() / setActive(true) 里探测一次，
#      tick() / processEvent() 都不重新探测，改分辨率它不知道。
#   2. VirtualMouse::create(w,h) 把 ABS_X / ABS_Y 的 absinfo max 写死成
#      w-1 / h-1，指针坐标系在创建那一刻就固定了。
#   3. 探测链第一个来源是属性 persist.gammaos.gamepad.screen_w/screen_h，
#      这两个属性 gammapad 只读不写；缺省就落到 fb0 ioctl，而 fb0 永远报
#      物理分辨率（wm size 只改 SurfaceFlinger 的 override DisplayInfo，
#      不改 fb）。
#
# 这里在开机时把 `wm size` 的当前值写进那两个属性。
#
# 注意：早期版本在这段后面挂了个每 2 秒轮询的看门狗，全新刷机会不断 fork
#   `wm`（Java 进程，几十 MB），SurfaceFlinger 没就绪时进程堆积到内存耗尽，
#   表现就是开机反复重启。所以现在只做一次，不做常驻循环。
#   改完分辨率后想让指针重新对齐，重启一次 gammapad 或整机即可。
ngp_wm_size() {
    _out=$(wm size 2>/dev/null)
    _res=$(printf '%s\n' "$_out" | sed -n 's/.*Override size: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1x\2/p' | tail -n 1)
    [ -z "$_res" ] && \
        _res=$(printf '%s\n' "$_out" | sed -n 's/.*Physical size: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1x\2/p' | tail -n 1)
    NGP_W=${_res%x*}
    NGP_H=${_res#*x}
}

ngp_sync_screen_once() {
    ngp_wm_size
    case "$NGP_W" in ''|*[!0-9]*) return 1 ;; esac
    case "$NGP_H" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$(getprop persist.gammaos.gamepad.screen_w)" = "$NGP_W" ] && \
       [ "$(getprop persist.gammaos.gamepad.screen_h)" = "$NGP_H" ]; then
        return 0
    fi
    setprop persist.gammaos.gamepad.screen_w "$NGP_W"
    setprop persist.gammaos.gamepad.screen_h "$NGP_H"
    log -t $TAG "gammapad screen -> ${NGP_W}x${NGP_H}"

    # 服务还没起来就别动它：init 拉起时会自己读刚写好的属性。
    [ "$(getprop init.svc.gammapad)" = "running" ] || return 0

    # 已在运行：重启一次让它重新探测。等 init 状态机走完，
    # 避免新旧两个实例并存（各建一个 VirtualMouse 就成了两个光标）。
    setprop ctl.stop gammapad
    _n=0
    while [ "$_n" -lt 20 ]; do
        [ "$(getprop init.svc.gammapad)" = "stopped" ] && break
        sleep 0.25
        _n=$((_n + 1))
    done
    pidof gammapad >/dev/null 2>&1 && { killall -9 gammapad 2>/dev/null; sleep 0.5; }
    setprop ctl.start gammapad
    log -t $TAG "gammapad restart requested"
}

ngp_sync_screen_once


# ⓪ Nano 模式方向修正（必须在 gammaos-nano 起渲染之前写好，
#    所以这一段放在脚本最前面；boot_completed 时 nano 的 home 已经
#    起来了，改属性对"下一次进 nano"生效，正好是我们要的语义）。
#
# 现象：第一次进 nano 模式整个界面是上下翻转的，随便开一个游戏后重启
#       才恢复正常。
#
# 根因（反汇编 gammaos-nano 确认）：
#   gammaos-nano 计算 DRM 旋转矩阵时读的是
#     ro.surface_flinger.primary_display_orientation
#   只认 ORIENTATION_90 / ORIENTATION_180 / ORIENTATION_270 三个值，
#   换算成 90/180/270 度。本机该属性是 ORIENTATION_0 => 换算角度 0。
#   而代码里角度为 0 时不是"用单位阵"，而是直接 b.eq 跳过整个矩阵
#   初始化块（0x15d2b8 -> 0x15d33c），矩阵留在未初始化的状态，
#   首次运行的栈内容不确定 => 画面翻转；重启后栈布局稳定 => 看起来"好了"。
#   所以"重启一次就正常"不是修好了，是撞对了。
#
# 修法：把 persist.gammaos.nano.orientation 设成 rev_landscape。
#   gammaos-nano 会打印 nano: force_orientation=rev_landscape，
#   走 DRM 自家方向路径，不再依赖那个残缺的 installOrientation 分支。
#   实测 rev_landscape 是正的（landscape / drm_flip_v=1 都还是倒的）。
#
# 只在值缺失或不合法时写，用户自己改成 portrait 之类的不动。
NANO_ORIENT=$(getprop persist.gammaos.nano.orientation)
case "$NANO_ORIENT" in
    auto|landscape|rev_landscape|portrait|rev_portrait)
        log -t $TAG "nano orientation kept: $NANO_ORIENT" ;;
    *)
        setprop persist.gammaos.nano.orientation rev_landscape
        log -t $TAG "nano orientation fixed: '$NANO_ORIENT' -> rev_landscape" ;;
esac
# drm_flip_h/v 是用户级微调，默认必须是 0；这两个值非 0 会叠加翻转。
[ "$(getprop persist.gammaos.nano.drm_flip_h)" = "" ] && \
    setprop persist.gammaos.nano.drm_flip_h 0
[ "$(getprop persist.gammaos.nano.drm_flip_v)" = "" ] && \
    setprop persist.gammaos.nano.drm_flip_v 0

# ① 启用 AOSP leanback 输入法（幂等）
pm enable com.android.inputmethod.leanback >/dev/null 2>&1

# ② 改掉 rg52-ime.sh 的强制目标
setprop persist.rg52.ime $IME_ID

# ②b 性能悬浮窗：默认不开，需要时点桌面「NGP 悬浮窗开关」图标。
#
#   帧率来自 SurfaceFlinger TimeStats，需要 root；而 app 进程 CapBnd 为空，
#   调 su 提权必然 EPERM（Android 设计），所以拆成"root 守护进程写文件、
#   app 读文件"两个进程：
#     - ngp-statd 由 init 起（/vendor/etc/init/ngp-statd.rc）常驻，但只在
#       com.ngp.overlay 进程存在时才真正采样；app 没开就 5 秒空转一次，
#       完全不碰 SurfaceFlinger（每次采样都要 fork 一个 dumpsys/JVM，
#       不开悬浮窗时没必要付这笔开销）。
#     - app 自己也不许开机自启：manifest 里有 BOOT_COMPLETED 接收器，
#       这里用 appops 掐掉。桌面图标（ToggleActivity）手动点仍然正常。
if [ -x /vendor/bin/ngp-statd ] && ! pidof ngp-statd >/dev/null 2>&1; then
    # init 服务没起来时补拉一次（不是循环，避免早期那种常驻轮询的坑）
    setprop ctl.start ngp_statd >/dev/null 2>&1
fi
if pm path com.ngp.overlay >/dev/null 2>&1; then
    appops set com.ngp.overlay SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1

    # 掐掉开机自启：只把 BOOT_COMPLETED / MY_PACKAGE_REPLACED 这个接收器
    # 组件禁掉，包本身不禁用，桌面图标（ToggleActivity）与手动 am start
    # 都不受影响。
    #
    # 为什么不用别的写法（都实测过）：
    #   - `cmd appops set ... BOOT_COMPLETED ignore` → 本机报
    #     Unknown operation string，这个 ROM 上没有该 op 名；
    #   - `am set-standby-bucket ... restricted` → 能拦住开机广播，但
    #     用户每打开一次 app，系统就把它重置回 active，等于没设；
    #   - 只靠 force-stop → 有效且 stopped 状态能跨重启，但用户用过一次
    #     就会清掉标记，下次开机又自启。
    pm disable com.ngp.overlay/.BootReceiver >/dev/null 2>&1

    # 首次开机兜底：/data 全新时上面那条还没执行过，BootReceiver 已经把
    # 悬浮窗拉起来了，这里停掉（顺带把 app 置为 stopped 状态）。
    am force-stop com.ngp.overlay >/dev/null 2>&1

    log -t $TAG "overlay: autostart off, open from launcher"
fi

# ③ 等 rg52-ime.sh 的 60 秒循环跑完，再定终态输入法。
#
# 为什么必须是这个顺序：rg52-ime.sh 在 boot_completed 后每 2 秒刷一次
# default_input_method、连刷 30 次，抢在它前面设没用。它读 persist.rg52.ime
# 当目标（上面已经写好），所以循环跑完后终态就是我们要的那个 —— 这里再补
# 一次是双保险，覆盖 rg52-ime.sh 因故没跑的情况。
#
# 系统自带的两个键盘（AOSP leanback、LeanKey）都只有英文，没有中文拼音，
# 所以默认必须落在 ngp-pinyin 上。
sleep 70

# enabled_input_methods 必须先写全，否则 ime set 会报
# "Unknown input method ... cannot be selected for user #0"。
# 保留 leanback / LeanKey 是为了系统里还有可切换的英文键盘。
settings put secure enabled_input_methods \
    "$NGP_IME:$AOSP_IME:$LEANKEY_IME" >/dev/null 2>&1
ime enable $NGP_IME >/dev/null 2>&1
ime enable $AOSP_IME >/dev/null 2>&1

if [ "$(settings get secure default_input_method 2>/dev/null)" != "$IME_ID" ]; then
    ime set "$IME_ID" >/dev/null 2>&1
fi

log -t $TAG "ime -> $(settings get secure default_input_method 2>/dev/null)"

# ④ 联网验证改用国内可达的探测点。
#    默认是 connectivitycheck.gstatic.com/generate_204，国内连不上 =>
#    系统判"受限/未连接互联网"，但实际能上网。
settings put global captive_portal_http_url "http://connect.rom.miui.com/generate_204"
settings put global captive_portal_https_url "https://connect.rom.miui.com/generate_204"
settings put global captive_portal_fallback_url "http://connect.rom.miui.com/generate_204"
settings put global captive_portal_use_https 0
log -t $TAG "captive portal -> miui"

# ⑤ 把第二张 TF 卡挂进 /data/media/0/ROMs，供 nano 前端扫描。
#
# nano（gammaos-nano 的 XMB 前端）只认 /data/media/0/ROMs/<平台>/，而 ROM 全在
# 第二张 TF 卡上（vold 给的占位 UUID 挂载点），它的根目录直接就是平台目录，
# 没有 ROMs 这一层。
#
# 符号链接不行：/storage/emulated/0 是 MediaProvider 的 FUSE，ln -s 之后
# ls 直接报 "Function not implemented"（实测）。bind mount 可以 —— FUSE 会把
# bind 的内容透出来，nano 实测能扫到（NES 295 / SNES 300 款）。
#
# 一次 bind 整个 TF2 根目录。早先试过逐平台 bind：174 个目录每个都要走 FUSE
# 判空再 mount，5 分钟都跑不完；而且 /data/media/0/ROMs 下本来就没有 3ds 这类
# 目录（只有 174 个旧平台名），逐平台挂根本挂不全。
#
# 内置存储自带的 210 个示例游戏先挪到 ROMs.builtin（只挪一次，不删）。
T2=/storage/00000000-0000-0000-0000-000000000001
if [ -d "$T2" ]; then
    if [ -d /data/media/0/ROMs ] && [ ! -e /data/media/0/ROMs.builtin ]; then
        mv /data/media/0/ROMs /data/media/0/ROMs.builtin 2>/dev/null &&
            log -t $TAG "builtin roms -> ROMs.builtin"
    fi
    mkdir -p /data/media/0/ROMs
    if mount --bind "$T2" /data/media/0/ROMs 2>/dev/null; then
        log -t $TAG "tf2 roms bound"
    else
        log -t $TAG "tf2 roms bind failed"
    fi
fi

# ⑥ 让 azahar-nano 能读 /sdcard/ROMs/ 下的 ROM。
#
# nano（XMB 前端）点 3DS 游戏时，传给 azahar-nano 的路径是
# /sdcard/ROMs/3ds/<rom>（硬编码在二进制里，改不了）。
#
# 而 /sdcard -> /storage/self/primary -> /storage/emulated/0，最后一层是
# MediaProvider 的 FUSE。FUSE 给 root 列目录，但打开文件会失败 ——
# dd 报 Bytes address，azahar-nano 报：
#   Loader <Error> GetLoader:159: Failed to load file !/sdcard/ROMs/3ds/x.cci
#   Core <Critical> Load:671: Failed to obtain loader for !/sdcard/ROMs/3ds/x.cci
# 8 毫秒后 core shutdown，用户看到的就是点游戏闪退回桌面。
#
# （/data/media/0/ROMs 上第 ⑤ 段 bind 的那层同样被 FUSE 盖住了：mount 表里
# 它显示为 /dev/fuse on /data/media/0/ROMs。FUSE 透传内容，nano 扫描没问题，
# 但 root 打开文件依旧失败。所以要在 FUSE 视图上再压一层 vfat。）
if [ -d "$T2" ] && [ -d /storage/emulated/0/ROMs ]; then
    if mount --bind "$T2" /storage/emulated/0/ROMs 2>/dev/null; then
        log -t $TAG "tf2 roms bound for azahar (/sdcard)"
    else
        log -t $TAG "tf2 roms bind for azahar failed"
    fi
fi

# ⑦ 手柄自愈。
#
# gammapad 启动时会做一次 re-hid：grab 物理手柄 → 读能力位 → unregister 物理
# input device（把它从 Android 视野里藏掉）→ 注册一个同 VID/PID 的虚拟手柄冒充。
# 正常时 /dev/input/event3 消失、虚拟的 /dev/input/event4 顶上，用户无感。
#
# 但有时序竞态：偶尔它会卡在
#   gammapad: Re-hid reappeared source node: /dev/input/event3 (major=13 minor=67)
# 每秒一条无限重试，虚拟手柄也收不到事件。表现就是"系统假死、所有按键失效"
# —— 2026-10-30 凌晨就中过一次，从 23:53 一直坏到早上 08:03 才被发现。
#
# 官方留了 /system/bin/gammapad_restore 干这个（gammapad_restore 会把物理手柄的
# evdev 重新注册回来），只是没做自动触发。这里补上。
#
# 判据（三条，任一命中就修）：
#   1. 物理和虚拟手柄的节点一个都打不开
#   2. logcat 里 Re-hid reappeared 超过 5 条（正常是 0 条，卡住时每秒 +1）
# 注意：**不能看 sysfs 判断**。物理设备被摘掉后 /sys/class/input/event3 还在、
# dev 还是 13:67、/proc/devices 里 13 input 也在，但内核 cdev 已经没了，
# open 会报 ENOENT。只有 getevent 能反映真实可用性。
if [ "$(getprop persist.gammaos.gamepad.enable 2>/dev/null)" = "1" ]; then
    _phys=0
    _virt=0
    for _e in /dev/input/event*; do
        _nm=$(getevent -i "$_e" 2>/dev/null | grep -m1 "name:")
        case "$_nm" in
            *retrogame_joypad*)           _phys=1 ;;
            *"Xbox Wireless Controller"*) _virt=1 ;;
        esac
    done
    _rehid=$(logcat -d -s gammapad 2>/dev/null | grep -c "Re-hid reappeared")
    [ -z "$_rehid" ] && _rehid=0

    _bad=""
    if [ "$_phys" = "0" ] && [ "$_virt" = "0" ]; then
        _bad="no node"
    elif [ "$_rehid" -gt 5 ]; then
        _bad="rehid loop $_rehid"
    fi

    if [ -z "$_bad" ]; then
        log -t $TAG "gamepad ok (phys=$_phys virt=$_virt rehid=$_rehid)"
    else
        log -t $TAG "gamepad bad ($_bad), restoring"
        stop gammapad 2>/dev/null
        /system/bin/gammapad_restore 2>/dev/null
        sleep 1
        start gammapad 2>/dev/null
        sleep 8
        # 修完再验一次：还是坏的就把 gammapad 关掉，至少保证物理手柄能用
        _ok2=0
        for _e in /dev/input/event*; do
            _nm=$(getevent -i "$_e" 2>/dev/null | grep -m1 "name:")
            case "$_nm" in
                *retrogame_joypad*|*"Xbox Wireless Controller"*) _ok2=1 ;;
            esac
        done
        _rehid2=$(logcat -d -s gammapad 2>/dev/null | grep -c "Re-hid reappeared")
        [ -z "$_rehid2" ] && _rehid2=0
        if [ "$_ok2" = "0" ] || [ "$_rehid2" -gt "$((_rehid + 5))" ]; then
            log -t $TAG "gamepad still bad (rehid=$_rehid2), leaving gammapad off"
            stop gammapad 2>/dev/null
            /system/bin/gammapad_restore 2>/dev/null
        else
            log -t $TAG "gamepad recovered (rehid=$_rehid2)"
        fi
    fi
fi

# ⑧ RetroArch 简体中文 + CJK 字体。
#
# RA 的 ozone/xmb 菜单默认用内置 ASCII 字体，没有 CJK 字形 —— 语言切到中文后
# 所有汉字都变成方框。又因为系统自带的 NotoSansCJK 是 .ttc collection，RA 用的
# stb_truetype 不支持 collection，指过去也无效，必须用单文件 ttf。
#
# /system/fonts/CarroisGothicSC-Regular.ttf 是镜像里现成的纯 ttf 简体中文字体
# （40 KB，md5 a43f5aaf82ae9d3e3dbfc2dde2c0ba88），复制到 RA 的 files 目录再把
# 三个字体项指过去即可。
#
# 语言编号别写错：1.22.1 里 12 = 简体中文，11 = 繁体，10 = 韩语。
# （2026-10-14 在 v3/EmuELEC 时代记的是 11，那是老版本 RA 的编号，迁移到
#   GammaOS 的 1.22.1 上就变成繁体了，2026-10-30 在这台机上重新校对过。）
RA_DIR=/storage/emulated/0/Android/data/com.retroarch.aarch64/files
if [ -d "$RA_DIR" ]; then
    RA_FONT=$RA_DIR/zh-CN.ttf
    RA_CFG=$RA_DIR/retroarch.cfg
    if [ ! -f "$RA_FONT" ]; then
        cp -f /system/fonts/CarroisGothicSC-Regular.ttf "$RA_FONT" 2>/dev/null &&
            log -t $TAG "retroarch zh font installed"
    fi
    if [ -f "$RA_FONT" ] && [ -f "$RA_CFG" ]; then
        RA_UID=$(stat -c %u /data/data/com.retroarch.aarch64 2>/dev/null)
        [ -n "$RA_UID" ] && chown "$RA_UID:ext_data_rw" "$RA_FONT" 2>/dev/null
        chmod 660 "$RA_FONT" 2>/dev/null

        # 只在还是出厂英文（0）时改成简体中文，用户手动选过的语言尊重不动
        if grep -q '^user_language = "0"' "$RA_CFG"; then
            sed -i 's|^user_language = .*|user_language = "12"|' "$RA_CFG"
            log -t $TAG "retroarch language -> zh_CN(12)"
        fi
        # 字体项只在空值时填，用户自己换了字体就不动
        for _k in ozone_font xmb_font video_font_path; do
            if grep -q "^$_k = \"\"" "$RA_CFG"; then
                sed -i "s|^$_k = .*|$_k = \"$RA_FONT\"|" "$RA_CFG"
            fi
        done
        if [ -n "$RA_UID" ]; then
            chown "$RA_UID:ext_data_rw" "$RA_CFG" 2>/dev/null
            chmod 660 "$RA_CFG" 2>/dev/null
        fi
        log -t $TAG "retroarch zh: lang=$(grep -m1 '^user_language' "$RA_CFG" | cut -d'"' -f2)"
    fi
fi

# ⑨ 3DS（azahar-nano）游戏内菜单汉化
#
# 前端的菜单文本是编译进二进制的 const char* 字面量，没有 i18n 框架，
# 汉化就是改.rodata 引用：把 locale 串池追加到文件末尾，再重写
# adrp+add 指令对（aarch64 没有 32 位绝对地址，放不下指针）。
# /vendor/bin/azahar-nano-zh 是打好补丁的前端，md5 记在 azahar/README.md。
#
# /system 是整块只读挂载（/dev/block/mmcblk1p4 on / type ext4 ro），
# 改不了文件，只能用 bind mount 盖上去。注意不能直接 exec
# /vendor/bin/azahar-nano-zh —— 那样 /proc/self/exe 落在 vendor 命名空间，
# linker 找不到 /system/lib64/libgui.so，报 CANNOT LINK EXECUTABLE。
# bind 到 /system/bin 之后路径是 system 的，一切正常。
#
# 源文件不存在或 bind 失败都保持原版，不会把 3DS 弄坏。
AZH_SRC=/vendor/bin/azahar-nano-zh
AZH_DST=/system/bin/azahar-nano
if [ -x "$AZH_SRC" ] && [ -f "$AZH_DST" ]; then
    if grep -q " $AZH_DST " /proc/self/mountinfo 2>/dev/null; then
        log -t $TAG "azahar zh: already bound"
    elif mount --bind "$AZH_SRC" "$AZH_DST" 2>/dev/null; then
        log -t $TAG "azahar zh: bind ok ($(stat -c %s "$AZH_DST" 2>/dev/null) B)"
    else
        log -t $TAG "azahar zh: bind FAILED, keeping stock frontend"
    fi
fi

# 段名同时也是 config.ini 的 section 名，汉化后旧配置的 [Audio] 之类就找不到
# 了，那些值会回落到默认。升级上来的机器做一次性迁移；全新刷机时 config.ini
# 还不存在（首次运行才生成，生成的就是中文段名），这段自然跳过。
AZH_CFG=/data/system/azahar-nano/config/config.ini
if [ -f "$AZH_CFG" ] &&
   grep -qE '^\[(Audio|Controls|Core|Layout|Renderer|System)\]' "$AZH_CFG" &&
   ! grep -qE '^\[(音频|控制|核心|布局|渲染|系统)\]' "$AZH_CFG"; then
    cp -f "$AZH_CFG" "$AZH_CFG.bak-en" 2>/dev/null
    sed -i \
        -e 's/^\[Controls\]/[控制]/' \
        -e 's/^\[Core\]/[核心]/' \
        -e 's/^\[Renderer\]/[渲染]/' \
        -e 's/^\[Layout\]/[布局]/' \
        -e 's/^\[Audio\]/[音频]/' \
        -e 's/^\[System\]/[系统]/' \
        "$AZH_CFG" 2>/dev/null &&
        log -t $TAG "azahar zh: config sections migrated (bak-en kept)"
fi

# ⑩ gammapad 按键重映射：菜单键(BTN_MODE 316) -> BACK(158)
# 默认 gammapad 把 316 映射成 172(KEY_HOMEPAGE)，按下就直接回桌面，
# 游戏里根本弹不出菜单。改成 BACK 后：LANGOS/桌面 里 BACK 也是回上一层，
# 行为不变；NetherSX2 收到 BACK 会弹暂停菜单。
# persist.* 存在 /data/property，刷机后丢失，所以每次开机都要补一遍。
CUR_RM=$(getprop persist.gammaos.gamepad.remap_btn)
case "$CUR_RM" in
    *316:158*)
        : # 已经是目标值
        ;;
    *)
        # 先把已有的 316:x 摘掉，避免出现两条
        REST=$(echo "$CUR_RM" | tr ',' '\n' | grep -v '^316:' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$REST" ]; then
            setprop persist.gammaos.gamepad.remap_btn "316:158,$REST"
        else
            setprop persist.gammaos.gamepad.remap_btn "316:158"
        fi
        log -t $TAG "gamepad remap: menu key -> BACK (now: $(getprop persist.gammaos.gamepad.remap_btn))"
        # gammapad 只在启动时读属性，改完要重启它
        # 注意：重启后物理手柄节点的 evdev 名字会消失是正常现象（它 re-hid 成虚拟手柄），
        #      不等同于「手柄坏了」，判据仍用 getevent -i | grep retrogame_joypad 之外的
        #      虚拟设备 "Xbox Wireless Controller" 是否在。
        setprop ctl.restart gammapad 2>/dev/null
        sleep 2
        log -t $TAG "gammapad restarted for remap"
        ;;
esac

# ⑪ 预装 LANGOS 修改版（PS2 走 NetherSX2 + N64/Dreamcast 映射修正）+ 预置 PS2 配置
# apk 放 /vendor/etc/ngp/，不碰 system 分区：LANGOS 是 system app，
# 直接换 /system/app 里的 apk 要过 verity 和包签名一致性，走 pm install -r
# 装成 /data/app 的更新版最省事（签名和系统版同为 langos.jks，能覆盖）。
NGP_DIR=/vendor/etc/ngp
if [ -f "$NGP_DIR/LANGOS.apk" ]; then
    if dumpsys package com.retrofront 2>/dev/null | grep -q "codePath=/data/app"; then
        : # 已经是更新版，不用重复装
    else
        # 开机初期 pm 可能还没就绪，重试三次
        i=0
        while [ $i -lt 3 ]; do
            if pm install -r "$NGP_DIR/LANGOS.apk" >/dev/null 2>&1; then
                log -t $TAG "langos: patched build installed"
                break
            fi
            i=$((i + 1))
            sleep 5
        done
        [ $i -ge 3 ] && log -t $TAG "langos: install FAILED"
    fi
fi

# NetherSX2 由 /vendor/app/NetherSX2/ 自动扫描安装，这里只补它的首启配置。
# 手柄绑定是 Pad1/*（设备哈希做前缀），全新刷机时 app 还没跑过、prefs 不存在，
# 所以只在「目录在、prefs 在、但还没有 Pad1/Cross」时补，避免覆盖用户自改。
PS2_DATA=/data/data/xyz.aethersx2.android
PS2_PREFS=$PS2_DATA/shared_prefs/xyz.aethersx2.android_preferences.xml
if [ -f "$NGP_DIR/ps2prefs.xml" ] && [ -d "$PS2_DATA" ] && [ -f "$PS2_PREFS" ]; then
    if ! grep -q "Pad1/Cross" "$PS2_PREFS" 2>/dev/null; then
        UID_PS2=$(stat -c %u "$PS2_DATA" 2>/dev/null)
        if [ -n "$UID_PS2" ] && cp -f "$NGP_DIR/ps2prefs.xml" "$PS2_PREFS"; then
            chown "$UID_PS2:$UID_PS2" "$PS2_PREFS" 2>/dev/null
            chmod 660 "$PS2_PREFS" 2>/dev/null
            log -t $TAG "ps2: prefs seeded (uid=$UID_PS2, OpenGL + Pad1)"
        fi
    fi
fi
