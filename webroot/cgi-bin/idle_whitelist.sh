#!/system/bin/sh
# idle_whitelist.sh - 管理调速器白名单 (whitelist.txt [idle_gov] 分区)
# 用法: idle_whitelist.sh?action=list
#       idle_whitelist.sh?action=add&pkg=com.xxx (支持 com.xxx.* 前缀)
#       idle_whitelist.sh?action=del&pkg=com.xxx
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
PKG=$(qget pkg)

case "$ACTION" in
list)
    json_headers
    printf '{"ok":true,"items":['
    first=1
    while read -r p; do
        p=$(printf '%s' "$p" | sed 's/#.*//' | xargs)
        [ -n "$p" ] || continue
        [ "$first" = "1" ] || printf ','
        printf '{"pkg":"%s"}' "$(json_escape "$p")"
        first=0
    done <<EOF
$(section_body "$IDLE_WL" idle_gov)
EOF
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    valid_pkg_prefix "$PKG" || { json_err "无效的包名"; exit 0; }
    add_section_line "$IDLE_WL" idle_gov "$PKG"
    json_ok "已添加 $PKG"
    ;;
del)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    del_section_line "$IDLE_WL" idle_gov "$PKG"
    json_ok "已移除 $PKG"
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
