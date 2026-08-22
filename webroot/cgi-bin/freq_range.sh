#!/system/bin/sh
# freq_range.sh - CPU 频率范围 (小/中/大核 min/max) 查询与设置
# 用法: freq_range.sh?action=get
#       freq_range.sh?action=set&key=LITTLE_MAX&value=1344000
#       freq_range.sh?action=clear
. "$(dirname "$0")/lib.sh"

FREQ_RANGE_CFG="$USER_PATH/freq_range.txt"
FREQ_LIMIT_SCRIPT=/data/adb/modules/uperf/script/freq_limit.sh
ACTION=$(qget action)

ensure_range_cfg() {
    mkdir -p "$USER_PATH"
    if [ ! -f "$FREQ_RANGE_CFG" ]; then
        cat >"$FREQ_RANGE_CFG" <<'EOF'
FREQ_RANGE_ENABLE=0
LITTLE_MIN=0
LITTLE_MAX=0
MID_MIN=0
MID_MAX=0
BIG_MIN=0
BIG_MAX=0
EOF
    fi
}

# 识别 SoC 配置名 (与脚本 libsysinfo 对齐)
soc_name() {
    case "$(getprop ro.board.platform)" in
        kalama) echo "sdm8g2" ;;
        taro)   echo "sdm8+" ;;
        *)      echo "$(getprop ro.product.board)" ;;
    esac
}

freq_table_file() {
    case "$(soc_name)" in
        sdm8g2) echo "/data/adb/modules/uperf/script/freq_table_8g2.txt" ;;
        sdm8+)  echo "/data/adb/modules/uperf/script/freq_table_8p.txt" ;;
        *)      echo "" ;;
    esac
}

# $1: little|mid|big; 输出 JSON 数组
freqs_json() {
    local sec="$1" tbl
    tbl=$(freq_table_file)
    [ -n "$tbl" ] || { echo "[]"; return; }
    awk -v s="[$sec]" '
        BEGIN { ins=0; n=0; printf "[" }
        /^\[/ { ins=($0==s); next }
        ins && $0 ~ /^[0-9]+$/ { if (n++) printf ","; printf "%s", $1 }
        END { printf "]" }
    ' "$tbl" 2>/dev/null
}

# $1: little|mid|big  $2: kHz; 返回 0 = 支持
is_supported() {
    local tbl="$1" sec
    tbl=$(freq_table_file)
    [ -n "$tbl" ] || return 1
    sec="$1"
    awk -v s="[$sec]" '
        /^\[/ { ins=($0==s); next }
        ins && $1==v { found=1 }
        END { exit found?0:1 }
    ' v="$2" "$tbl" 2>/dev/null
}

range_get() {
    grep "^$1=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2
}

# 写 freq_range.txt (保留注释与其余键)
range_set() {
    local key="$1" val="$2"
    if grep -q "^$key=" "$FREQ_RANGE_CFG" 2>/dev/null; then
        sed -i "s/^$key=.*/$key=$val/" "$FREQ_RANGE_CFG" 2>/dev/null
    else
        echo "$key=$val" >>"$FREQ_RANGE_CFG"
    fi
}

# 校验频率键值
freq_key_valid() {
    case "$1" in
        FREQ_RANGE_ENABLE|LITTLE_MIN|LITTLE_MAX|MID_MIN|MID_MAX|BIG_MIN|BIG_MAX) return 0 ;;
    esac
    return 1
}

# $1: key $2: value → 返回 0 合法
freq_value_valid() {
    local key="$1" val="$2" cluster
    case "$key" in
        FREQ_RANGE_ENABLE)
            [ "$val" = "0" ] || [ "$val" = "1" ]
            return $?
            ;;
    esac
    echo "$val" | grep -qE '^[0-9]+$' || return 1
    [ "$val" = "0" ] && return 0
    case "$key" in
        LITTLE_MIN|LITTLE_MAX) cluster=little ;;
        MID_MIN|MID_MAX)       cluster=mid ;;
        BIG_MIN|BIG_MAX)       cluster=big ;;
    esac
    is_supported "$cluster" "$val"
}

case "$ACTION" in
get)
    ensure_range_cfg
    json_headers
    ENABLE=$(range_get FREQ_RANGE_ENABLE)
    [ "$ENABLE" = "1" ] || ENABLE=0
    LMIN=$(range_get LITTLE_MIN); [ -n "$LMIN" ] || LMIN=0
    LMAX=$(range_get LITTLE_MAX); [ -n "$LMAX" ] || LMAX=0
    MMIN=$(range_get MID_MIN);     [ -n "$MMIN" ] || MMIN=0
    MMAX=$(range_get MID_MAX);     [ -n "$MMAX" ] || MMAX=0
    BMIN=$(range_get BIG_MIN);     [ -n "$BMIN" ] || BMIN=0
    BMAX=$(range_get BIG_MAX);     [ -n "$BMAX" ] || BMAX=0
    SOC=$(soc_name)
    # 当前实际 scaling min/max (JSON 数组)
    POLS=""
    n=0
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -f "$p/scaling_min_freq" ] || continue
        [ -f "$p/scaling_max_freq" ] || continue
        min=$(cat "$p/scaling_min_freq" 2>/dev/null)
        max=$(cat "$p/scaling_max_freq" 2>/dev/null)
        [ -n "$min" ] && [ -n "$max" ] || continue
        if [ "$n" -gt 0 ]; then POLS="$POLS,"; fi
        POLS="$POLS{\"policy\":\"${p##*/}\",\"min_khz\":$min,\"max_khz\":$max}"
        n=$((n + 1))
    done
    printf '{'
    printf '"ok":true,'
    printf '"soc":"%s",' "$SOC"
    printf '"enable":%s,' "$ENABLE"
    printf '"little_min":%s,"little_max":%s,' "$LMIN" "$LMAX"
    printf '"mid_min":%s,"mid_max":%s,' "$MMIN" "$MMAX"
    printf '"big_min":%s,"big_max":%s,' "$BMIN" "$BMAX"
    printf '"freqs_little":%s,' "$(freqs_json little)"
    printf '"freqs_mid":%s,' "$(freqs_json mid)"
    printf '"freqs_big":%s,' "$(freqs_json big)"
    printf '"policies":[%s]' "$POLS"
    printf '}\n'
    ;;
set)
    ensure_range_cfg
    KEY=$(qget key)
    VAL=$(qget value)
    freq_key_valid "$KEY" || { json_err "invalid key: $KEY"; exit 0; }
    freq_value_valid "$KEY" "$VAL" || { json_err "value must be 0 or supported frequency (kHz): $KEY=$VAL"; exit 0; }
    # 互斥: 关闭时清 enable, 开启时保持各值
    range_set "$KEY" "$VAL"
    sh "$FREQ_LIMIT_SCRIPT" apply 2>/dev/null
    json_ok "$KEY=$VAL 已保存并应用"
    ;;
clear)
    ensure_range_cfg
    range_set FREQ_RANGE_ENABLE 0
    sh "$FREQ_LIMIT_SCRIPT" apply 2>/dev/null
    json_ok "已恢复动态频率范围"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
