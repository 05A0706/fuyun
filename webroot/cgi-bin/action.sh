#!/system/bin/sh
# action.sh - 动作执行
# 用法: action.sh?do=reclaim          立即回收一轮
#       action.sh?do=restart_memctl   重启 memctl 服务
#       action.sh?do=reload           重载配置 (touch fuyun.conf 触发热加载)
. "$(dirname "$0")/lib.sh"
require_token

DO=$(qget 'do')

case "$DO" in
reclaim)
    # memctl 每轮检测该文件, 触发一次回收后删除
    touch "$RECLAIM_NOW" 2>/dev/null
    json_ok "已触发回收, 一个轮询周期内执行"
    ;;
restart_uperf)
    # 重启 uperf 使新配置生效 (高级设置保存 uperf.json 后使用)
    if [ -x "$MODDIR/bin/uperf" ]; then
        killall uperf 2>/dev/null
        sleep 0.5
        [ -f "$USER_PATH/uperf_log.txt" ] && mv -f "$USER_PATH/uperf_log.txt" "$USER_PATH/uperf_log.txt.bak" 2>/dev/null
        nohup "$MODDIR/bin/uperf" "$UPERF_JSON" -o "$USER_PATH/uperf_log.txt" >/dev/null 2>&1 &
        # uperf 不应抢占前台任务
        local pid
        pid=$(pgrep -x uperf | head -n 1)
        [ -n "$pid" ] && echo "$pid" >/dev/cpuset/background/tasks 2>/dev/null
        json_ok "uperf 已重启"
    else
        json_err "uperf 二进制缺失, 无法重启"
    fi
    ;;
restart_memctl)
    # 杀掉旧实例并重新拉起 (由 service.sh 相同的路径启动; 模块路径由 lib.sh 的 MODDIR 推导)
    pkill -f "script/memctl.sh" 2>/dev/null
    sleep 1
    if [ -f "$MODDIR/script/memctl.sh" ]; then
        sh "$MODDIR/script/memctl.sh" >/dev/null 2>&1 &
        json_ok "memctl 已重启"
    else
        json_err "memctl.sh 未找到"
    fi
    ;;
reload)
    # 配置文件已由 memctl 每轮热加载; touch 触发下一轮立即重读
    touch "$CFG" 2>/dev/null
    json_ok "已安排重载配置"
    ;;
*)
    json_err "unknown action: $DO"
    ;;
esac
