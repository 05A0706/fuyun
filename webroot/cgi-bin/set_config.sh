#!/system/bin/sh
# set_config.sh - 修改 mem_config.txt (键白名单校验)
# 用法: set_config.sh?key=MODE&value=hard
. "$(dirname "$0")/lib.sh"

KEY=$(qget key)
VAL=$(qget value)

cfg_key_valid "$KEY" || { json_err "invalid key: $KEY"; exit 0; }

# 值校验
case "$KEY" in
    MODE)       reclaim_mode_valid "$VAL" || { json_err "invalid mode: $VAL"; exit 0; } ;;
    MEM_ENABLE|SWITCH_RECLAIM)
                [ "$VAL" = "0" ] || [ "$VAL" = "1" ] || { json_err "value must be 0 or 1"; exit 0; } ;;
    INTERVAL|PSI_THRESHOLD|MAX_PER_ROUND|IDLE_KILL_MIN)
                echo "$VAL" | grep -qE '^[0-9]+$' || { json_err "value must be a number"; exit 0; } ;;
    HARD_RECLAIM)
                echo "$VAL" | grep -qE '^[0-9]+[KMG]?$' || { json_err "invalid size"; exit 0; } ;;
    PUSH_KEEP|KEEP_CMDLINE)
                echo "$VAL" | grep -qE '^[a-zA-Z0-9_.:|]+$' || { json_err "invalid characters"; exit 0; } ;;
esac

set_cfg "$KEY" "$VAL"
json_ok "$KEY=$VAL"
