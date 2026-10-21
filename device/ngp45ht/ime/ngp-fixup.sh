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

# ⓪b 鼠标模式（gammapad）屏幕尺寸同步。
#
# 现象：`wm size 640x480` 或某个 app 自己改分辨率之后，鼠标指针能看见，
#       但点击落点整体偏到别处（越往下/往右偏得越多）。
#
# 根因（反汇编 gammapad + 运行时验证）：
#   1. MouseMode 的屏幕尺寸只在 loadConfig() / setActive(true) 里探测一次，
#      tick() 和 processEvent() 都不会重新探测 —— 改分辨率它不知道。
#   2. VirtualMouse::create(w,h) 把 ABS_X/ABS_Y 的 absinfo max 写死成
#      w-1 / h-1，指针坐标系从创建那一刻就固定了。
#   3. 探测链第一个来源是属性 persist.gammaos.gamepad.screen_w/screen_h，
#      这两个属性 gammapad 只读取、不会自己写；缺省就落到 fb0 ioctl，
#      而 fb0 永远报物理分辨率 1024x768（wm size 只改 SurfaceFlinger 的
#      override DisplayInfo，不改 fb）。
#   => 指针坐标系恒为 1024x768，而 app 的坐标系是 640x480，
#      点击位置按 (1024/640, 768/480) 的倍率错位。
#
# 修法：本脚本先把 override 尺寸写进上面两个属性，再起一个后台看门狗，
#   每 2 秒比一次 `wm size`，变化时更新属性并重启 gammapad，
#   让它走 loadConfig() 重新探测、重建 VirtualMouse。
#   实测日志：MouseMode: screen size from property: 640x480。

# 从 `wm size` 输出解析当前生效尺寸（优先 Override size），写进 1、2 两个变量
ngp_wm_size() {
    WM_OUT=$(wm size 2>/dev/null)
    WM_RES=$(printf '%s\n' "$WM_OUT" | sed -n 's/.*Override size: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1x\2/p' | tail -n 1)
    [ -z "$WM_RES" ] && \
        WM_RES=$(printf '%s\n' "$WM_OUT" | sed -n 's/.*Physical size: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1x\2/p' | tail -n 1)
    WM_W=${WM_RES%x*}
    WM_H=${WM_RES#*x}
}

ngp_sync_screen() {
    ngp_wm_size
    case "$WM_W" in ''|*[!0-9]*) return 1 ;; esac
    case "$WM_H" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$(getprop persist.gammaos.gamepad.screen_w)" != "$WM_W" ] || \
       [ "$(getprop persist.gammaos.gamepad.screen_h)" != "$WM_H" ]; then
        setprop persist.gammaos.gamepad.screen_w "$WM_W"
        setprop persist.gammaos.gamepad.screen_h "$WM_H"
        log -t $TAG "gammapad screen -> ${WM_W}x${WM_H}, restarting gammapad"
        setprop ctl.stop gammapad
        sleep 1
        setprop ctl.start gammapad
    fi
    return 0
}

# 开机时先同步一次（此时属性可能还是空的，gammapad 会用 fb0 的 1024x768）
ngp_sync_screen

# 看门狗：分辨率一变就跟进。永不退出（进程随系统生命周期）。
(
    while :; do
        sleep 2
        ngp_sync_screen
    done
) </dev/null >/dev/null 2>&1 &

# ① 启用 AOSP leanback 输入法（幂等）
pm enable com.android.inputmethod.leanback >/dev/null 2>&1

# ② 改掉 rg52-ime.sh 的强制目标
setprop persist.rg52.ime $IME_ID

# ②b 性能悬浮窗：先起 root 统计守护进程，再拉起覆盖层应用
#     帧率来自 SurfaceFlinger TimeStats，需要 root；app 进程 CapBnd 为空，
#     调 su 提权必然 EPERM（Android 设计），所以改成"守护进程写文件、app 读文件"。
if [ -x /vendor/bin/ngp-statd ] && ! pidof ngp-statd >/dev/null 2>&1; then
    # 兜底：/vendor/etc/init/ngp-statd.rc 里已定义 init 服务，这里用 shell 守护循环
    # 再套一层，万一 init 因 SELinux 或崩溃计数放弃重启，帧率也不会永久变灰。
    setsid /system/bin/sh -c 'while :; do /vendor/bin/ngp-statd; sleep 5; done' \
        </dev/null >/dev/null 2>&1 &
fi
if pm path com.ngp.overlay >/dev/null 2>&1; then
    appops set com.ngp.overlay SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
    # 1.3 起入口类改名 ToggleActivity（带 LAUNCHER，桌面有图标），旧名不再存在
    am start -n com.ngp.overlay/.ToggleActivity >/dev/null 2>&1
    log -t $TAG "overlay started"
fi

# ③ rg52-ime.sh 在 boot_completed 后循环 30 次 × 2 秒，等它结束再收尾
sleep 70
ime enable $IME_ID >/dev/null 2>&1
ime set $IME_ID >/dev/null 2>&1

log -t $TAG "done, method=$(settings get secure default_input_method 2>/dev/null)"

# ④ 联网验证改用国内可达的探测点。
#    默认是 connectivitycheck.gstatic.com/generate_204，国内连不上 =>
#    系统判"受限/未连接互联网"，但实际能上网。
settings put global captive_portal_http_url "http://connect.rom.miui.com/generate_204"
settings put global captive_portal_https_url "https://connect.rom.miui.com/generate_204"
settings put global captive_portal_fallback_url "http://connect.rom.miui.com/generate_204"
settings put global captive_portal_use_https 0
log -t $TAG "captive portal -> miui"
