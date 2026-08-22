#!/system/bin/sh
# mode.sh - 切换性能模式
# 用法: mode.sh?mode=performance
. "$(dirname "$0")/lib.sh"

M=$(qget mode)
mode_valid "$M" || { json_err "invalid mode: $M"; exit 0; }

echo "$M" >"$POWERMODE_FILE" 2>/dev/null
# 通知 uperf 切换 (powercfg 入口)
if [ -f /data/powercfg.sh ]; then
    sh /data/powercfg.sh "$M" 2>/dev/null
fi
json_ok "mode switched to $M"
