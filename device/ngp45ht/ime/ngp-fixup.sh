#!/system/bin/sh
# NGP45HT 开机修正：让软键盘可用
#
# 背景（三层叠加，缺一不可）：
#   1. 镜像默认把两个输入法包都禁用了 —— com.android.inputmethod.leanback
#      和 com.liskovsoft.leankeyboard 都在 `pm list packages -d` 里，
#      包被禁用 => IME 服务起不来 => InputMethodManager 报 mCurId=null /
#      mHaveConnection=false => 任何应用调键盘都失败。
#   2. /system/bin/rg52-ime.sh（上游 RG52 的脚本）在 boot_completed 后
#      每 2 秒刷一次、连刷 30 次，把 default_input_method 强制设成
#      com.liskovsoft.leankeyboard —— 正好是启不来的那个。
#   3. 该脚本自带逃生门：读 persist.rg52.ime，设了它就用它。
#
# 这里：① 启用 AOSP leanback 键盘；② 用 persist.rg52.ime 改掉强制目标；
#       ③ 等它的 60 秒循环跑完，再收尾强制设置一次（双保险）。

TAG=ngp-fixup
IME_ID=com.android.inputmethod.leanback/.service.LeanbackImeService

log -t $TAG "start"

# ⓪a 默认桌面：固定为 LANGOS（com.retrofront）。
#
# Daijishou 已从本机卸载，而 /system/bin/rg52-home.sh 守的是它 —— 包不在时
# 只打一条 warning 就退出，等于没人兜底；万一 home 偏好丢了会停在选择框。
# 这里每次开机都显式指定一次（幂等，成本一条 cmd）。
# 注意：必须确认包存在再设，指向不存在的组件会让 home 永久解析失败。
if pm path com.retrofront >/dev/null 2>&1; then
    cmd package set-home-activity --user 0 com.retrofront/.NativeActivity >/dev/null 2>&1
    log -t $TAG "home -> com.retrofront/.NativeActivity"
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
#    优先讯飞输入法（com.iflytek.inputmethod，中文拼音，全屏候选，手柄/遥控器可用）；
#    包不在才回落 leanback。
#
# 为什么是讯飞：
#   - 系统自带的两个键盘（AOSP leanback、LeanKey）都只有英文，没有中文拼音；
#   - 搜狗输入法TV版（com.sohu.inputmethod.sogou.tv）APKPure 上那份是残缺包，
#     解出来 0 个 .so，IMEInterface.native_setup 直接 UnsatisfiedLinkError，
#     键盘只能弹出一次（第一次是空壳）随后窗口退化成 [512,768][512,768]，已弃用；
#   - 讯飞这份 lib/arm64-v8a 下有 48 个 .so，targetSdk 30，Android 14 正常跑。
IFLY_IME=com.iflytek.inputmethod/.FlyIME
IFLY_PKG=com.iflytek.inputmethod
sleep 70
if pm path $IFLY_PKG >/dev/null 2>&1; then
    # 必须先写进 enabled_input_methods，否则 ime set 报
    # "Unknown input method ... cannot be selected for user #0"
    settings put secure enabled_input_methods "$IFLY_IME:$IME_ID" >/dev/null 2>&1
    ime enable $IFLY_IME >/dev/null 2>&1
    ime set $IFLY_IME >/dev/null 2>&1

    # 讯飞首次启动会弹「服务和隐私条款概要」（PrivacyPolicyActivity）。
    # 在用户点「同意」之前，这个引导会由 IME 自己在键盘窗口里再画一次，
    # 把真实键盘整个盖掉 —— 表现就是"键盘弹出来了但看不见、点不了"。
    # 脚本没法替用户点（该页是普通 Activity，只能人用手柄/触屏点「同意」），
    # 所以这里不做任何自动操作，只在首次需要时把页面拉出来给用户点。
    if [ ! -f /data/local/tmp/.iflytek_agreed ]; then
        _cur=$(dumpsys window 2>/dev/null | grep -o 'mCurrentFocus=Window{[^}]*}' | head -n 1)
        if echo "$_cur" | grep -qE 'com.retrofront|tvlauncher'; then
            am start -n $IFLY_PKG/com.iflytek.inputmethod.wizard.PrivacyPolicyActivity \
                >/dev/null 2>&1
            log -t $TAG "iflytek: privacy wizard surfaced (need one-time tap)"
        fi
    fi
fi
if [ "$(settings get secure default_input_method 2>/dev/null)" != "$IFLY_IME" ]; then
    ime enable $IME_ID >/dev/null 2>&1
    ime set $IME_ID >/dev/null 2>&1
fi

log -t $TAG "done, method=$(settings get secure default_input_method 2>/dev/null)"

# ④ 联网验证改用国内可达的探测点。
#    默认是 connectivitycheck.gstatic.com/generate_204，国内连不上 =>
#    系统判"受限/未连接互联网"，但实际能上网。
settings put global captive_portal_http_url "http://connect.rom.miui.com/generate_204"
settings put global captive_portal_https_url "https://connect.rom.miui.com/generate_204"
settings put global captive_portal_fallback_url "http://connect.rom.miui.com/generate_204"
settings put global captive_portal_use_https 0
log -t $TAG "captive portal -> miui"
