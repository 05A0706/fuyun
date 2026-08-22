#!/system/bin/sh
# whitelist.sh - 管理 mem_whitelist.txt 回收白名单
# 用法: whitelist.sh?action=list
#       whitelist.sh?action=add&pkg=com.xxx (支持 com.xxx.* 前缀)
#       whitelist.sh?action=del&pkg=com.xxx
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
    if [ -f "$WL" ]; then
        while read -r p; do
            case "$p" in ""|\#*) continue ;; esac
            [ "$first" = "1" ] || printf ','
            printf '{"pkg":"%s"}' "$p"
            first=0
        done <"$WL"
    fi
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    echo "$PKG" | grep -qE '^[a-zA-Z0-9_.]+(\*)?$' || { json_err "invalid pkg"; exit 0; }
    esc=$(sed_escape "$PKG")
    [ -f "$WL" ] && sed -i "/^$esc$/d" "$WL"
    echo "$PKG" >>"$WL"
    json_ok "added $PKG"
    ;;
del)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    esc=$(sed_escape "$PKG")
    [ -f "$WL" ] && sed -i "/^$esc$/d" "$WL"
    json_ok "removed $PKG"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
