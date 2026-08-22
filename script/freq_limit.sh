#!/system/bin/sh
#
# freq_limit.sh - fuyun CPU 频率控制服务
#
# 作用:
#   1) 保留原有「全局/大核最高频率上限」(freq_limit.txt)
#   2) 新增「小/中/大核分别设置 min/max」(freq_range.txt)
#      支持任意 SoC 支持频点, min=max 即锁频。
#      频点以设备实测 scaling_available_frequencies 为准 (内置表兜底),
#      非法频点自动吸附到最近支持频点, 不再静默失效。
#   3) 生效状态写入 freq_range.state (WebUI 按 policy 显示), 失败逐簇记日志。
#      频点以设备实测 scaling_available_frequencies 为准 (内置表兜底),
#      非法频点自动吸附到最近支持频点, 不再静默失效。
#   3) 生效状态写入 freq_range.state (WebUI 按 policy 显示), 失败逐簇记日志。
#      频点以设备实测 scaling_available_frequencies 为准 (内置表兜底),
#      非法频点自动吸附到最近支持频点, 不再静默失效。
#   3) 生效状态写入 freq_range.state (WebUI 按 policy 显示), 失败逐簇记日志。
#   3) 上限/范围以下仍由 uperf 动态调频; 通过 bind-mount 掩码冻结,
#      uperf 的后续写入无法突破。
#
# 配置:
#   /sdcard/Android/yc/uperf/freq_limit.txt   (原有全局上限)
#   /sdcard/Android/yc/uperf/freq_range.txt   (新增分簇 min/max)
# 日志:
#   /sdcard/Android/yc/uperf/mem_log.txt (前缀 "频率限制:")
#
# 用法:
#   freq_limit.sh watch   守护循环 (默认)
#   freq_limit.sh apply   一次性应用当前配置
#   freq_limit.sh clear   解除全部限制并恢复动态

USER_PATH=/sdcard/Android/yc/uperf
CFG="$USER_PATH/freq_limit.txt"
RANGE_CFG="$USER_PATH/freq_range.txt"
STATE_FILE="$USER_PATH/freq_limit.state"
RANGE_STATE_FILE="$USER_PATH/freq_range.state"
# per-policy 掩码文件前缀: 不同 policy 的生效值可能不同 (clamp 到各自最低频),
# 必须各自独立掩码源, 否则共享 inode 后写覆盖先挂载 (所有挂载点读到同一值)
MASK_CAP_PFX=/data/local/tmp/fuyun_freq_cap_
MASK_MIN_PFX=/data/local/tmp/fuyun_freq_min_
MASK_MAX_PFX=/data/local/tmp/fuyun_freq_max_
LOG="$USER_PATH/mem_log.txt"

# 模块目录 (用于读取内置频率表/插件接口)
MODDIR=$(dirname "$(dirname "$(readlink -f "$0")")")
[ -f "$MODDIR/script/libsysinfo.sh" ] && . "$MODDIR/script/libsysinfo.sh"
[ -f "$MODDIR/script/plugin.sh" ] && . "$MODDIR/script/plugin.sh"

# 默认参数 (freq_limit.txt 可覆盖)
FREQ_CAP=0
FREQ_SCOPE=big
FREQ_OFFSCREEN=1
FREQ_OFFSCREEN_CAP=1200000

# 默认参数 (freq_range.txt 可覆盖)
FREQ_RANGE_ENABLE=0
LITTLE_MIN=0
LITTLE_MAX=0
MID_MIN=0
MID_MAX=0
BIG_MIN=0
BIG_MAX=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 频率限制: $*" >>"$LOG"
}

# 屏幕是否亮着 (与 service.sh / memctl.sh 同款双判断, 兼容不同版本 dumpsys)
screen_on() {
    dumpsys power 2>/dev/null | grep -qE "mWakefulness=Awake|mHoldingDisplaySuspendBlocker=true"
}

