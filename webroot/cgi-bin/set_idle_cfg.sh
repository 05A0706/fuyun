#!/system/bin/sh
# set_idle_cfg.sh - 修改 idle_gov.txt 辅助调速器配置 (键白名单校验)
# 用法: set_idle_cfg.sh?key=IDLE_POWER_W&value=0.8
. "$(dirname "$0")/lib.sh"

KEY=$(qget key)
VAL=$(qget value)

# 校验键名白名单 (防注入)
case "$KEY" in
    IDLE_GOV|IDLE_INTERVAL|IDLE_TIMEOUT|IDLE_CPU_THD|IDLE_POWER_W) ;;
    *) json_err "invalid key: $KEY"; exit 0 ;;
esac

# 值校验
case "$KEY" in
    IDLE_GOV)
        [ "$VAL" = "0" ] || [ "$VAL" = "1" ] || { json_err "value must be 0 or 1"; exit 0; } ;;
    IDLE_INTERVAL|IDLE_TIMEOUT|IDLE_CPU_THD)
        echo "$VAL" | grep -qE '^[0-9]+$' || { json_err "value must be a number"; exit 0; }
        [ "$VAL" -ge 1 ] 2>/dev/null || { json_err "value must be >= 1"; exit 0; } ;;
    IDLE_POWER_W)
        echo "$VAL" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { json_err "invalid power"; exit 0; }
        echo "$VAL" | awk '{ exit !($1 >= 0.1 && $1 <= 5) }' || { json_err "power must be 0.1-5"; exit 0; } ;;
esac

# 写 idle_gov.txt (保留注释与其余键, 与 set_cfg 相同策略)
tmp="$IDLE_CFG.tmp"
: >"$tmp"
found=0
while IFS='=' read -r k v; do
    if [ "$k" = "$KEY" ]; then
        echo "$KEY=$VAL" >>"$tmp"
        found=1
    else
        echo "$k=$v" >>"$tmp"
    fi
done <"$IDLE_CFG"
[ "$found" = "0" ] && echo "$KEY=$VAL" >>"$tmp"
mv "$tmp" "$IDLE_CFG"
json_ok "$KEY=$VAL"
