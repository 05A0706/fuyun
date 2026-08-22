#!/system/bin/sh
# log.sh - 查看日志尾部
# 用法: log.sh?lines=50&file=mem
. "$(dirname "$0")/lib.sh"

LINES=$(qget lines)
[ -n "$LINES" ] || LINES=50
echo "$LINES" | grep -qE '^[0-9]+$' || LINES=50

FILE=$(qget file)
case "$FILE" in
    screen) SRC="$USER_PATH/screen_log.txt" ;;
    uperf)  SRC="$USER_PATH/uperf_log.txt" ;;
    *)      SRC="$LOG" ;;
esac

json_headers
printf '{"ok":true,"lines":['
first=1
if [ -f "$SRC" ]; then
    tail -n "$LINES" "$SRC" 2>/dev/null | while IFS= read -r line; do
        [ "$first" = "1" ] || printf ','
        # JSON 字符串转义 (引号/反斜杠/控制字符)
        esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g;s/"/\\"/g')
        printf '"%s"' "$esc"
        first=0
    done
fi
printf ']}\n'
