#!/system/bin/sh
# 延迟把 host 翻成 app。
#
# AzaharSf 的 sessionRunning() 要求 host=app；但 azahar-nano 前端在 main()
# 里会读 host 来选择后端（host=nano -> DRM/SF，按 backend 属性）。如果
# init.svc.azahar-nano=running 一触发就立刻改 host，前端会读到 app，
# 结果连手持模式也被迫走 SurfaceFlinger。
#
# 这里等 3 秒，让前端完成启动和后端选择，再只改给 AzaharSf 看的 host。
TAG=ngp-azahar-host
sleep 3
[ "$(getprop init.svc.azahar-nano)" = "running" ] || exit 0
[ "$(getprop sys.gammaos.azahar_nano.from_app)" = "1" ] || exit 0
setprop sys.gammaos.azahar_nano.host app
log -t $TAG "host -> app (session=$(getprop sys.gammaos.azahar_nano.session))"
