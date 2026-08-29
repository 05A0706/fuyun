#!/system/bin/sh
# apps.sh - 管理 mem_apps.txt 分应用策略
# 用法: apps.sh?action=list
#       apps.sh?action=add&pkg=com.xxx&mode=kill
#       apps.sh?action=del&pkg=com.xxx
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
PKG=$(qget pkg)
AMODE=$(qget mode)

case "$ACTION" in
list)
    json_headers
    printf '{"ok":true,"items":['
    first=1
    if [ -f "$APPS_FILE" ]; then
        while read -r p m; do
            case "$p" in ""|\#*) continue ;; esac
            [ "$first" = "1" ] || printf ','
            printf '{"pkg":"%s","mode":"%s"}' "$(json_escape "$p")" "$(json_escape "${m:-global}")"
            first=0
        done <"$APPS_FILE"
    fi
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    valid_pkg "$PKG" || { json_err "无效的包名"; exit 0; }
    [ -n "$AMODE" ] || AMODE=hard
    reclaim_mode_valid "$AMODE" || { json_err "无效的模式: $AMODE"; exit 0; }
    # 已存在则先删旧行 (转义后再进 sed 模式); 原子替换 + 自动备份
    esc=$(sed_escape "$PKG")
    atomic_sed "$APPS_FILE" "/^$esc /d"
    echo "$PKG $AMODE" >>"$APPS_FILE"
    json_ok "已添加 $PKG $AMODE"
    ;;
del)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    esc=$(sed_escape "$PKG")
    atomic_sed "$APPS_FILE" "/^$esc /d"
    json_ok "已移除 $PKG"
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
