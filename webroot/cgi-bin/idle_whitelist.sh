#!/system/bin/sh
# idle_whitelist.sh - 管理 idle_whitelist.txt 辅助调速器白名单
# 用法: idle_whitelist.sh?action=list
#       idle_whitelist.sh?action=add&pkg=com.xxx (支持 com.xxx.* 前缀)
#       idle_whitelist.sh?action=del&pkg=com.xxx
. "$(dirname "$0")/lib.sh"

ACTION=$(qget action)
PKG=$(qget pkg)

# sed 模式字面量转义: 白名单支持 com.xxx.* 通配, 防止 . * 被当作正则元字符
sed_escape() {
    echo "$1" | sed 's/\./\\./g; s/\*/\\*/g; s/\[/\\[/g; s/\]/\\]/g; s/\^/\\^/g; s/\$/\\$/g; s#/#\\/#g'
}

case "$ACTION" in
list)
    json_headers
    printf '{"ok":true,"items":['
    first=1
    if [ -f "$IDLE_WL" ]; then
        while read -r p; do
            case "$p" in ""|\#*) continue ;; esac
            [ "$first" = "1" ] || printf ','
            printf '{"pkg":"%s"}' "$p"
            first=0
        done <"$IDLE_WL"
    fi
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    echo "$PKG" | grep -qE '^[a-zA-Z0-9_.]+(\*)?$' || { json_err "invalid pkg"; exit 0; }
    esc=$(sed_escape "$PKG")
    [ -f "$IDLE_WL" ] && sed -i "/^$esc$/d" "$IDLE_WL"
    echo "$PKG" >>"$IDLE_WL"
    json_ok "added $PKG"
    ;;
del)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    esc=$(sed_escape "$PKG")
    [ -f "$IDLE_WL" ] && sed -i "/^$esc$/d" "$IDLE_WL"
    json_ok "removed $PKG"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
