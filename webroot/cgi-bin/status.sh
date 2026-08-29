#!/system/bin/sh
# status.sh - 读取全部状态, 返回 JSON
. "$(dirname "$0")/lib.sh"
require_token

# 前台应用缓存 (dumpsys 是一次较重的 binder 调用, 前端每 15s 轮询一次本接口)
FG_CACHE_FILE=/data/local/tmp/fuyun_fg_cache
FG_CACHE_TTL=8

json_headers

# uperf / memctl 进程状态
UPERF_RUN=0
MEMCTL_RUN=0
pgrep -x uperf >/dev/null 2>&1 && UPERF_RUN=1
pgrep -f 'memctl.sh' >/dev/null 2>&1 && MEMCTL_RUN=1

# 当前性能模式
MODE=$(cat "$POWERMODE_FILE" 2>/dev/null)
[ -n "$MODE" ] || MODE=unknown

# 内存可用量 (空值/非数字保护, 避免算术展开报错)
MEMAVAIL=$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')
case "$MEMAVAIL" in ''|*[!0-9]*) MEMAVAIL=0 ;; esac
MEMAVAIL_MB=$((MEMAVAIL / 1024))

# memctl 配置: 一次 awk 读全部键 (原为每键一次 grep|head|cut)
MODE_CFG=hard
PSI=30
INTERVAL=300
IDLE=5
SWITCH=1
MEM_ENABLE=1
MAXROUND=10
KEYS=$(read_keys "$CFG" mem MODE PSI_THRESHOLD INTERVAL IDLE_KILL_MIN SWITCH_RECLAIM MEM_ENABLE MAX_PER_ROUND)
while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    case "$k" in
        MODE)           MODE_CFG=$v ;;
        PSI_THRESHOLD)  PSI=$v ;;
        INTERVAL)       INTERVAL=$v ;;
        IDLE_KILL_MIN)  IDLE=$v ;;
        SWITCH_RECLAIM) SWITCH=$v ;;
        MEM_ENABLE)     MEM_ENABLE=$v ;;
        MAX_PER_ROUND)  MAXROUND=$v ;;
    esac
done <<EOF
$KEYS
EOF
# 与 memctl 回退保持一致: 非法值 (含旧版 freeze) 显示 hard
case "$MODE_CFG" in soft|hard|kill) ;; *) MODE_CFG=hard ;; esac

# 辅助调速器状态 (与 memctl 默认值保持一致)
IDLEGOV_EN=1
IDLEGOV_INTERVAL=10
IDLEGOV_TIMEOUT=30
IDLEGOV_THD=5
IDLEGOV_POWER=0.8
KEYS=$(read_keys "$IDLE_CFG" idle_gov IDLE_GOV IDLE_INTERVAL IDLE_TIMEOUT IDLE_CPU_THD IDLE_POWER_W)
while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    case "$k" in
        IDLE_GOV)      IDLEGOV_EN=$v ;;
        IDLE_INTERVAL) IDLEGOV_INTERVAL=$v ;;
        IDLE_TIMEOUT)  IDLEGOV_TIMEOUT=$v ;;
        IDLE_CPU_THD)  IDLEGOV_THD=$v ;;
        IDLE_POWER_W)  IDLEGOV_POWER=$v ;;
    esac
done <<EOF
$KEYS
EOF
IDLEGOV_ACTIVE=0
[ -f "$GOV_STATE_FILE" ] && IDLEGOV_ACTIVE=1

# 核心开关状态 (字段由 script/corectl.sh status 提供, 单一事实来源)
CORECTL_ENABLE=0
CORECTL_BIG_OFF=0
CORECTL_MID_OFF=0
CORECTL_OFFLINED=""
CORECTL_ACTIVE=0
if [ -x "$CORECTL_SCRIPT" ]; then
    CI=$(sh "$CORECTL_SCRIPT" status 2>/dev/null)
    # 函数+heredoc 解析: 避免管道子 shell 导致变量赋值丢失
    parse_corectl() {
        local k v
        while IFS='=' read -r k v; do
            case "$k" in
                ENABLE)       CORECTL_ENABLE=$v ;;
                BIG_OFF)      CORECTL_BIG_OFF=$v ;;
                MID_OFF)      CORECTL_MID_OFF=$v ;;
                OFFLINE_LIST) CORECTL_OFFLINED=$v ;;
            esac
        done
    }
    parse_corectl <<EOF
