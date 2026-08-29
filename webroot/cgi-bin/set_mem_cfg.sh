#!/system/bin/sh
# set_mem_cfg.sh - 修改 fuyun.conf [mem] 分区内存配置 (键白名单校验)
# 用法: set_config.sh?key=MODE&value=hard
. "$(dirname "$0")/lib.sh"
require_token

KEY=$(qget key)
VAL=$(qget value)

cfg_key_valid "$KEY" || { json_err "无效的配置键: $KEY"; exit 0; }

# 值校验 (统一工具; 边界与 script/memctl.sh load_cfg 保持一致, 避免"保存成功却不生效")
case "$KEY" in
    MODE)       reclaim_mode_valid "$VAL" || { json_err "无效的模式: $VAL"; exit 0; } ;;
    MEM_ENABLE|SWITCH_RECLAIM)
                valid_bool "$VAL" || { json_err "值必须为 0 或 1"; exit 0; } ;;
    INTERVAL)   valid_uint "$VAL" || { json_err "值必须为数字"; exit 0; }
                valid_range "$VAL" 10 86400 || { json_err "INTERVAL 需在 10-86400 之间"; exit 0; } ;;
    PSI_THRESHOLD)
                valid_uint "$VAL" || { json_err "值必须为数字"; exit 0; }
                valid_range "$VAL" 1 100 || { json_err "PSI_THRESHOLD 需在 1-100 之间"; exit 0; } ;;
    MAX_PER_ROUND)
                valid_uint "$VAL" || { json_err "值必须为数字"; exit 0; }
                valid_range "$VAL" 1 50 || { json_err "MAX_PER_ROUND 需在 1-50 之间"; exit 0; } ;;
    IDLE_KILL_MIN)
                valid_uint "$VAL" || { json_err "值必须为数字"; exit 0; }
                valid_range "$VAL" 0 1440 || { json_err "IDLE_KILL_MIN 需在 0-1440 之间"; exit 0; } ;;
    HARD_RECLAIM)
                echo "$VAL" | grep -qE '^[0-9]+[KMG]?$' || { json_err "无效的内存大小格式"; exit 0; } ;;
    PUSH_KEEP)
                # 与 memctl.sh 安全字符集一致 (不含冒号, 防止保存成功但守护回退默认)
                echo "$VAL" | grep -qE '^[a-zA-Z0-9_.|]+$' || { json_err "仅允许字母数字 _ . |"; exit 0; } ;;
    KEEP_CMDLINE)
                echo "$VAL" | grep -qE '^[a-zA-Z0-9_.|*+-]+$' || { json_err "仅允许字母数字 _ . | * + -"; exit 0; } ;;
esac

set_cfg "$KEY" "$VAL"
json_ok "$KEY=$VAL"
