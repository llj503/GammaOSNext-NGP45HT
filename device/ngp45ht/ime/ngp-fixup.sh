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

# ① 启用 AOSP leanback 输入法（幂等）
pm enable com.android.inputmethod.leanback >/dev/null 2>&1

# ② 改掉 rg52-ime.sh 的强制目标
setprop persist.rg52.ime $IME_ID

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
