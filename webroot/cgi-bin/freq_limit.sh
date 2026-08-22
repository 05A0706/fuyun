#!/system/bin/sh
# freq_limit.sh - 频率限制 查询与设置
# 用法: freq_limit.sh?action=get
#       freq_limit.sh?action=set&key=FREQ_CAP&value=1800000
#       freq_limit.sh?action=clear
. "$(dirname "$0")/lib.sh"

ACTION=$(qget action)

# 上限类键值校验: 0 或 200000-5000000 kHz
cap_valid() {
    echo "$1" | grep -qE '^[0-9]+$' || return 1
    [ "$1" -ge 0 ] 2>/dev/null || return 1
    [ "$1" -le 5000000 ] 2>/dev/null || return 1
    { [ "$1" = "0" ] || [ "$1" -ge 200000 ]; } 2>/dev/null || return 1
    return 0
}

# 输出设备 cpufreq 概况: "policy路径 硬件上限kHz 当前上限kHz" (每行一个)
policies_info() {
    local p maxf cur
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -f "$p/scaling_max_freq" ] || continue
        maxf=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        cur=$(cat "$p/scaling_max_freq" 2>/dev/null)
        echo "${p##*/} ${maxf:-0} ${cur:-0}"
    done
}

# 读取配置键 (带默认值回退)
cfg_get() {
    local k="$1" v
    v=$(grep "^$k=" "$FREQ_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
    [ -n "$v" ] || v="$2"
    echo "$v"
}

case "$ACTION" in
get)
    json_headers
    CAP=$(cfg_get FREQ_CAP 0)
    echo "$CAP" | grep -qE '^[0-9]+$' || CAP=0
    { [ "$CAP" -ge 0 ] 2>/dev/null && [ "$CAP" -le 5000000 ] 2>/dev/null; } || CAP=0
    SCOPE=$(cfg_get FREQ_SCOPE big)
    case "$SCOPE" in big|all) ;; *) SCOPE=big ;; esac
    OFFSCREEN=$(cfg_get FREQ_OFFSCREEN 1)
    case "$OFFSCREEN" in 0|1) ;; *) OFFSCREEN=1 ;; esac
    OFFCAP=$(cfg_get FREQ_OFFSCREEN_CAP 1200000)
    echo "$OFFCAP" | grep -qE '^[0-9]+$' || OFFCAP=1200000
    { [ "$OFFCAP" -ge 0 ] 2>/dev/null && [ "$OFFCAP" -le 5000000 ] 2>/dev/null; } || OFFCAP=1200000
    ACTIVE=0
    grep -qE "fuyun_freq_(cap|min|max)_" /proc/mounts 2>/dev/null && ACTIVE=1
    BIG_MAX=0
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -f "$p/cpuinfo_max_freq" ] || continue
        f=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -gt "$BIG_MAX" ] && BIG_MAX=$f
    done
    # policy 明细 (JSON 数组)
    POLS=$(policies_info | awk '{ if (n++) printf ","; printf "{\"policy\":\"%s\",\"max_khz\":%s,\"cur_khz\":%s}", $1, $2, $3 }')
    printf '{'
    printf '"ok":true,'
    printf '"freq_cap":%s,' "$CAP"
    printf '"freq_scope":"%s",' "$SCOPE"
    printf '"freq_active":%s,' "$ACTIVE"
    printf '"freq_offscreen":%s,' "$OFFSCREEN"
    printf '"freq_offcap":%s,' "$OFFCAP"
    printf '"freq_big_max_khz":%s,' "${BIG_MAX:-0}"
    printf '"freq_policies":[%s]' "$POLS"
    printf '}\n'
    ;;
set)
    KEY=$(qget key)
    VAL=$(qget value)
    case "$KEY" in
        FREQ_CAP|FREQ_SCOPE|FREQ_OFFSCREEN|FREQ_OFFSCREEN_CAP) ;;
        *) json_err "invalid key: $KEY"; exit 0 ;;
    esac
    case "$KEY" in
        FREQ_CAP|FREQ_OFFSCREEN_CAP)
            cap_valid "$VAL" || { json_err "$KEY must be 0 or 200000-5000000 (kHz)"; exit 0; }
            ;;
        FREQ_SCOPE)
            [ "$VAL" = "big" ] || [ "$VAL" = "all" ] || { json_err "scope must be big or all"; exit 0; }
            ;;
        FREQ_OFFSCREEN)
            [ "$VAL" = "0" ] || [ "$VAL" = "1" ] || { json_err "value must be 0 or 1"; exit 0; }
            ;;
    esac
    # 写 freq_limit.txt (保留注释与其余键, 与 set_cfg 相同策略)
    tmp="$FREQ_CFG.tmp"
    : >"$tmp"
    found=0
    while IFS='=' read -r k v; do
        if [ "$k" = "$KEY" ]; then
            echo "$KEY=$VAL" >>"$tmp"
            found=1
        else
            echo "$k=$v" >>"$tmp"
        fi
    done <"$FREQ_CFG"
    [ "$found" = "0" ] && echo "$KEY=$VAL" >>"$tmp"
    mv "$tmp" "$FREQ_CFG"
    # 立即应用 (freq_limit.sh apply 幂等)
    sh /data/adb/modules/uperf/script/freq_limit.sh apply 2>/dev/null
    # 报告应用结果
    ACTIVE=0
    grep -qE "fuyun_freq_(cap|min|max)_" /proc/mounts 2>/dev/null && ACTIVE=1
    if [ "$KEY" = "FREQ_CAP" ] && [ "$VAL" = "0" ]; then
        json_ok "已切换为动态频率"
    elif [ "$ACTIVE" = "1" ]; then
        json_ok "$KEY=$VAL 已保存并生效"
    elif [ "$KEY" = "FREQ_CAP" ]; then
        json_err "配置已保存, 但上限未生效 (高于硬件上限或冻结失败), 请查看日志"
    else
        json_ok "$KEY=$VAL 已保存"
    fi
    ;;
clear)
    sh /data/adb/modules/uperf/script/freq_limit.sh clear 2>/dev/null
    json_ok "已解除频率限制, 恢复动态频率"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
