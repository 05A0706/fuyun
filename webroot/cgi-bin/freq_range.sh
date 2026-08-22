#!/system/bin/sh
# freq_range.sh - CPU 频率范围 (小/中/大核 min/max) 查询与设置
# 用法: freq_range.sh?action=get
#       freq_range.sh?action=set&key=LITTLE_MAX&value=1344000
#       freq_range.sh?action=clear
. "$(dirname "$0")/lib.sh"

FREQ_RANGE_CFG="$USER_PATH/freq_range.txt"
FREQ_LIMIT_SCRIPT=/data/adb/modules/uperf/script/freq_limit.sh
RANGE_STATE="$USER_PATH/freq_range.state"
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
        pineapple) echo "sdm8g3" ;;
        sun)       echo "sdm8e" ;;
        shark)     echo "sdm8e5" ;;
        kalama)    echo "sdm8g2" ;;
        taro)      echo "sdm8+" ;;
        *)         echo "$(getprop ro.product.board)" ;;
    esac
}

freq_table_file() {
    case "$(soc_name)" in
        sdm8g2) echo "/data/adb/modules/uperf/script/freq_table_8g2.txt" ;;
        sdm8+)  echo "/data/adb/modules/uperf/script/freq_table_8p.txt" ;;
        sdm8g3) echo "/data/adb/modules/uperf/script/freq_table_8g3.txt" ;;
        sdm8e)  echo "/data/adb/modules/uperf/script/freq_table_8e.txt" ;;
        sdm8e5) echo "/data/adb/modules/uperf/script/freq_table_8e5.txt" ;;
        *)      echo "" ;;
    esac
}

# 所有 cpufreq policy 路径
cpufreq_policies() {
    ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null
}

# $1: policy 路径; 输出 little|mid|big|unknown
cluster_of_policy() {
    local p="$1" rel maxf count mincpu maxcpu cpus a b i c bestf b f
    rel=$(cat "$p/related_cpus" 2>/dev/null)
    [ -n "$rel" ] || rel=$(cat "$p/affected_cpus" 2>/dev/null)
    [ -n "$rel" ] || { echo "unknown"; return; }
    cpus=""
    case "$rel" in
        *-*)
            a=${rel%-*}
            b=${rel#*-}
            i=$a
            while [ "$i" -le "$b" ] 2>/dev/null; do
                cpus="$cpus $i"
                i=$((i + 1))
            done
            ;;
        *)
            cpus=$(echo "$rel" | tr ',' ' ')
            ;;
    esac
    count=0
    mincpu=999
    maxcpu=0
    for c in $cpus; do
        case "$c" in ''|*[!0-9]*) continue ;; esac
        count=$((count + 1))
        [ "$c" -lt "$mincpu" ] && mincpu=$c
        [ "$c" -gt "$maxcpu" ] && maxcpu=$c
    done
    [ "$count" -eq 0 ] && { echo "unknown"; return; }
    maxf=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
    case "$maxf" in ''|*[!0-9]*) echo "unknown"; return ;; esac
    bestf=0
    for b in $(cpufreq_policies); do
        [ -f "$b/cpuinfo_max_freq" ] || continue
        f=$(cat "$b/cpuinfo_max_freq" 2>/dev/null)
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -gt "$bestf" ] && bestf=$f
    done
    # 大核: 包含全局最高频核心的簇 (兼容 8 Elite 双核 Prime 簇)
    if [ "$maxf" -ge "$bestf" ] 2>/dev/null; then
        echo "big"
        return
    fi
    if [ "$mincpu" = "0" ]; then
        echo "little"
        return
    fi
    echo "mid"
}

# $1: policy 路径; 输出该 policy 实测支持频点 (每行一个; 无则空)
policy_freqs() {
    local p="$1" f
    if [ -f "$p/scaling_available_frequencies" ]; then
        f=$(cat "$p/scaling_available_frequencies" 2>/dev/null)
    fi
    if [ -z "$f" ] && [ -f "$p/scaling_boost_frequencies" ]; then
        f=$(cat "$p/scaling_boost_frequencies" 2>/dev/null)
    fi
    [ -n "$f" ] || return 1
    echo "$f" | tr ' ' '\n' | grep -E '^[0-9]+$'
}

# $1: little|mid|big; 输出该簇可用频点 JSON 数组 (设备实测并集去重)
freqs_json() {
    local cluster="$1"
    for p in $(cpufreq_policies); do
        [ "$(cluster_of_policy "$p")" = "$cluster" ] || continue
        policy_freqs "$p" 2>/dev/null
    done | sort -n -u | awk 'BEGIN{n=0; printf "["} {if (n++) printf ","; printf "%s", $1} END {printf "]"}'
}

