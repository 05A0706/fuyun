#!/system/bin/sh
#
# freq_limit.sh - fuyun CPU 频率限制 (限制频率) 服务
#
# 作用:
#   限制 CPU 最高频率 (硬上限), 上限以下仍由 uperf 动态调频 (保留动态频率)。
#   适合续航向 / 压制发热 / 息屏省电场景, WebUI「频率限制」卡片可切换。
#   支持息屏自动限频: 息屏时自动套用 FREQ_OFFSCREEN_CAP, 亮屏恢复主上限。
#   (应用息屏管理/冻结交给墓碑类专用模块, 本服务不干预应用)
#
# 机制:
#   uperf 会按场景/负载持续向 scaling_max_freq 写入目标频率, 直接 echo 会被覆盖。
#   本服务两步生效:
#     1) 先真实写入上限 → 内核 cpufreq 立即生效 (schedutil 在上限以下动态调频);
#     2) 再 bind-mount 掩码文件冻结该节点 → uperf 后续写入被重定向到掩码文件,
#        内核上限保持为设定值, 任何写入都无法突破 (解除时 umount 即还原)。
#   与开机脚本共用 /data/local/tmp/mount_mask 会互相污染内容, 故使用独立掩码源。
#
# 配置:   /sdcard/Android/yc/uperf/freq_limit.txt (FREQ_CAP / FREQ_SCOPE)
# 日志:   /sdcard/Android/yc/uperf/mem_log.txt (前缀 "频率限制:")
#
# 用法:
#   freq_limit.sh watch   守护循环 (开机/WebUI 修改后自动保持, 默认)
#   freq_limit.sh apply   一次性应用当前配置 (幂等)
#   freq_limit.sh clear   解除全部限制并还原动态频率

USER_PATH=/sdcard/Android/yc/uperf
CFG="$USER_PATH/freq_limit.txt"
STATE_FILE="$USER_PATH/freq_limit.state"
# per-policy 掩码文件前缀: 不同 policy 的生效值可能不同 (clamp 到各自最低频),
# 必须各自独立掩码源, 否则共享 inode 后写覆盖先挂载 (所有挂载点读到同一值)
MASK_SRC_PFX=/data/local/tmp/fuyun_freq_cap_
LOG="$USER_PATH/mem_log.txt"

# 默认参数 (freq_limit.txt 可覆盖)
FREQ_CAP=0
FREQ_SCOPE=big
FREQ_OFFSCREEN=1
FREQ_OFFSCREEN_CAP=1200000

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 频率限制: $*" >>"$LOG"
}

# 屏幕是否亮着 (与 service.sh / memctl.sh 同款双判断, 兼容不同版本 dumpsys)
screen_on() {
    dumpsys power 2>/dev/null | grep -qE "mWakefulness=Awake|mHoldingDisplaySuspendBlocker=true"
}

# 读取配置 (仅白名单键, 不用 eval 防 /sdcard 配置注入)
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
    # 值合法性: 非法值回退默认, 避免把上限写成 0 或天文数字
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

# 首次运行生成默认配置 (不覆盖用户已有文件; 安装包 config/ 已带模板, 此处兜底)
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

# 当前是否挂着本功能的掩码 (0=无 1=有)
# 注意: /proc/mounts 中设备列在行首, 必须行首锚定 (前导空格会匹配不上)
mask_mounted() {
    grep -q "^$MASK_SRC_PFX" /proc/mounts 2>/dev/null && echo 1 || echo 0
}

# 解除限制: 卸载本功能挂上的全部掩码 (按挂载源前缀识别, 不碰其他掩码) + 还原硬件上限
clear_cap() {
    local mp p maxf
    grep "^$MASK_SRC_PFX" /proc/mounts 2>/dev/null | awk '{print $2}' | while read -r mp; do
        umount "$mp" 2>/dev/null
    done
    rm -f "$MASK_SRC_PFX"* 2>/dev/null
    for p in $(cpufreq_policies); do
        [ -f "$p/scaling_max_freq" ] || continue
        maxf=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        case "$maxf" in
            ''|*[!0-9]*) continue ;;
        esac
        echo "$maxf" >"$p/scaling_max_freq" 2>/dev/null
    done
}

