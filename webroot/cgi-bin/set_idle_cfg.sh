#!/system/bin/sh
# set_idle_cfg.sh - 修改 fuyun.conf [idle_gov] 分区辅助调速器配置 (键白名单校验)
# 用法: set_idle_cfg.sh?key=IDLE_POWER_W&value=0.8
. "$(dirname "$0")/lib.sh"
require_token

KEY=$(qget key)
VAL=$(qget value)

# 校验键名白名单 (防注入)
case "$KEY" in
    IDLE_GOV|IDLE_INTERVAL|IDLE_TIMEOUT|IDLE_CPU_THD|IDLE_POWER_W) ;;
    *) json_err "无效的配置键: $KEY"; exit 0 ;;
esac

# 值校验 (统一工具; 边界与 script/auxgov.sh load_idle_cfg 保持一致)
case "$KEY" in
    IDLE_GOV)
        valid_bool "$VAL" || { json_err "值必须为 0 或 1"; exit 0; } ;;
    IDLE_INTERVAL)
        valid_uint "$VAL" || { json_err "值必须为数字"; exit 0; }
        valid_range "$VAL" 3 86400 || { json_err "IDLE_INTERVAL 需在 3-86400 之间"; exit 0; } ;;
    IDLE_TIMEOUT)
        valid_uint "$VAL" || { json_err "值必须为数字"; exit 0; }
        valid_range "$VAL" 1 100000 || { json_err "数值超出范围"; exit 0; } ;;
    IDLE_CPU_THD)
        valid_uint "$VAL" || { json_err "值必须为数字"; exit 0; }
        valid_range "$VAL" 1 100 || { json_err "IDLE_CPU_THD 需在 1-100 之间"; exit 0; } ;;
    IDLE_POWER_W)
        echo "$VAL" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { json_err "无效的功率值"; exit 0; }
        echo "$VAL" | awk '{ exit !($1 >= 0.1 && $1 <= 5) }' || { json_err "power must be 0.1-5"; exit 0; } ;;
esac

# 写 fuyun.conf [idle_gov] 分区 (保留注释与其余键, 原子替换)
set_section_kv "$IDLE_CFG" idle_gov "$KEY" "$VAL"
json_ok "$KEY=$VAL"
