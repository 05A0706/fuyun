#!/system/bin/sh
# whitelist.sh - 管理回收白名单 (whitelist.txt [mem] 分区)
# 用法: whitelist.sh?action=list
#       whitelist.sh?action=add&pkg=com.xxx (支持 com.xxx.* 前缀)
#       whitelist.sh?action=del&pkg=com.xxx
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
        # 去掉行内注释和首尾空白
        p=$(printf '%s' "$p" | sed 's/#.*//' | xargs)
        [ -n "$p" ] || continue
        [ "$first" = "1" ] || printf ','
        printf '{"pkg":"%s"}' "$(json_escape "$p")"
        first=0
    done <<EOF
$(section_body "$WL" mem)
EOF
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    valid_pkg_prefix "$PKG" || { json_err "无效的包名"; exit 0; }
    add_section_line "$WL" mem "$PKG"
    json_ok "已添加 $PKG"
    ;;
del)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    del_section_line "$WL" mem "$PKG"
    json_ok "已移除 $PKG"
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