# 应用当前配置 (幂等: 状态未变且掩码在位时直接跳过, 避免无谓的 mount/umount 抖动)
# 息屏联动: FREQ_OFFSCREEN=1 且屏幕熄灭时, 本次生效上限切换为 FREQ_OFFSCREEN_CAP
# clamp: 上限低于某簇 scaling_min_freq 时内核会拒绝写入 → 改为写入该簇最低频
#        (效果 = 锁最低频, 保证"0.8G 档"在最低频更高的簇上仍然生效)
apply_cap() {
    local want cur p maxf minf write_val target="" applied=0
    load_cfg
    [ -f "$CFG" ] || return 0
    if [ "$FREQ_OFFSCREEN" = "1" ] && [ "$FREQ_OFFSCREEN_CAP" -gt 0 ] 2>/dev/null && ! screen_on; then
        FREQ_CAP=$FREQ_OFFSCREEN_CAP
    fi
    want="$FREQ_CAP $FREQ_SCOPE"
    cur=$(cat "$STATE_FILE" 2>/dev/null)
    if [ "$cur" = "$want" ]; then
        if [ "$FREQ_CAP" = "0" ]; then
            [ "$(mask_mounted)" = "0" ] && return 0
        else
            [ "$(mask_mounted)" = "1" ] && return 0
        fi
    fi

    clear_cap
    if [ "$FREQ_CAP" = "0" ]; then
        rm -f "$STATE_FILE"
        log "动态频率 (未限制)"
        return 0
    fi

    # 确定目标 policy: big = 仅最高频簇; all = 全部
    if [ "$FREQ_SCOPE" = "all" ]; then
        target=$(cpufreq_policies)
    else
        target=$(big_policy)
    fi
    [ -n "$target" ] || { log "未找到 cpufreq policy, 无法限制"; return 1; }

    for p in $target; do
        [ -f "$p/scaling_max_freq" ] || continue
        maxf=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        case "$maxf" in
            ''|*[!0-9]*) continue ;;
        esac
        # 上限不低于该簇硬件上限 → 无需限制 (保持动态)
        [ "$maxf" -gt "$FREQ_CAP" ] || continue
        # clamp: 上限低于该簇最低频时, 内核会拒绝写入 → 改为锁最低频
        write_val=$FREQ_CAP
        minf=$(cat "$p/cpuinfo_min_freq" 2>/dev/null)
        case "$minf" in
            ''|*[!0-9]*) ;;
            *) [ "$minf" -gt "$write_val" ] && write_val=$minf ;;
        esac
        # 1) 真实写入: 内核 cpufreq 立即生效 (写入失败说明该上限不合法, 跳过)
        echo "$write_val" >"$p/scaling_max_freq" 2>/dev/null || continue
        # 2) per-policy 掩码冻结: uperf 后续写入无法突破该上限 (各簇独立掩码源)
        echo "$write_val" >"$MASK_SRC_PFX${p##*/}" 2>/dev/null || continue
        mount --bind "$MASK_SRC_PFX${p##*/}" "$p/scaling_max_freq" 2>/dev/null && applied=$((applied + 1))
    done

    if [ "$applied" -gt 0 ]; then
        echo "$want" >"$STATE_FILE"
        local ghz
        ghz=$(awk -v k="$FREQ_CAP" 'BEGIN{printf "%.2f", k / 1000000}')
        log "已限制 ${FREQ_SCOPE} 频率上限 ${ghz}GHz ($applied 个 policy 冻结)"
    else
        rm -f "$STATE_FILE"
        log "上限高于硬件上限或写入失败, 保持动态"
    fi
}

# 守护循环: 开机/配置修改后自动保持 (亮屏时 60s 巡检; 息屏联动开启时 15s 快巡检)
watch_loop() {
    local test_file
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 5
    done
    # /sdcard 需用户解锁后才可写 (与 memctl 同款等待)
    test_file=/sdcard/Android/.PERMISSION_TEST
    : >"$test_file" 2>/dev/null
    until [ -f "$test_file" ]; do
        : >"$test_file" 2>/dev/null
        sleep 2
    done
    rm -f "$test_file"

    init_defaults
    while true; do
        apply_cap
        load_cfg
        if [ "$FREQ_OFFSCREEN" = "1" ]; then
            sleep 15
        else
            sleep 60
        fi
    done
}

case "$1" in
    apply)  init_defaults; apply_cap ;;
    clear)  clear_cap; rm -f "$STATE_FILE"; log "已解除限制, 恢复动态频率" ;;
    *)      watch_loop ;;
esac
