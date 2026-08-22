#!/system/bin/sh
# config_file.sh - 高级设置: 读取/保存配置文件 (仅白名单文件)
# 用法:
#   config_file.sh?action=get&file=uperf
#   POST config_file.sh?action=save&file=uperf   (body = 文件原始内容)
#   config_file.sh?action=save&file=mem&content=...  (小文件兼容 GET)
. "$(dirname "$0")/lib.sh"

ACTION=$(qget action)
FILE=$(qget file)

# 文件白名单: name -> path
resolve_file() {
    case "$1" in
        uperf)  echo "$UPERF_JSON" ;;
        mem)    echo "$CFG" ;;
        idle)   echo "$IDLE_CFG" ;;
        perapp) echo "$PERAPP_FILE" ;;
        doze)   echo "$DOZE_WL" ;;
        *)      echo "" ;;
    esac
}

PATH_RESOLVED=$(resolve_file "$FILE")
[ -n "$PATH_RESOLVED" ] || { json_err "invalid file: $FILE"; exit 0; }

case "$ACTION" in
get)
    [ -f "$PATH_RESOLVED" ] || { json_out "{\"ok\":true,\"file\":\"$FILE\",\"lines\":[]}"; exit 0; }
    json_headers
    printf '{"ok":true,"file":"%s","lines":[' "$FILE"
    first=1
    while IFS= read -r line; do
        [ "$first" = "1" ] || printf ','
        esc=$(json_escape "$line")
        printf '"%s"' "$esc"
        first=0
    done <"$PATH_RESOLVED"
    printf ']}\n'
    ;;
save)
    # 优先读取 POST body, 其次兼容 GET content 参数
    if [ "$REQUEST_METHOD" = "POST" ]; then
        CONTENT=$(cat)
    else
        CONTENT=$(qget content)
    fi
    [ -n "$CONTENT" ] || { json_err "empty content"; exit 0; }

    # 保存前备份 (保留上一次 .bak)
    if [ -f "$PATH_RESOLVED" ]; then
        cp -f "$PATH_RESOLVED" "$PATH_RESOLVED.bak" 2>/dev/null
    fi

    # uperf.json 做最基础的 JSON 形状检查, 避免明显写坏
    if [ "$FILE" = "uperf" ]; then
        first_char=$(printf '%s' "$CONTENT" | head -c 1)
        last_char=$(printf '%s' "$CONTENT" | tail -c 1)
        if [ "$first_char" != "{" ] || [ "$last_char" != "}" ]; then
            json_err "uperf.json 不是有效 JSON 对象 (需以 { 开头并以 } 结尾), 已放弃保存"
            exit 0
        fi
    fi

    # 写入时确保最后有换行, 兼容 read 逐行解析
    printf '%s\n' "$CONTENT" >"$PATH_RESOLVED"
    json_ok "saved $FILE (backup: .bak)"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
