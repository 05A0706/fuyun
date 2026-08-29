#!/system/bin/sh
# config_file.sh - 高级设置: 读取/保存配置文件 (仅白名单文件)
# 用法:
#   config_file.sh?action=get&file=uperf
#   POST config_file.sh?action=save&file=uperf   (body = 文件原始内容)
#   config_file.sh?action=save&file=mem&content=...  (小文件兼容 GET)
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
FILE=$(qget file)

# 文件白名单: name -> path
# 26w34.6-B: 配置合并, 可编辑文件为 fuyun.conf (三合一) / whitelist.txt (三合一)
resolve_file() {
    case "$1" in
        uperf)    echo "$UPERF_JSON" ;;
        fuyun)    echo "$CFG" ;;
        whitelist) echo "$WL" ;;
        perapp)   echo "$PERAPP_FILE" ;;
        automation) echo "$AUTOMATION_FILE" ;;
        *)        echo "" ;;
    esac
}

PATH_RESOLVED=$(resolve_file "$FILE")
[ -n "$PATH_RESOLVED" ] || { json_err "无效的文件: $FILE"; exit 0; }

# JSON 括号平衡校验 (防止写坏 uperf.json 让调度整体失效)
json_balanced() {
    printf '%s' "$1" | awk '
    {
        line = $0
        gsub(/\\./, "", line)          # 跳过转义字符
        gsub(/"(\\.|[^"\\])*"/, "", line)  # 跳过字符串内容
        n = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "{" || c == "[") n++
            else if (c == "}" || c == "]") n--
            if (n < 0) { print "bad"; exit }
        }
        if (n != 0) { print "bad"; exit }
    }
    END { if (n == 0) print "ok" }'
}

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
    [ -n "$CONTENT" ] || { json_err "内容为空"; exit 0; }

    # POST body 大小限制 (防塞满磁盘), 1MB
    [ "${#CONTENT}" -le 1048576 ] 2>/dev/null || { json_err "内容过大 (>1MB)"; exit 0; }

    # uperf.json 做 JSON 形状 + 括号平衡检查, 避免明显写坏
    if [ "$FILE" = "uperf" ]; then
        first_char=$(printf '%s' "$CONTENT" | head -c 1)
        last_char=$(printf '%s' "$CONTENT" | tail -c 1)
        if [ "$first_char" != "{" ] || [ "$last_char" != "}" ]; then
            json_err "uperf.json 不是有效 JSON 对象 (需以 { 开头并以 } 结尾), 已放弃保存"
            exit 0
        fi
        [ "$(json_balanced "$CONTENT")" = "ok" ] || { json_err "uperf.json 括号不匹配, 已放弃保存"; exit 0; }
    fi

    # 原子写入 (写前自动备份 .bak) + 末尾补换行兼容逐行解析
    printf '%s\n' "$CONTENT" | atomic_write "$PATH_RESOLVED"
    json_ok "已保存 $FILE (备份: .bak)"
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
