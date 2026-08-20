#!/system/bin/sh
# action.sh - 动作执行
# 用法: action.sh?do=reclaim          立即回收一轮
#       action.sh?do=restart_memctl   重启 memctl 服务
#       action.sh?do=reload           重载配置 (touch mem_config.txt 触发热加载)
. "$(dirname "$0")/lib.sh"

DO=$(qget 'do')

case "$DO" in
reclaim)
    # memctl 每轮检测该文件, 触发一次回收后删除
    touch "$RECLAIM_NOW" 2>/dev/null
    json_ok "reclaim triggered (memctl will run it within one interval)"
    ;;
restart_memctl)
    # 杀掉旧实例并重新拉起 (由 service.sh 相同的路径启动)
    pkill -f "script/memctl.sh" 2>/dev/null
    sleep 1
    if [ -f /data/adb/modules/uperf/script/memctl.sh ]; then
        sh /data/adb/modules/uperf/script/memctl.sh >/dev/null 2>&1 &
        json_ok "memctl restarted"
    else
        json_err "memctl.sh not found"
    fi
    ;;
reload)
    # 配置文件已由 memctl 每轮热加载; touch 触发下一轮立即重读
    touch "$CFG" 2>/dev/null
    json_ok "config reload scheduled"
    ;;
*)
    json_err "unknown action: $DO"
    ;;
esac
