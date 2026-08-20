#!/system/bin/sh
# doze.sh - 管理 doze_whitelist.txt 息屏 Doze 白名单
# 用法: doze.sh?action=list
#       doze.sh?action=add&pkg=com.xxx
#       doze.sh?action=del&pkg=com.xxx
. "$(dirname "$0")/lib.sh"

ACTION=$(qget action)
PKG=$(qget pkg)

# sed 模式字面量转义: 防止包名中的 . 被当作正则元字符
sed_escape() {
    printf '%s' "$1" | sed 's/\./\\./g; s/\*/\\*/g; s/\[/\\[/g; s/\]/\\]/g; s/\^/\\^/g; s/\$/\\$/g; s#/#\\/#g'
}

# 首次访问时若文件不存在则创建默认白名单
init_doze_file() {
    [ -f "$DOZE_WL" ] && return 0
    mkdir -p "$USER_PATH"
    cat >"$DOZE_WL" <<'EOF'
# fuyun 息屏 Doze 白名单: 每行一个包名, # 开头为注释, 重启保留
# 白名单内的应用在深度 Doze 时仍可接收推送/消息
com.tencent.mm # 微信
com.tencent.mobileqq # QQ
com.tencent.tim # Tim
com.coolapk.market # 酷安
com.android.mms # 短信
com.android.email # 邮件
com.google.android.apps.messaging # 谷歌FCM推送
com.android.cellbroadcastreceiver # 紧急广播
EOF
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
    done <"$DOZE_WL"
    printf ']}\n'
    ;;
add)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    echo "$PKG" | grep -qE '^[a-zA-Z0-9_.]+$' || { json_err "invalid pkg"; exit 0; }
    init_doze_file
    # 已存在则先删旧行 (精确匹配, 避免子串误删)
    esc=$(sed_escape "$PKG")
    sed -i "/^$esc[[:space:]#]/d; /^$esc$/d" "$DOZE_WL" 2>/dev/null
    echo "$PKG" >>"$DOZE_WL"
    json_ok "added $PKG"
    ;;
del)
    [ -n "$PKG" ] || { json_err "missing pkg"; exit 0; }
    [ -f "$DOZE_WL" ] || { json_err "not found"; exit 0; }
    esc=$(sed_escape "$PKG")
    sed -i "/^$esc[[:space:]#]/d; /^$esc$/d" "$DOZE_WL" 2>/dev/null
    json_ok "removed $PKG"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