# 读取全局上限配置
load_cfg() {
    [ -f "$CFG" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        [ -n "$v" ] || continue
        case "$k" in
            FREQ_CAP)             FREQ_CAP=$v ;;
            FREQ_SCOPE)           FREQ_SCOPE=$v ;;
            FREQ_OFFSCREEN)       FREQ_OFFSCREEN=$v ;;
            FREQ_OFFSCREEN_CAP)   FREQ_OFFSCREEN_CAP=$v ;;
        esac
    done <"$CFG"
    # 值合法性
    case "$FREQ_CAP" in
        ''|*[!0-9]*) FREQ_CAP=0 ;;
    esac
    { [ "$FREQ_CAP" -ge 200000 ] 2>/dev/null && [ "$FREQ_CAP" -le 5000000 ] 2>/dev/null; } || FREQ_CAP=0
    case "$FREQ_SCOPE" in
        big|all) ;;
        *) FREQ_SCOPE=big ;;
    esac
    case "$FREQ_OFFSCREEN" in
        0|1) ;;
        *) FREQ_OFFSCREEN=1 ;;
    esac
    case "$FREQ_OFFSCREEN_CAP" in
        ''|*[!0-9]*) FREQ_OFFSCREEN_CAP=1200000 ;;
    esac
    { [ "$FREQ_OFFSCREEN_CAP" -ge 0 ] 2>/dev/null && [ "$FREQ_OFFSCREEN_CAP" -le 5000000 ] 2>/dev/null; } || FREQ_OFFSCREEN_CAP=1200000
}

# 读取分簇 min/max 配置
load_range_cfg() {
    [ -f "$RANGE_CFG" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        [ -n "$v" ] || continue
        case "$k" in
            FREQ_RANGE_ENABLE) FREQ_RANGE_ENABLE=$v ;;
            LITTLE_MIN)        LITTLE_MIN=$v ;;
            LITTLE_MAX)        LITTLE_MAX=$v ;;
            MID_MIN)           MID_MIN=$v ;;
            MID_MAX)           MID_MAX=$v ;;
            BIG_MIN)           BIG_MIN=$v ;;
            BIG_MAX)           BIG_MAX=$v ;;
        esac
    done <"$RANGE_CFG"
    case "$FREQ_RANGE_ENABLE" in 0|1) ;; *) FREQ_RANGE_ENABLE=0 ;; esac
    case "$LITTLE_MIN" in ''|*[!0-9]*) LITTLE_MIN=0 ;; esac
    case "$LITTLE_MAX" in ''|*[!0-9]*) LITTLE_MAX=0 ;; esac
    case "$MID_MIN"    in ''|*[!0-9]*) MID_MIN=0 ;; esac
    case "$MID_MAX"    in ''|*[!0-9]*) MID_MAX=0 ;; esac
    case "$BIG_MIN"    in ''|*[!0-9]*) BIG_MIN=0 ;; esac
    case "$BIG_MAX"    in ''|*[!0-9]*) BIG_MAX=0 ;; esac
}

# 首次运行生成默认配置 (不覆盖用户已有文件)
init_defaults() {
    mkdir -p "$USER_PATH"
    if [ ! -f "$CFG" ]; then
        cat >"$CFG" <<'EOF'
# fuyun 频率限制配置 (重启保留, 修改即时生效)
# FREQ_CAP: 频率上限 kHz, 0=动态不限制 (如 1800000=1.8GHz)
FREQ_CAP=0
# FREQ_SCOPE: big=仅大核(最高频簇) all=全部核心
FREQ_SCOPE=big
# FREQ_OFFSCREEN: 息屏自动限频开关 1=启用 0=关闭
FREQ_OFFSCREEN=1
# FREQ_OFFSCREEN_CAP: 息屏时套用的上限 kHz, 0=跟随主上限 (如 1200000=1.2GHz)
FREQ_OFFSCREEN_CAP=1200000
EOF
    fi
    if [ ! -f "$RANGE_CFG" ]; then
        cat >"$RANGE_CFG" <<'EOF'
# fuyun CPU 频率范围配置 (小/中/大核 min/max 可调)
# 0 = 动态; 非 0 = SoC 支持频点 kHz; min=max = 锁频
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

# 所有 cpufreq policy 路径
cpufreq_policies() {
    ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null
}

# 最高频簇 (大核) 的 policy 路径
big_policy() {
    local p maxf best="" bestf=0
    for p in $(cpufreq_policies); do
        [ -f "$p/cpuinfo_max_freq" ] || continue
        maxf=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        case "$maxf" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$maxf" -gt "$bestf" ]; then
            bestf=$maxf
            best=$p
        fi
    done
    echo "$best"
}

# SoC 配置名: sdm8g2 / sdm8+ / unsupported
soc_name() {
    local board cfg
    board=$(getprop ro.board.platform)
    cfg=$(get_config_name "$board" 2>/dev/null)
    if [ "$cfg" = "unsupported" ] || [ -z "$cfg" ]; then
        board=$(getprop ro.product.board)
        cfg=$(get_config_name "$board" 2>/dev/null)
    fi
    echo "$cfg"
}

# 当前 SoC 的频率表路径
freq_table_file() {
    case "$(soc_name)" in
        sdm8g2) echo "$MODDIR/script/freq_table_8g2.txt" ;;
        sdm8+)  echo "$MODDIR/script/freq_table_8p.txt" ;;
        sdm8g3) echo "$MODDIR/script/freq_table_8g3.txt" ;;
        sdm8e)  echo "$MODDIR/script/freq_table_8e.txt" ;;
        sdm8e5) echo "$MODDIR/script/freq_table_8e5.txt" ;;
        *)      echo "" ;;
    esac
}

