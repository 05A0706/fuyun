#!/system/bin/sh
# doze.sh - 管理息屏 Doze 白名单 (whitelist.txt [doze] 分区)
# 用法: doze.sh?action=list
#       doze.sh?action=add&pkg=com.xxx
#       doze.sh?action=del&pkg=com.xxx
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
PKG=$(qget pkg)

# 兜底: 文件不存在时创建 (默认 Doze 白名单由 post-fs-data.sh 初始化)
init_doze_file() {
    [ -f "$DOZE_WL" ] && return 0
    mkdir -p "$USER_PATH"
    : >"$DOZE_WL"
}

case "$ACTION" in
list)
    init_doze_file
    json_headers
    printf '{"ok":true,"items":['
    first=1
    while read -r p; do
        # 去掉行内注释和首尾空白
        p=$(printf '%s' "$p" | sed 's/#.*//' | xargs)
        [ -n "$p" ] || continue
        [ "$first" = "1" ] || printf ','
        esc=$(json_escape "$p")
        printf '{"pkg":"%s"}' "$esc"
        first=0
    done <<EOF
$(section_body "$DOZE_WL" doze)
EOF
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    valid_pkg "$PKG" || { json_err "无效的包名"; exit 0; }
    init_doze_file
    add_section_line "$DOZE_WL" doze "$PKG"
    json_ok "已添加 $PKG"
    ;;
del)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    [ -f "$DOZE_WL" ] || { json_err "文件不存在"; exit 0; }
    del_section_line "$DOZE_WL" doze "$PKG"
    json_ok "已移除 $PKG"
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