$CI
EOF
fi
[ -n "$CORECTL_OFFLINED" ] && CORECTL_ACTIVE=1
case "$CORECTL_ENABLE" in 0|1) ;; *) CORECTL_ENABLE=0 ;; esac
case "$CORECTL_BIG_OFF" in ''|*[!0-9]*) CORECTL_BIG_OFF=0 ;; esac
case "$CORECTL_MID_OFF" in ''|*[!0-9]*) CORECTL_MID_OFF=0 ;; esac

# 前台应用: dumpsys 结果做短 TTL 缓存 (与 memctl.sh 的 FG_CACHE 同策略)
FG=unknown
FG_TS=$(stat -c %Y "$FG_CACHE_FILE" 2>/dev/null)
case "${FG_TS:-0}" in ''|*[!0-9]*) FG_TS=0 ;; esac
if [ "$(( $(date +%s) - FG_TS ))" -lt "$FG_CACHE_TTL" ] 2>/dev/null; then
    FG=$(cat "$FG_CACHE_FILE" 2>/dev/null)
    [ -n "$FG" ] || FG=unknown
else
    FG=$(dumpsys activity activities 2>/dev/null |
        grep -oE '(ResumedActivity|topResumedActivity): [A-Za-z0-9_.]+' |
        awk '{print $NF}' | head -n 1)
    if [ -n "$FG" ]; then
        echo "$FG" >"$FG_CACHE_FILE" 2>/dev/null
        # 前台应用属隐私信息, 收紧缓存文件权限, 防止其他 App 读取
        chmod 600 "$FG_CACHE_FILE" 2>/dev/null
    else
        FG=unknown
    fi
fi

# 日志最后一行 (JSON 转义, 防止引号/反斜杠破坏响应)
LAST_LOG=$(tail -n 1 "$LOG" 2>/dev/null | json_escape)

# 模块版本 (供页面 footer 展示, 便于反馈问题时核对)
VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2)
[ -n "$VER" ] || VER="unknown"

# Vulkan 渲染状态 (post-fs-data.sh / action.sh 持久化, 1=Vulkan 0=OpenGL)
VULKAN=1
VULKAN_STATE=/data/adb/uperf/vulkan.state
if [ -f "$VULKAN_STATE" ]; then
    vk=$(cat "$VULKAN_STATE" 2>/dev/null)
    [ "$vk" = "0" ] && VULKAN=0
fi

printf '{'
printf '"version":"%s",' "$VER"
printf '"vulkan":%s,' "$VULKAN"
printf '"uperf_running":%s,' "$UPERF_RUN"
printf '"memctl_running":%s,' "$MEMCTL_RUN"
printf '"powermode":"%s",' "$MODE"
printf '"mem_available_mb":%s,' "${MEMAVAIL_MB:-0}"
printf '"mem_enable":%s,' "$MEM_ENABLE"
printf '"mode":"%s",' "$MODE_CFG"
printf '"psi_threshold":%s,' "$PSI"
printf '"interval":%s,' "$INTERVAL"
printf '"idle_kill_min":%s,' "$IDLE"
printf '"switch_reclaim":%s,' "$SWITCH"
printf '"max_per_round":%s,' "$MAXROUND"
printf '"idle_gov_enable":%s,' "$IDLEGOV_EN"
printf '"idle_gov_active":%s,' "$IDLEGOV_ACTIVE"
printf '"idle_interval":%s,' "$IDLEGOV_INTERVAL"
printf '"idle_timeout":%s,' "$IDLEGOV_TIMEOUT"
printf '"idle_cpu_thd":%s,' "$IDLEGOV_THD"
printf '"idle_power_w":%s,' "$IDLEGOV_POWER"
printf '"corectl_enable":%s,' "$CORECTL_ENABLE"
printf '"corectl_big_off":%s,' "$CORECTL_BIG_OFF"
printf '"corectl_mid_off":%s,' "$CORECTL_MID_OFF"
printf '"corectl_active":%s,' "$CORECTL_ACTIVE"
printf '"corectl_offlined":"%s",' "$CORECTL_OFFLINED"
printf '"foreground":"%s",' "$FG"
printf '"last_log":"%s"' "$LAST_LOG"
printf '}\n'
