#!/system/bin/sh
# vulkan.sh - Vulkan / OpenGL 渲染后端查询与切换
# 用法:
#   vulkan.sh?action=get                查询当前状态 (1=Vulkan 0=OpenGL)
#   vulkan.sh?action=set&mode=vulkan    切换为 Vulkan (写状态文件 + resetprop)
#   vulkan.sh?action=set&mode=opengl    还原 OpenGL
# 注: prop 修改即时生效一部分, 完全生效需重启 (post-fs-data.sh 开机按状态应用)
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
MODE=$(qget mode)

STATE_DIR=/data/adb/uperf
STATE_FILE="$STATE_DIR/vulkan.state"
USER_STATE="$USER_PATH/vulkan.state"

case "$ACTION" in
get)
    VULKAN=1
    if [ -f "$STATE_FILE" ]; then
        v=$(cat "$STATE_FILE" 2>/dev/null)
        [ "$v" = "0" ] && VULKAN=0
    fi
    json_out "{\"ok\":true,\"vulkan\":$VULKAN}"
    ;;
set)
    case "$MODE" in
    vulkan)
        resetprop ro.hwui.use_vulkan true
        resetprop debug.hwui.renderer skiavk
        resetprop debug.renderengine.backend skiavkthreaded
        resetprop debug.renderengine.vulkan true
        resetprop debug.renderengine.graphite true
        resetprop debug.egl.hw 1
        echo 1 >"$STATE_FILE" 2>/dev/null
        echo 1 >"$USER_STATE" 2>/dev/null
        json_ok "已切换为 Vulkan (完全生效需重启, 开机自动保持)"
        ;;
    opengl)
        resetprop ro.hwui.use_vulkan false
        resetprop debug.hwui.renderer opengl
        resetprop debug.renderengine.backend threaded
        resetprop debug.renderengine.vulkan false
        resetprop debug.renderengine.graphite false
        resetprop debug.egl.hw 0
        echo 0 >"$STATE_FILE" 2>/dev/null
        echo 0 >"$USER_STATE" 2>/dev/null
        json_ok "已还原 OpenGL (完全生效需重启, 开机自动保持)"
        ;;
    *)
        json_err "无效模式: $MODE (vulkan|opengl)"
        ;;
    esac
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
