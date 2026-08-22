#!/system/bin/sh
# status.sh - 读取全部状态, 返回 JSON
. "$(dirname "$0")/lib.sh"

json_headers

# uperf / memctl 进程状态
UPERF_RUN=0
MEMCTL_RUN=0
pgrep -x uperf >/dev/null 2>&1 && UPERF_RUN=1
pgrep -f 'memctl.sh' >/dev/null 2>&1 && MEMCTL_RUN=1

# 当前性能模式
MODE=$(cat "$POWERMODE_FILE" 2>/dev/null)
[ -n "$MODE" ] || MODE=unknown

# 内存可用量
MEMAVAIL=$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')
MEMAVAIL_MB=$((MEMAVAIL / 1024))

# memctl 配置
MODE_CFG=$(get_cfg MODE)
PSI=$(get_cfg PSI_THRESHOLD)
INTERVAL=$(get_cfg INTERVAL)
IDLE=$(get_cfg IDLE_KILL_MIN)
SWITCH=$(get_cfg SWITCH_RECLAIM)
MEM_ENABLE=$(get_cfg MEM_ENABLE)
MAXROUND=$(get_cfg MAX_PER_ROUND)
[ -n "$MODE_CFG" ] || MODE_CFG=hard
# 与 memctl 回退保持一致: 非法值 (含旧版 freeze) 显示 hard
case "$MODE_CFG" in soft|hard|kill) ;; *) MODE_CFG=hard ;; esac
[ -n "$PSI" ] || PSI=30
[ -n "$INTERVAL" ] || INTERVAL=300
[ -n "$IDLE" ] || IDLE=5
[ -n "$SWITCH" ] || SWITCH=1
[ -n "$MEM_ENABLE" ] || MEM_ENABLE=1
[ -n "$MAXROUND" ] || MAXROUND=10

# 前台应用
FG=$(dumpsys activity activities 2>/dev/null |
    grep -oE '(ResumedActivity|topResumedActivity): [A-Za-z0-9_.]+' |
    awk '{print $NF}' | head -n 1)
[ -n "$FG" ] || FG=unknown

# 日志最后一行 (JSON 转义, 防止引号/反斜杠破坏响应)
LAST_LOG=$(tail -n 1 "$LOG" 2>/dev/null | sed 's/\\/\\\\/g;s/"/\\"/g')

# 辅助调速器状态 (与 memctl 默认值保持一致)
IDLEGOV_EN=$(grep "^IDLE_GOV=" "$IDLE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
IDLEGOV_INTERVAL=$(grep "^IDLE_INTERVAL=" "$IDLE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
IDLEGOV_TIMEOUT=$(grep "^IDLE_TIMEOUT=" "$IDLE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
IDLEGOV_THD=$(grep "^IDLE_CPU_THD=" "$IDLE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
IDLEGOV_POWER=$(grep "^IDLE_POWER_W=" "$IDLE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
[ -n "$IDLEGOV_EN" ] || IDLEGOV_EN=1
[ -n "$IDLEGOV_INTERVAL" ] || IDLEGOV_INTERVAL=10
[ -n "$IDLEGOV_TIMEOUT" ] || IDLEGOV_TIMEOUT=30
[ -n "$IDLEGOV_THD" ] || IDLEGOV_THD=5
[ -n "$IDLEGOV_POWER" ] || IDLEGOV_POWER=0.8
IDLEGOV_ACTIVE=0
[ -f "$GOV_STATE_FILE" ] && IDLEGOV_ACTIVE=1

# 频率限制状态 (与 freq_limit.sh 默认值保持一致)
FREQ_CAP=$(grep "^FREQ_CAP=" "$FREQ_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
FREQ_SCOPE=$(grep "^FREQ_SCOPE=" "$FREQ_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
FREQ_OFFSCREEN=$(grep "^FREQ_OFFSCREEN=" "$FREQ_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
FREQ_OFFCAP=$(grep "^FREQ_OFFSCREEN_CAP=" "$FREQ_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
echo "$FREQ_CAP" | grep -qE '^[0-9]+$' || FREQ_CAP=0
case "$FREQ_SCOPE" in big|all) ;; *) FREQ_SCOPE=big ;; esac
case "$FREQ_OFFSCREEN" in 0|1) ;; *) FREQ_OFFSCREEN=1 ;; esac
echo "$FREQ_OFFCAP" | grep -qE '^[0-9]+$' || FREQ_OFFCAP=1200000
# CPU 频率范围状态 (freq_range.txt)
FREQ_RANGE_ENABLE=$(grep "^FREQ_RANGE_ENABLE=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
[ "$FREQ_RANGE_ENABLE" = "1" ] || FREQ_RANGE_ENABLE=0
LITTLE_MIN=$(grep "^LITTLE_MIN=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
LITTLE_MAX=$(grep "^LITTLE_MAX=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
MID_MIN=$(grep "^MID_MIN=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
MID_MAX=$(grep "^MID_MAX=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
BIG_MIN=$(grep "^BIG_MIN=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
BIG_MAX=$(grep "^BIG_MAX=" "$FREQ_RANGE_CFG" 2>/dev/null | head -n 1 | cut -d= -f2)
echo "$LITTLE_MIN" | grep -qE '^[0-9]+$' || LITTLE_MIN=0
echo "$LITTLE_MAX" | grep -qE '^[0-9]+$' || LITTLE_MAX=0
echo "$MID_MIN" | grep -qE '^[0-9]+$' || MID_MIN=0
echo "$MID_MAX" | grep -qE '^[0-9]+$' || MID_MAX=0
echo "$BIG_MIN" | grep -qE '^[0-9]+$' || BIG_MIN=0
echo "$BIG_MAX" | grep -qE '^[0-9]+$' || BIG_MAX=0
FREQ_ACTIVE=0
grep -qE "fuyun_freq_(cap|min|max)_" /proc/mounts 2>/dev/null && FREQ_ACTIVE=1
FREQ_BIG_MAX=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -f "$p/cpuinfo_max_freq" ] || continue
    f=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
    case "$f" in ''|*[!0-9]*) continue ;; esac
    [ "$f" -gt "$FREQ_BIG_MAX" ] && FREQ_BIG_MAX=$f
done

printf '{'
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
printf '"freq_cap":%s,' "$FREQ_CAP"
printf '"freq_scope":"%s",' "$FREQ_SCOPE"
printf '"freq_active":%s,' "$FREQ_ACTIVE"
printf '"freq_offscreen":%s,' "$FREQ_OFFSCREEN"
printf '"freq_offcap":%s,' "$FREQ_OFFCAP"
printf '"freq_big_max_khz":%s,' "${FREQ_BIG_MAX:-0}"
printf '"foreground":"%s",' "$FG"
printf '"last_log":"%s"' "$LAST_LOG"
printf '}\n'
