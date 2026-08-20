#!/system/bin/sh
# apps.sh - 管理 mem_apps.txt 分应用策略
# 用法: apps.sh?action=list
#       apps.sh?action=add&pkg=com.xxx&mode=kill
#       apps.sh?action=del&pkg=com.xxx
. "$(dirname "$0")/lib.sh"

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
            printf '{"pkg":"%s","mode":"%s"}' "$p" "${m:-global}"
            first=0
        done <"$APPS_FILE"
    fi
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    echo "$PKG" | grep -qE '^[a-zA-Z0-9_.]+$' || { json_err "invalid pkg"; exit 0; }
    [ -n "$AMODE" ] || AMODE=hard
    reclaim_mode_valid "$AMODE" || { json_err "invalid mode: $AMODE"; exit 0; }
    # 已存在则先删旧行
    [ -f "$APPS_FILE" ] && sed -i "/^$PKG /d" "$APPS_FILE"
    echo "$PKG $AMODE" >>"$APPS_FILE"
    json_ok "added $PKG $AMODE"
    ;;
del)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    [ -f "$APPS_FILE" ] && sed -i "/^$PKG /d" "$APPS_FILE"
    json_ok "removed $PKG"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