# $1: policy 路径  $2: little|mid|big; 输出该 policy 支持频点 (每行一个)
# 优先读设备实测 scaling_available_frequencies, 缺失时回退内置频点表
policy_freqs() {
    local p="$1" cluster="$2" f tbl
    if [ -f "$p/scaling_available_frequencies" ]; then
        f=$(cat "$p/scaling_available_frequencies" 2>/dev/null)
    fi
    if [ -z "$f" ] && [ -f "$p/scaling_boost_frequencies" ]; then
        f=$(cat "$p/scaling_boost_frequencies" 2>/dev/null)
    fi
    if [ -n "$f" ]; then
        echo "$f" | tr ' ' '\n' | grep -E '^[0-9]+$'
        return 0
    fi
    tbl=$(freq_table_file)
    [ -n "$tbl" ] || return 1
    awk -v s="[$cluster]" 'BEGIN{ins=0} /^\[/{ins=($0==s)} ins && $0 ~ /^[0-9]+$/ {print $1}' "$tbl" 2>/dev/null
}

# $1: policy  $2: little|mid|big  $3: kHz; 返回 0 = 该频点可用
is_supported() {
    policy_freqs "$1" "$2" | grep -qx "$3"
}

# $1: policy  $2: cluster  $3: kHz; 输出 <= $3 的最大支持频点 (无则空)
freq_floor() {
    policy_freqs "$1" "$2" | awk -v v="$3" '$1<=v && $1>m {m=$1} END {if (m!="") print m}'
}

# $1: policy  $2: cluster  $3: kHz; 输出 >= $3 的最小支持频点 (无则空)
freq_ceil() {
    policy_freqs "$1" "$2" | awk -v v="$3" '{if ($1>=v && (m=="" || $1<m)) m=$1} END {if (m!="") print m}'
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
    # 全局最高频
    bestf=0
    for b in $(cpufreq_policies); do
        [ -f "$b/cpuinfo_max_freq" ] || continue
        f=$(cat "$b/cpuinfo_max_freq" 2>/dev/null)
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -gt "$bestf" ] && bestf=$f
    done
    # 大核: 包含全局最高频核心的簇 (兼容 8 Elite 双核 Prime 簇 / 8 Gen3 单核 X4)
    if [ "$maxf" -ge "$bestf" ] 2>/dev/null; then
        echo "big"
        return
    fi
    # 小核: 包含 cpu0
    if [ "$mincpu" = "0" ]; then
        echo "little"
        return
    fi
    echo "mid"
}

# 当前是否挂着本功能的掩码 (0=无 1=有)
mask_mounted() {
    grep -qE "^($MASK_CAP_PFX|$MASK_MIN_PFX|$MASK_MAX_PFX)" /proc/mounts 2>/dev/null && echo 1 || echo 0
}

# 解除全部频率控制: 卸载掩码 + 还原硬件 min/max
clear_all() {
    local mp p hwmin hwmax
    grep -E "^($MASK_CAP_PFX|$MASK_MIN_PFX|$MASK_MAX_PFX)" /proc/mounts 2>/dev/null | awk '{print $2}' | while read -r mp; do
        umount "$mp" 2>/dev/null
    done
    rm -f /data/local/tmp/fuyun_freq_* 2>/dev/null
    for p in $(cpufreq_policies); do
        if [ -f "$p/scaling_min_freq" ]; then
            hwmin=$(cat "$p/cpuinfo_min_freq" 2>/dev/null)
            case "$hwmin" in
                ''|*[!0-9]*) ;;
                *) chmod 0666 "$p/scaling_min_freq" 2>/dev/null; echo "$hwmin" >"$p/scaling_min_freq" 2>/dev/null ;;
            esac
        fi
        if [ -f "$p/scaling_max_freq" ]; then
            hwmax=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
            case "$hwmax" in
                ''|*[!0-9]*) ;;
                *) chmod 0666 "$p/scaling_max_freq" 2>/dev/null; echo "$hwmax" >"$p/scaling_max_freq" 2>/dev/null ;;
            esac
        fi
    done
    rm -f "$RANGE_STATE_FILE" 2>/dev/null
}

