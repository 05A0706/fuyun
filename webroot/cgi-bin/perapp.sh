#!/system/bin/sh
# perapp.sh - 管理 perapp_powermode.txt 分应用性能模式 (V-Tools 兼容格式)
# 用法: perapp.sh?action=list
#       perapp.sh?action=add&pkg=com.xxx&mode=performance
#       perapp.sh?action=del&pkg=com.xxx
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
PKG=$(qget pkg)
PMODE=$(qget mode)

case "$ACTION" in
list)
    json_headers
    printf '{"ok":true,"items":['
    first=1
    if [ -f "$PERAPP_FILE" ]; then
        while read -r p m; do
            case "$p" in ""|\#*) continue ;; esac
            [ "$first" = "1" ] || printf ','
            printf '{"pkg":"%s","mode":"%s"}' "$(json_escape "$p")" "$(json_escape "${m:-balance}")"
            first=0
        done <"$PERAPP_FILE"
    fi
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    valid_pkg "$PKG" || { json_err "无效的包名"; exit 0; }
    [ -n "$PMODE" ] || PMODE=balance
    mode_valid "$PMODE" || { json_err "无效的模式: $PMODE"; exit 0; }
    # 已存在则先删旧行 (转义后进 sed 模式); 原子替换 + 自动备份
    esc=$(sed_escape "$PKG")
    atomic_sed "$PERAPP_FILE" "/^$esc[[:space:]]/d; /^$esc\$/d"
    echo "$PKG $PMODE" >>"$PERAPP_FILE"
    json_ok "已添加 $PKG $PMODE"
    ;;
del)
    [ -n "$PKG" ] || { json_err "缺少包名"; exit 0; }
    esc=$(sed_escape "$PKG")
    atomic_sed "$PERAPP_FILE" "/^$esc[[:space:]]/d; /^$esc\$/d"
    json_ok "已移除 $PKG"
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