# 回退: 内置表 (设备实测缺失时)
freqs_json_fallback() {
    local cluster="$1" tbl
    tbl=$(freq_table_file)
    [ -n "$tbl" ] || { echo "[]"; return; }
    awk -v s="[$cluster]" '
        BEGIN { ins=0; n=0; printf "[" }
        /^\[/ { ins=($0==s); next }
        ins && $0 ~ /^[0-9]+$/ { if (n++) printf ","; printf "%s", $1 }
        END { printf "]" }
    ' "$tbl" 2>/dev/null
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
# 频率值只做数值范围校验 (0 或 1-5000000), 具体频点由 freq_limit.sh 吸附到设备支持频点
freq_value_valid() {
    local key="$1" val="$2"
    case "$key" in
        FREQ_RANGE_ENABLE)
            [ "$val" = "0" ] || [ "$val" = "1" ]
            return $?
            ;;
    esac
    echo "$val" | grep -qE '^[0-9]+$' || return 1
    [ "$val" = "0" ] && return 0
    [ "$val" -ge 1 ] 2>/dev/null || return 1
    [ "$val" -le 5000000 ] 2>/dev/null || return 1
    return 0
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
    # 各簇可用频点: 设备实测优先
    FL=$(freqs_json little); [ "$FL" = "[]" ] && FL=$(freqs_json_fallback little)
    FM=$(freqs_json mid);    [ "$FM" = "[]" ] && FM=$(freqs_json_fallback mid)
    FB=$(freqs_json big);    [ "$FB" = "[]" ] && FB=$(freqs_json_fallback big)
    # 逐 policy 状态: cluster + 当前实际 min/max + 掩码是否生效
    POLS=""
    n=0
    for p in $(cpufreq_policies); do
        [ -f "$p/scaling_min_freq" ] || continue
        [ -f "$p/scaling_max_freq" ] || continue
        cl=$(cluster_of_policy "$p")
        [ "$cl" = "unknown" ] && continue
        min=$(cat "$p/scaling_min_freq" 2>/dev/null)
        max=$(cat "$p/scaling_max_freq" 2>/dev/null)
        [ -n "$min" ] && [ -n "$max" ] || continue
        masked=0
        st=$(grep "^${p##*/} " "$RANGE_STATE" 2>/dev/null | head -n 1)
        case "$st" in
            *"masked=1"*) masked=1 ;;
            *"masked=2"*) masked=1 ;;
        esac
        # 掩码已挂载也算生效 (状态文件可能尚未刷新)
        grep -qE "^/data/local/tmp/fuyun_freq_(min|max)_${p##*/} " /proc/mounts 2>/dev/null && masked=1
        if [ "$n" -gt 0 ]; then POLS="$POLS,"; fi
        POLS="$POLS{\"policy\":\"${p##*/}\",\"cluster\":\"$cl\",\"min_khz\":$min,\"max_khz\":$max,\"masked\":$masked}"
        n=$((n + 1))
    done
    printf '{'
    printf '"ok":true,'
    printf '"soc":"%s",' "$SOC"
    printf '"enable":%s,' "$ENABLE"
    printf '"little_min":%s,"little_max":%s,' "$LMIN" "$LMAX"
    printf '"mid_min":%s,"mid_max":%s,' "$MMIN" "$MMAX"
    printf '"big_min":%s,"big_max":%s,' "$BMIN" "$BMAX"
    printf '"freqs_little":%s,' "$FL"
    printf '"freqs_mid":%s,' "$FM"
    printf '"freqs_big":%s,' "$FB"
    printf '"policies":[%s]' "$POLS"
    printf '}\n'
    ;;
set)
    ensure_range_cfg
    KEY=$(qget key)
    VAL=$(qget value)
    freq_key_valid "$KEY" || { json_err "invalid key: $KEY"; exit 0; }
    freq_value_valid "$KEY" "$VAL" || { json_err "value must be 0 or 1-5000000 (kHz): $KEY=$VAL"; exit 0; }
    range_set "$KEY" "$VAL"
    # 设置任意簇 min/max 时自动启用频率范围 (避免只改值忘开总开关)
    case "$KEY" in
        LITTLE_MIN|LITTLE_MAX|MID_MIN|MID_MAX|BIG_MIN|BIG_MAX)
            range_set FREQ_RANGE_ENABLE 1
            ;;
    esac
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