# 写节点并掩码冻结; 返回 0 = 已冻结生效
# 顺序: 解除旧掩码 → 真实写入内核 → 写掩码源文件 → bind-mount
# bind-mount 失败时尝试只读锁定兜底 (注意: root 进程可绕过, 仅尽力而为)
apply_node() {
    local v="$1" n="$2" m="$3"
    chmod 0666 "$n" 2>/dev/null
    umount "$n" 2>/dev/null
    if ! echo "$v" >"$n" 2>/dev/null; then
        log "写入被内核拒绝: $n = $v kHz"
        return 1
    fi
    if ! echo "$v" >"$m" 2>/dev/null; then
        log "掩码源文件不可写: $m"
        return 1
    fi
    if mount --bind "$m" "$n" 2>/dev/null; then
        return 0
    fi
    chmod 0444 "$n" 2>/dev/null
    log "bind-mount 失败: $n (已尝试只读锁定兜底, 对 root 进程可能无效)"
    return 1
}

# 应用当前配置 (幂等)
apply_all() {
    local want cur p cluster hwmin hwmax cmin cmax do_min do_max applied ok masked r
    load_cfg
    load_range_cfg
    # 息屏联动
    if [ "$FREQ_OFFSCREEN" = "1" ] && [ "$FREQ_OFFSCREEN_CAP" -gt 0 ] 2>/dev/null && ! screen_on; then
        FREQ_CAP=$FREQ_OFFSCREEN_CAP
    fi
    want="cap:$FREQ_CAP:$FREQ_SCOPE:$FREQ_OFFSCREEN:$FREQ_OFFSCREEN_CAP|range:$FREQ_RANGE_ENABLE:$LITTLE_MIN:$LITTLE_MAX:$MID_MIN:$MID_MAX:$BIG_MIN:$BIG_MAX"
    cur=$(cat "$STATE_FILE" 2>/dev/null)
    if [ "$cur" = "$want" ] && [ "$(mask_mounted)" = "1" ]; then
        return 0
    fi

    clear_all
    if [ "$FREQ_CAP" = "0" ] && [ "$FREQ_RANGE_ENABLE" != "1" ]; then
        rm -f "$STATE_FILE"
        log "动态频率 (未限制)"
        type run_plugins >/dev/null 2>&1 && run_plugins "clear"
        return 0
    fi

    applied=0
    : >"$RANGE_STATE_FILE" 2>/dev/null
    for p in $(cpufreq_policies); do
        [ -f "$p/scaling_min_freq" ] || continue
        [ -f "$p/scaling_max_freq" ] || continue
        cluster=$(cluster_of_policy "$p")
        [ "$cluster" = "unknown" ] && continue
        hwmin=$(cat "$p/cpuinfo_min_freq" 2>/dev/null)
        hwmax=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        case "$hwmin" in ''|*[!0-9]*) continue ;; esac
        case "$hwmax" in ''|*[!0-9]*) continue ;; esac
        cmin=0
        cmax=0
        do_min=0
        do_max=0
        # ---- 分簇 min/max (freq_range.txt) ----
        if [ "$FREQ_RANGE_ENABLE" = "1" ]; then
            case "$cluster" in
                little) cmin=$LITTLE_MIN; cmax=$LITTLE_MAX ;;
                mid)    cmin=$MID_MIN;    cmax=$MID_MAX ;;
                big)    cmin=$BIG_MIN;    cmax=$BIG_MAX ;;
            esac
            # min: 非法频点向上吸附到最近支持频点, 超过硬件上限则忽略
            if [ "$cmin" -ne 0 ] 2>/dev/null; then
                if is_supported "$p" "$cluster" "$cmin"; then
                    do_min=1
                else
                    r=$(freq_ceil "$p" "$cluster" "$cmin")
                    if [ -n "$r" ]; then
                        log "$cluster min=${cmin}kHz 非支持频点, 自动吸附到 ${r}kHz"
                        cmin=$r
                        do_min=1
                    else
                        log "忽略 $cluster min=${cmin}kHz: 高于硬件上限或无可用频点"
                        cmin=0
                    fi
                fi
            fi
            # max: 非法频点向下吸附到最近支持频点, 低于硬件最低频则忽略
            if [ "$cmax" -ne 0 ] 2>/dev/null; then
                if is_supported "$p" "$cluster" "$cmax"; then
                    do_max=1
                else
                    r=$(freq_floor "$p" "$cluster" "$cmax")
                    if [ -n "$r" ]; then
                        log "$cluster max=${cmax}kHz 非支持频点, 自动吸附到 ${r}kHz"
                        cmax=$r
                        do_max=1
                    else
                        log "忽略 $cluster max=${cmax}kHz: 低于硬件最低频或无可用频点"
                        cmax=0
                    fi
                fi
            fi
        fi
        # ---- 全局上限叠加 (freq_limit.txt) ----
        if [ "$FREQ_CAP" -gt 0 ] 2>/dev/null; then
            if [ "$FREQ_SCOPE" = "all" ] || [ "$cluster" = "big" ]; then
                [ "$cmax" -eq 0 ] 2>/dev/null && cmax=$hwmax
                [ "$cmax" -gt "$FREQ_CAP" ] && cmax=$FREQ_CAP
                # 上限低于硬件最低频时锁最低频 (与旧逻辑一致)
                [ "$cmax" -lt "$hwmin" ] && cmax=$hwmin
                if ! is_supported "$p" "$cluster" "$cmax"; then
                    r=$(freq_floor "$p" "$cluster" "$cmax")
                    if [ -n "$r" ] && [ "$r" -ge "$hwmin" ] 2>/dev/null; then
                        cmax=$r
                    else
                        cmax=$hwmin
                    fi
                    log "$cluster 上限吸附到 ${cmax}kHz"
                fi
                do_max=1
            fi
        fi
        # 没有需要控制的节点则跳过
        [ "$do_min" = "0" ] && [ "$do_max" = "0" ] && continue
        # 校验 min<=max
        if [ "$do_min" = "1" ] && [ "$do_max" = "1" ] && [ "$cmin" -gt "$cmax" ] 2>/dev/null; then
            log "忽略 $cluster min>max ($cmin>$cmax)"
            continue
        fi
        masked=0
        if [ "$do_min" = "1" ]; then
            apply_node "$cmin" "$p/scaling_min_freq" "$MASK_MIN_PFX${p##*/}" && masked=$((masked + 1))
        fi
        if [ "$do_max" = "1" ]; then
            apply_node "$cmax" "$p/scaling_max_freq" "$MASK_MAX_PFX${p##*/}" && masked=$((masked + 1))
        fi
        echo "${p##*/} $cluster min=$cmin max=$cmax masked=$masked" >>"$RANGE_STATE_FILE"
        [ "$masked" -gt 0 ] && applied=$((applied + 1))
    done

    if [ "$applied" -gt 0 ]; then
        echo "$want" >"$STATE_FILE"
        log "已应用频率控制 (global cap=${FREQ_CAP}kHz range=${FREQ_RANGE_ENABLE}, 明细见 freq_range.state)"
        type run_plugins >/dev/null 2>&1 && run_plugins "apply"
    else
        rm -f "$STATE_FILE"
        log "频率控制未生效，保持动态"
    fi
}

# 守护循环
watch_loop() {
    local test_file
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 5
    done
    # /sdcard 需用户解锁后才可写
    test_file=/sdcard/Android/.PERMISSION_TEST
    : >"$test_file" 2>/dev/null
    until [ -f "$test_file" ]; do
        : >"$test_file" 2>/dev/null
        sleep 2
    done
    rm -f "$test_file"

    init_defaults
    while true; do
        apply_all
        load_cfg
        if [ "$FREQ_OFFSCREEN" = "1" ]; then
            sleep 15
        else
            sleep 60
        fi
    done
}

case "$1" in
    apply)  init_defaults; apply_all ;;
    clear)  clear_all; rm -f "$STATE_FILE"; log "已解除频率控制, 恢复动态"; type run_plugins >/dev/null 2>&1 && run_plugins "clear" ;;
    *)      watch_loop ;;
esac
