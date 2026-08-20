#!/system/bin/sh
#
# memctl.sh - fuyun 通用内存优化服务
#
# 功能:
#   1. 内存压力驱动的后台应用回收 (soft / hard / kill)
#   2. 推送应用进程保护清理 (原"微信QQ优化"的通用化, 支持任意应用)
#
# 配置:   /sdcard/Android/yc/uperf/mem_config.txt
# 白名单: /sdcard/Android/yc/uperf/mem_whitelist.txt (支持 com.xxx.* 前缀规则)
# 分应用: /sdcard/Android/yc/uperf/mem_apps.txt
# 日志:   /sdcard/Android/yc/uperf/mem_log.txt

USER_PATH=/sdcard/Android/yc/uperf
CFG="$USER_PATH/mem_config.txt"
WL="$USER_PATH/mem_whitelist.txt"
APPS_FILE="$USER_PATH/mem_apps.txt"
LOG="$USER_PATH/mem_log.txt"
LAST_USED_FILE="$USER_PATH/last_used.txt"

# 默认参数 (mem_config.txt 可覆盖, 配置修改后最多一个轮询周期生效)
MEM_ENABLE=1
MODE=hard
INTERVAL=300
PSI_THRESHOLD=30
HARD_RECLAIM=32M
MAX_PER_ROUND=10
IDLE_KILL_MIN=5
SWITCH_RECLAIM=1
PUSH_KEEP="com.tencent.mm|com.tencent.mobileqq|com.tencent.tim"
KEEP_CMDLINE="push|daemon|msf"

# 分应用策略表 (由 load_apps 填充): "pkg:mode pkg:mode ..."
APPS_RULES=""

# ---------- 辅助调速器 (深度空闲压频) ----------
# 前台应用持续低 CPU 占用(如停留在静态页面)时, 把 uperf 各档位 idle 场景的功率预算
# 调低并重启 uperf, 压制空闲频率; 一旦 CPU 回升/切换应用/命中白名单/性能档位/息屏立即还原。
# 安全设计: 只改 uperf 的 idle 场景参数 —— 触摸瞬间 uperf 自动切 touch 场景,
#           深度参数只作用于真正的空闲段, 交互性能不受影响。
# 配置:   /sdcard/Android/yc/uperf/idle_gov.txt
# 白名单: /sdcard/Android/yc/uperf/idle_whitelist.txt (支持 com.xxx.* 前缀通配)

IDLE_CFG_FILE="$USER_PATH/idle_gov.txt"
IDLE_WL_FILE="$USER_PATH/idle_whitelist.txt"
UPERF_JSON="$USER_PATH/uperf.json"
UPERF_JSON_BAK="$USER_PATH/uperf.json.idlebak"
GOV_STATE_FILE="$USER_PATH/idle_gov.state"
BIN_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/bin"

# 默认参数 (idle_gov.txt 可覆盖, 配置修改后最多一个轮询周期生效)
IDLE_GOV=1
IDLE_INTERVAL=10
IDLE_TIMEOUT=30
IDLE_CPU_THD=5
IDLE_POWER_W=0.8

# 调速器运行状态 (仅 idle_gov_loop 子进程内使用)
GOV_STATE=mild
GOV_PID=""
GOV_PKG=""
GOV_MTIME=""
GOV_STREAK=0
GOV_PREV="" # "uptime utime stime" 上次 CPU 采样
GOV_PCT="" # 最近窗口 CPU 占用 (单核百分比, sample_cpu_pct 输出)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    local sz
    sz=$(stat -c %s "$LOG" 2>/dev/null)
    [ "${sz:-0}" -gt 1048576 ] && { mv "$LOG" "$LOG.old"; : >"$LOG"; }
}

# 读取配置 (仅白名单键, 逐键赋值, 不用 eval 防 /sdcard 配置注入)
load_cfg() {
    [ -f "$CFG" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        [ -n "$v" ] || continue
        case "$k" in
            MEM_ENABLE)     MEM_ENABLE=$v ;;
            MODE)           MODE=$v ;;
            INTERVAL)       INTERVAL=$v ;;
            PSI_THRESHOLD)  PSI_THRESHOLD=$v ;;
            HARD_RECLAIM)   HARD_RECLAIM=$v ;;
            MAX_PER_ROUND)  MAX_PER_ROUND=$v ;;
            IDLE_KILL_MIN)  IDLE_KILL_MIN=$v ;;
            SWITCH_RECLAIM) SWITCH_RECLAIM=$v ;;
            PUSH_KEEP)      PUSH_KEEP=$v ;;
            KEEP_CMDLINE)   KEEP_CMDLINE=$v ;;
        esac
    done <"$CFG"

    # 数值/枚举合法性校验, 防止异常配置导致除零、死循环或误杀
    case "$MEM_ENABLE" in 0|1) ;; *) MEM_ENABLE=1 ;; esac
    case "$MODE" in
        soft|hard|kill) ;;
        *)  log "MODE=$MODE 无效, 回退 hard (freeze 模式已移除)"
            MODE=hard ;;
    esac
    case "$INTERVAL" in
        ''|*[!0-9]*) INTERVAL=300 ;;
    esac
    [ "$INTERVAL" -ge 10 ] || INTERVAL=300
    [ "$INTERVAL" -le 86400 ] || INTERVAL=86400
    case "$PSI_THRESHOLD" in
        ''|*[!0-9]*) PSI_THRESHOLD=30 ;;
    esac
    { [ "$PSI_THRESHOLD" -ge 1 ] && [ "$PSI_THRESHOLD" -le 100 ]; } || PSI_THRESHOLD=30
    echo "$HARD_RECLAIM" | grep -qE '^[0-9]+[KMG]?$' || HARD_RECLAIM=32M
    case "$MAX_PER_ROUND" in
        ''|*[!0-9]*) MAX_PER_ROUND=10 ;;
    esac
    [ "$MAX_PER_ROUND" -ge 1 ] || MAX_PER_ROUND=10
    [ "$MAX_PER_ROUND" -le 50 ] || MAX_PER_ROUND=50
    case "$IDLE_KILL_MIN" in
        ''|*[!0-9]*) IDLE_KILL_MIN=5 ;;
    esac
    [ "$IDLE_KILL_MIN" -le 1440 ] || IDLE_KILL_MIN=5
    case "$SWITCH_RECLAIM" in 0|1) ;; *) SWITCH_RECLAIM=1 ;; esac
    # 列表/正则类配置: 只允许安全字符, 防止把用户配置变成意外正则或注入
    case "$PUSH_KEEP" in
        *[!A-Za-z0-9_.|]*) PUSH_KEEP="com.tencent.mm|com.tencent.mobileqq|com.tencent.tim" ;;
    esac
    case "$KEEP_CMDLINE" in
        *[!A-Za-z0-9_.|*+-]*) KEEP_CMDLINE="push|daemon|msf" ;;
    esac
}

# 读取辅助调速器配置 (仅白名单键, 与 load_cfg 相同防注入策略)
load_idle_cfg() {
    [ -f "$IDLE_CFG_FILE" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        [ -n "$v" ] || continue
        case "$k" in
            IDLE_GOV)      IDLE_GOV=$v ;;
            IDLE_INTERVAL) IDLE_INTERVAL=$v ;;
            IDLE_TIMEOUT)  IDLE_TIMEOUT=$v ;;
            IDLE_CPU_THD)  IDLE_CPU_THD=$v ;;
            IDLE_POWER_W)  IDLE_POWER_W=$v ;;
        esac
    done <"$IDLE_CFG_FILE"
    # 值合法性: 非法值回退默认, 避免除零/无限等待
    case "$IDLE_GOV" in 0|1) ;; *) IDLE_GOV=1 ;; esac
    case "$IDLE_INTERVAL" in
        ''|*[!0-9]*) IDLE_INTERVAL=10 ;;
    esac
    [ "$IDLE_INTERVAL" -ge 3 ] || IDLE_INTERVAL=10
    case "$IDLE_TIMEOUT" in
        ''|*[!0-9]*) IDLE_TIMEOUT=30 ;;
    esac
    [ "$IDLE_TIMEOUT" -ge 1 ] || IDLE_TIMEOUT=30
    case "$IDLE_CPU_THD" in
        ''|*[!0-9]*) IDLE_CPU_THD=5 ;;
    esac
    { [ "$IDLE_CPU_THD" -ge 1 ] && [ "$IDLE_CPU_THD" -le 100 ]; } || IDLE_CPU_THD=5
    case "$IDLE_POWER_W" in
        ''|*[!0-9.]*) IDLE_POWER_W=0.8 ;;
    esac
    echo "$IDLE_POWER_W" | grep -qE '^[0-9]+(\.[0-9]+)?$' || IDLE_POWER_W=0.8
}

# $1: 包名; 返回 0 = 在白名单内(受保护)
# 外置白名单支持两种写法: 精确包名 / 前缀通配 (如 com.tencent.*)
is_whitelisted() {
    local pkg="$1" line prefix
    if [ -f "$WL" ]; then
        while read -r line; do
            line=$(echo "$line" | sed 's/#.*//' | xargs)
            [ -n "$line" ] || continue
            case "$line" in
                *\*)
                    # 前缀规则: com.tencent.*
                    prefix=${line%\*}
                    [ "${pkg#"$prefix"}" != "$pkg" ] && return 0
                    ;;
                *)
                    [ "$line" = "$pkg" ] && return 0
                    ;;
            esac
        done <"$WL"
    fi
    # 内置兜底保护: 系统应用 / 桌面 / 输入法 (误伤代价太高)
    # 注意: com.android.* / com.google.android.* 已覆盖其全部子包名,
    #       后面的分支只列未被覆盖的厂商桌面/输入法
    case "$pkg" in
        android|com.android.*|com.google.android.*)
            return 0 ;;
        com.miui.home|com.miui.securitycenter|com.huawei.android.launcher|com.oplus.launcher|com.oneplus.launcher|com.vivo.launcher|com.bbk.launcher2|com.sec.android.app.launcher|com.meizu.flyme.launcher)
            return 0 ;;
        com.sohu.inputmethod.sogou|com.baidu.input|com.iflytek.inputmethod|com.qq.pinyin|com.sec.android.inputmethod)
            return 0 ;;
    esac
    return 1
}

# 读取分应用策略表
load_apps() {
    APPS_RULES=""
    [ -f "$APPS_FILE" ] || return 0
    local pkg mode
    while read -r pkg mode; do
        case "$pkg" in
            ""|\#*) continue ;;
        esac
        # 模式归一: 非法值 (含旧版 freeze) 回退全局 MODE, 避免"写了没生效"
        case "$mode" in
            soft|hard|kill|off) ;;
            *) mode="$MODE" ;;
        esac
        APPS_RULES="$APPS_RULES $pkg:$mode"
    done <"$APPS_FILE"
}

# $1: 包名; 输出该应用的专属模式 (未配置则输出空)
get_app_mode() {
    local r p m
    for r in $APPS_RULES; do
        p=${r%%:*}
        m=${r#*:}
        [ "$p" = "$1" ] && { echo "$m"; return; }
    done
}

# 系统当前可用内存 (KB)
mem_available_kb() {
    grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}'
}

# ============ 空闲淘汰机制 (只杀闲置超过 IDLE_KILL_MIN 分钟的应用) ============
# 维护 last_used.txt: "包名 最后使用时间戳", 每轮只更新前台应用, 零额外系统调用

# $1=包名 $2=now: 更新最后使用时间
touch_last_used() {
    [ -n "$1" ] || return 0
    sed -i "/^$1 /d" "$LAST_USED_FILE" 2>/dev/null
    echo "$1 $2" >>"$LAST_USED_FILE"
}

# $1=包名: 输出最后使用时间戳 (无记录输出空)
get_last_used() {
    grep "^$1 " "$LAST_USED_FILE" 2>/dev/null | awk '{print $2}' | tail -n 1
}

# $1=包名 $2=now: 返回 0 = 已闲置超过 IDLE_KILL_MIN 分钟
# 无使用记录视为"不空闲" (保守, 避免误杀刚启动/未知应用)
is_idle() {
    local lu
    lu=$(get_last_used "$1")
    [ -n "$lu" ] || return 1
    [ $(( $2 - lu )) -ge $((IDLE_KILL_MIN * 60)) ]
}

# 空闲淘汰: 非前台 + 闲置超时 + 非系统应用 + 非白名单 + 非 per-app off → am kill
# $1=前台包名 $2=now
idle_kill() {
    local fg="$1" now="$2" pid cmdline pkg uid mode
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [ -r "/proc/$pid/cmdline" ] || continue
        cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
        [ -n "$cmdline" ] || continue
        pkg=${cmdline%% *}
        case "$pkg" in
            *:*|/system/*|/vendor/*|/apex/*|zygote|zygote64) continue ;;
        esac
        uid=$(stat -c %u "/proc/$pid" 2>/dev/null)
        [ "${uid:-0}" -ge 10000 ] || continue
        [ "$pkg" = "$fg" ] && continue
        is_whitelisted "$pkg" && continue
        mode=$(get_app_mode "$pkg")
        [ "$mode" = "off" ] && continue
        is_idle "$pkg" "$now" || continue
        am kill "$pkg" 2>/dev/null
        log "空闲淘汰: $pkg (闲置超 ${IDLE_KILL_MIN} 分钟)"
    done
}

# 当前前台应用包名
get_fg_pkg() {
    dumpsys activity activities 2>/dev/null |
        grep -oE '(ResumedActivity|topResumedActivity): [A-Za-z0-9_.]+' |
        awk '{print $NF}' | head -n 1
}

# 带短 TTL 缓存的前台包名: 降低 dumpsys 调用频率 (辅助调速器高频场景)
# 必须以普通语句调用 (不能放进 $( )), 函数内更新全局 FG_CACHE/FG_CACHE_TS
FG_CACHE=""
FG_CACHE_TS=0
FG_CACHE_TTL=8
get_fg_pkg_cached() {
    local now
    now=$(date +%s)
    if [ -n "$FG_CACHE" ] && [ $((now - FG_CACHE_TS)) -lt "$FG_CACHE_TTL" ]; then
        return 0
    fi
    FG_CACHE=$(get_fg_pkg)
    FG_CACHE_TS=$now
}

# 内存压力检查: /proc/pressure/memory 的 full avg10 >= PSI_THRESHOLD 才回收
# (无 PSI 接口时保守返回"压力高", 保证功能仍可用)
mem_pressure_high() {
    [ -r /proc/pressure/memory ] || return 0
    local full
    full=$(mem_pressure_full_avg)
    [ "${full:-0}" -ge "$PSI_THRESHOLD" ]
}

# 当前 full avg10 整数部分 (无 PSI 输出空)
mem_pressure_full_avg() {
    [ -r /proc/pressure/memory ] || return 0
    grep '^full' /proc/pressure/memory 2>/dev/null | awk '{print $2}' | sed 's/avg10=//' | cut -d. -f1
}

# 收集可回收目标, 输出 "pid pkg mode" (每行一行)
# 排除: 系统/原生进程(uid<10000)、系统组件、前台应用、白名单、per-app off
collect_targets() {
    local fg="$1" pid cmdline pkg uid mode
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [ -r "/proc/$pid/cmdline" ] || continue
        cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
        [ -n "$cmdline" ] || continue
        pkg=${cmdline%% *}
        case "$pkg" in
            *:*|/system/*|/vendor/*|/apex/*|zygote|zygote64) continue ;;
        esac
        uid=$(stat -c %u "/proc/$pid" 2>/dev/null)
        [ "${uid:-0}" -ge 10000 ] || continue
        [ "$pkg" = "$fg" ] && continue
        is_whitelisted "$pkg" && continue
        mode=$(get_app_mode "$pkg")
        [ "$mode" = "off" ] && continue
        echo "$pid $pkg ${mode:-$MODE}"
    done
}

# 按 mode 回收单个进程
reclaim_one() {
    local pid="$1" pkg="$2" mode="$3" cg
    case "$mode" in
    soft)
        am send-trim-memory "$pid" 80 2>/dev/null
        ;;
    hard)
        # 1) 通知应用释放缓存 (TRIM_MEMORY_COMPLETE)
        am send-trim-memory "$pid" 80 2>/dev/null
        # 2) 内核回收该进程页缓存 (需内核支持, 失败自动忽略)
        [ -w "/proc/$pid/reclaim" ] && echo 1 >"/proc/$pid/reclaim" 2>/dev/null
        # 3) cgroup v2 memory.reclaim (需 cgroup v2 内核, 失败自动忽略)
        cg=$(awk -F: '{print $NF}' "/proc/$pid/cgroup" 2>/dev/null | head -n 1)
        if [ -n "$cg" ] && [ -w "/sys/fs/cgroup$cg/memory.reclaim" ]; then
            echo "0 $HARD_RECLAIM" >"/sys/fs/cgroup$cg/memory.reclaim" 2>/dev/null
        fi
        ;;
    kill)
        # 杀后台进程但保留任务栈 (Android 12+ 最佳)
        am kill "$pkg" 2>/dev/null
        ;;
    esac
}

# 前台切换回收: 对指定包名的所有进程做内存回收 (trim + 内核 reclaim, 不杀进程)
# $1=包名
reclaim_pkg() {
    local pkg="$1" pid cg
    for pid in $(pgrep -f "^$pkg" 2>/dev/null); do
        am send-trim-memory "$pid" 80 2>/dev/null
        [ -w "/proc/$pid/reclaim" ] && echo 1 >"/proc/$pid/reclaim" 2>/dev/null
        cg=$(awk -F: '{print $NF}' "/proc/$pid/cgroup" 2>/dev/null | head -n 1)
        if [ -n "$cg" ] && [ -w "/sys/fs/cgroup$cg/memory.reclaim" ]; then
            echo "0 $HARD_RECLAIM" >"/sys/fs/cgroup$cg/memory.reclaim" 2>/dev/null
        fi
    done
}

# 推送应用保护清理: 仅保留含 KEEP_CMDLINE 关键词的进程
# (原"微信QQ优化"通用化: PUSH_KEEP 支持任意包名; 遵循空闲规则, 近期用过的应用不清理)
clean_push_apps() {
    local fg="$1" now="$2" pkg pid cmdline
    for pkg in $(echo "$PUSH_KEEP" | tr '|' ' '); do
        [ -n "$pkg" ] || continue
        [ "$pkg" = "$fg" ] && continue
        is_idle "$pkg" "$now" || continue
        for pid in $(pgrep -f "^$pkg" 2>/dev/null); do
            [ -r "/proc/$pid/cmdline" ] || continue
            cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
            echo "$cmdline" | grep -qE "$KEEP_CMDLINE" && continue
            kill -9 "$pid" 2>/dev/null
            log "清理 $pkg 非推送进程 pid=$pid [$cmdline]"
        done
    done
}

# ============ 辅助调速器: 深度空闲压频 ============

# 屏幕状态 (与 service.sh 同款双判断, 兼容不同版本 dumpsys 输出)
is_screen_on() {
    dumpsys power 2>/dev/null | grep -qE "mWakefulness=Awake|mHoldingDisplaySuspendBlocker=true"
}

# $1: 包名; 返回 0 = 命中调速器白名单 (不压制频率)
idle_wl_hit() {
    local pkg="$1" line prefix
    [ -f "$IDLE_WL_FILE" ] || return 1
    while read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -n "$line" ] || continue
        case "$line" in
            *\*)
                prefix=${line%\*}
                [ "${pkg#"$prefix"}" != "$pkg" ] && return 0
                ;;
            *)
                [ "$line" = "$pkg" ] && return 0
                ;;
        esac
    done <"$IDLE_WL_FILE"
    return 1
}

# $1: 前台包名; 返回 0 = 当前有效档位为 performance/fast (调速器应禁用)
# 档位来源优先级: perapp 精确规则 > * 通配规则 > - 默认规则 > cur_powermode.txt
# (perapp 特殊行语义按"越靠前越具体"处理, 只有性能档才影响调速器, 误判方向为不压)
is_perf_mode() {
    local pkg="$1" mode
    mode=$(grep "^$pkg " "$USER_PATH/perapp_powermode.txt" 2>/dev/null | head -n 1 | awk '{print $2}')
    [ -n "$mode" ] || mode=$(grep "^\* " "$USER_PATH/perapp_powermode.txt" 2>/dev/null | head -n 1 | awk '{print $2}')
    [ -n "$mode" ] || mode=$(grep "^- " "$USER_PATH/perapp_powermode.txt" 2>/dev/null | head -n 1 | awk '{print $2}')
    [ -n "$mode" ] || mode=$(cat "$USER_PATH/cur_powermode.txt" 2>/dev/null)
    case "$mode" in
        performance|fast) return 0 ;;
    esac
    return 1
}

# $1: pid → 输出 "uptime utime stime" (读取失败输出空)
# 注意: /proc/<pid>/stat 的 comm 字段可能含空格, 先剥掉 "pid (comm) ",
#       之后 utime/stime 是第 12/13 个字段 (state, ppid, pgrp, session,
#       tty_nr, tpgid, flags, minflt, cminflt, majflt, cmajflt, utime, stime)
read_cpu_stat() {
    set -- $(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null)
    [ $# -ge 13 ] || return 1
    # 多位数位置参数必须用 ${} (POSIX: $12 会被解析成 $1 加字面量 "2")
    echo "$(date +%s) ${12} ${13}"
}

# $1: pid → 把最近一个轮询窗口的 CPU 占用写入 GOV_PCT (单核百分比, 向下取整)
# 无上次采样基线/时钟回退/pid 被复用 → 只刷新基线, 返回 1
# 注意: 结果走全局变量而非 echo, 调用方用 $( ) 捕获时函数内状态赋值会丢在子 shell
sample_cpu_pct() {
    local pid="$1" now u s pt pu ps
    set -- $(read_cpu_stat "$pid") || return 1
    now=$1; u=$2; s=$3
    if [ -n "$GOV_PREV" ]; then
        set -- $GOV_PREV
        pt=$1; pu=$2; ps=$3
        GOV_PREV="$now $u $s"
        # 窗口内 utime/stime 回退说明 pid 被新进程复用, 重建基线
        { [ "$u" -ge "$pu" ] && [ "$s" -ge "$ps" ]; } || return 1
        [ $((now - pt)) -gt 0 ] || return 1
        # (du+ds) 个时钟节拍 / dt 秒 = 单核百分比 (USER_HZ=100)
        GOV_PCT=$(( ( (u - pu) + (s - ps) ) / (now - pt) ))
        return 0
    fi
    GOV_PREV="$now $u $s"
    return 1
}

# 重启 uperf 使配置生效 (仅状态切换时调用, 频率极低)
restart_uperf() {
    local pid
    [ -x "$BIN_DIR/uperf" ] || { log "辅助调速: uperf 二进制缺失, 无法重启"; return 1; }
    [ -f "$USER_PATH/uperf_log.txt" ] && mv -f "$USER_PATH/uperf_log.txt" "$USER_PATH/uperf_log.txt.bak"
    killall uperf 2>/dev/null
    sleep 0.5
    nohup "$BIN_DIR/uperf" "$UPERF_JSON" -o "$USER_PATH/uperf_log.txt" >/dev/null 2>&1 &
    sleep 2
    # uperf 不应抢占前台任务 (与开机启动一致)
    pid=$(pgrep -x uperf | head -n 1)
    [ -n "$pid" ] && echo "$pid" >/dev/cpuset/background/tasks 2>/dev/null
}

# $1: 功率预算(瓦) $2: uperf.json 路径; 成功返回 0
# 给每个档位的 "idle" 场景块设置 cpu.slowLimitPower: 已有则替换, 没有则插入
# 支持模块自带的多行格式与用户改写的单行/空块格式; 只匹配 "idle": { 对象,
# 不会误伤 sched 模块的 "idle": "c1" 或 switcher 的 "idle": 0.0 等标量键
patch_idle_power() {
    local p="$1" f="$2" tmp
    tmp="$f.tmp"
    awk -v p="$p" '
        {
            # 行内花括号净计数 (idle 块内均为标量键, 无嵌套对象)
            n = 0
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") n++
                else if (c == "}") n--
            }
            if (in_idle) {
                if ($0 ~ /"cpu\.slowLimitPower"[[:space:]]*:/) {
                    sub(/"cpu\.slowLimitPower"[[:space:]]*:[[:space:]]*[0-9.]+/, "\"cpu.slowLimitPower\": " p, $0)
                    seen = 1
                    buf[++bn] = $0
                    next
                }
                if (n < 0) {
                    # idle 块闭合行: 块内无该键时, 最后一行补逗号后插入 (插入行是末键, 不带尾逗号)
                    for (i = 1; i <= bn; i++) {
                        if (!seen && i == bn) print buf[i] ","
                        else print buf[i]
                    }
                    if (!seen) print "        \"cpu.slowLimitPower\": " p
                    print
                    in_idle = 0
                    next
                }
                buf[++bn] = $0
                next
            }
            if ($0 ~ /"idle"[[:space:]]*:[[:space:]]*\{/) {
                if ($0 ~ /\}/) {
                    # 单行块: 行内替换; 空块直接填入; 否则在首个 } 前插入
                    if ($0 ~ /"cpu\.slowLimitPower"/) {
                        sub(/"cpu\.slowLimitPower"[[:space:]]*:[[:space:]]*[0-9.]+/, "\"cpu.slowLimitPower\": " p, $0)
                        print
                    } else if ($0 ~ /\{[[:space:]]*\}/) {
                        sub(/\{[[:space:]]*\}/, "{ \"cpu.slowLimitPower\": " p " }", $0)
                        print
                    } else if (match($0, /\}/)) {
                        print substr($0, 1, RSTART - 1) ", \"cpu.slowLimitPower\": " p " " substr($0, RSTART)
                    } else {
                        print
                    }
                    next
                }
                in_idle = 1
                seen = 0
                bn = 0
                buf[++bn] = $0
                next
            }
            print
        }
    ' "$f" >"$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$f"
}

# 进入深度空闲: 备份原始配置 → 压低 idle 功率预算 → 重启 uperf
# $1: 前台包名 $2: 前台 pid
enter_deep_idle() {
    local pkg="$1" pid="$2" mt
    [ -f "$UPERF_JSON" ] || return 1
    [ -f "$GOV_STATE_FILE" ] && { GOV_STATE=deep; return 0; } # 幂等: 已处于深度空闲
    cp -f "$UPERF_JSON" "$UPERF_JSON_BAK" 2>/dev/null || return 1
    patch_idle_power "$IDLE_POWER_W" "$UPERF_JSON" || { rm -f "$UPERF_JSON_BAK"; return 1; }
    mt=$(stat -c %Y "$UPERF_JSON" 2>/dev/null)
    echo "deep $pid $pkg $mt" >"$GOV_STATE_FILE"
    restart_uperf
    log "辅助调速: 进入深度空闲 $pkg (cpu<${IDLE_CPU_THD}% 持续≥${IDLE_TIMEOUT}s), idle 功率预算 ${IDLE_POWER_W}W"
    GOV_STATE=deep
    GOV_PID=$pid
    GOV_PKG=$pkg
    GOV_MTIME=$mt
    GOV_STREAK=0
    # GOV_PREV 保留: 深度状态首个巡检即可基于旧窗口检测 CPU 回升, 退出响应更快
}

# 退出深度空闲: 还原配置 → 重启 uperf
# 深度空闲期间用户若修改了 uperf.json (mtime 变化), 不覆盖其修改, 仅告警
exit_deep_idle() {
    local cur_mt
    [ -f "$GOV_STATE_FILE" ] || { GOV_STATE=mild; return 0; }
    cur_mt=$(stat -c %Y "$UPERF_JSON" 2>/dev/null)
    if [ -n "$GOV_MTIME" ] && [ "$cur_mt" = "$GOV_MTIME" ]; then
        mv -f "$UPERF_JSON_BAK" "$UPERF_JSON" 2>/dev/null
    else
        rm -f "$UPERF_JSON_BAK" 2>/dev/null
        log "辅助调速: 退出深度空闲, 但 uperf.json 期间被修改, 保留修改 (深度参数可能残留, 重启 uperf 可恢复原参数)"
    fi
    rm -f "$GOV_STATE_FILE"
    restart_uperf
    log "辅助调速: 退出深度空闲, 恢复原调度"
    GOV_STATE=mild
    GOV_PID=""
    GOV_PKG=""
    GOV_MTIME=""
    GOV_STREAK=0
    GOV_PREV=""
}

# 深度空闲判定步进 (前台应用持续低 CPU → 进入深度空闲)
gov_step_mild() {
    local fg pid
    is_screen_on || { GOV_STREAK=0; GOV_PREV=""; return; }
    get_fg_pkg_cached
    fg=$FG_CACHE
    [ -n "$fg" ] || { GOV_STREAK=0; GOV_PREV=""; return; }
    is_perf_mode "$fg" && { GOV_STREAK=0; GOV_PREV=""; return; }
    idle_wl_hit "$fg" && { GOV_STREAK=0; GOV_PREV=""; return; }
    pid=$(pidof "$fg" 2>/dev/null | awk '{print $1}')
    [ -n "$pid" ] || { GOV_STREAK=0; GOV_PREV=""; return; }
    # 前台应用切换时丢弃旧采样基线
    if [ "$pid" != "$GOV_PID" ]; then
        GOV_PID=$pid
        GOV_PREV=""
    fi
    GOV_PCT=""
    sample_cpu_pct "$pid" || { GOV_STREAK=0; return; }
    if [ "$GOV_PCT" -lt "$IDLE_CPU_THD" ]; then
        GOV_STREAK=$((GOV_STREAK + 1))
    else
        GOV_STREAK=0
    fi
    if [ $((GOV_STREAK * IDLE_INTERVAL)) -ge "$IDLE_TIMEOUT" ]; then
        enter_deep_idle "$fg" "$pid"
    fi
}

# 深度空闲维持/退出步进 (任何活跃信号立即还原)
gov_step_deep() {
    local fg pid
    is_screen_on || { exit_deep_idle; return; }
    # 每轮重新确认前台应用, 防止切到新应用后仍按旧应用压频
    get_fg_pkg_cached
    fg=$FG_CACHE
    [ -n "$fg" ] || { exit_deep_idle; return; }
    [ "$fg" = "$GOV_PKG" ] || { exit_deep_idle; return; }
    pid=$(pidof "$fg" 2>/dev/null | awk '{print $1}')
    [ -n "$pid" ] || { exit_deep_idle; return; }
    is_perf_mode "$fg" && { exit_deep_idle; return; }
    idle_wl_hit "$fg" && { exit_deep_idle; return; }
    # 前台进程 pid 变化时重建采样基线
    if [ "$pid" != "$GOV_PID" ]; then
        GOV_PID=$pid
        GOV_PREV=""
    fi
    GOV_PCT=""
    sample_cpu_pct "$GOV_PID" && [ "$GOV_PCT" -ge "$IDLE_CPU_THD" ] && exit_deep_idle
}

# 辅助调速器主循环 (独立子进程运行, 与内存回收互不干扰)
# 深度空闲期间以 5s 快节奏巡检, 保证 CPU 回升/视频自动播放等场景快速还原
idle_gov_loop() {
    local step_sleep
    # 恢复持久化状态: memctl 重启时 uperf.json 可能已处于深度空闲配置
    if [ -f "$GOV_STATE_FILE" ]; then
        set -- $(cat "$GOV_STATE_FILE" 2>/dev/null)
        if [ "$1" = "deep" ] && [ -f "$UPERF_JSON_BAK" ]; then
            GOV_STATE=deep
            GOV_PID=$2
            GOV_PKG=$3
            GOV_MTIME=$4
        else
            rm -f "$GOV_STATE_FILE"
        fi
    fi
    log "辅助调速器启动 (IDLE_GOV=$IDLE_GOV 间隔=${IDLE_INTERVAL}s 超时=${IDLE_TIMEOUT}s 阈值=${IDLE_CPU_THD}% 功率=${IDLE_POWER_W}W)"
    while true; do
        load_idle_cfg
        if [ "$IDLE_GOV" != "1" ]; then
            exit_deep_idle
            GOV_STREAK=0
            GOV_PREV=""
            sleep 30
            continue
        fi
        if [ "$GOV_STATE" = "deep" ]; then
            gov_step_deep
            step_sleep=5
        else
            gov_step_mild
            step_sleep=$IDLE_INTERVAL
        fi
        sleep "$step_sleep"
    done
}

# 首次运行生成默认白名单/分应用策略 (不覆盖用户已有文件)
init_defaults() {
    mkdir -p "$USER_PATH"
    if [ ! -f "$WL" ]; then
        cat >"$WL" <<'EOF'
# fuyun 内存回收白名单: 每行一个包名, # 开头为注释, 重启保留
# 支持前缀通配: 例如 com.tencent.* 保护所有腾讯应用
# 白名单内的应用不会被回收/清理 (系统应用/桌面/输入法已内置保护)
com.tencent.mm
com.tencent.mobileqq
com.tencent.tim
com.coolapk.market
com.android.mms
com.android.email
com.google.android.apps.messaging
com.android.cellbroadcastreceiver
EOF
    fi
    if [ ! -f "$APPS_FILE" ]; then
        cat >"$APPS_FILE" <<'EOF'
# fuyun 分应用回收策略: 每行 "包名 模式", # 开头为注释, 重启保留
# 模式: soft / hard / kill / off (off=永不回收, 等同白名单)
# 未列出的应用使用 mem_config.txt 的全局 MODE
EOF
    fi
    if [ ! -f "$IDLE_CFG_FILE" ]; then
        cat >"$IDLE_CFG_FILE" <<'EOF'
# fuyun 辅助调速器配置 (重启保留, 修改后最多一个轮询周期生效)
# 作用: 前台应用持续低 CPU 占用时压低 uperf idle 场景功率预算, 压制空闲频率
# 详细说明见安装包 config/idle_gov.txt

# 总开关: 1=启用 0=停用
IDLE_GOV=1

# 判定轮询间隔 (秒)
IDLE_INTERVAL=10

# 进入深度空闲需要的前台应用持续低 CPU 时长 (秒)
IDLE_TIMEOUT=30

# 前台应用 CPU 占用阈值 (占单核百分比): 低于该值视为空闲
IDLE_CPU_THD=5

# 深度空闲时 uperf idle 场景的功率预算 (瓦): 越低频率压得越狠
IDLE_POWER_W=0.8
EOF
    fi
    if [ ! -f "$IDLE_WL_FILE" ]; then
        cat >"$IDLE_WL_FILE" <<'EOF'
# fuyun 辅助调速器白名单: 每行一个包名, # 开头为注释, 重启保留
# 支持前缀通配: 例如 com.tencent.* 排除所有腾讯应用
# 前台应用命中白名单时永不压制频率
EOF
    fi
}

main() {
    init_defaults
    # 辅助调速器 (深度空闲压频): 独立子进程, 与内存回收互不干扰
    idle_gov_loop &
    # 等待系统完全启动, 并等应用加载稳定后再开始清理
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 10
    done
    sleep 30
    log "内存优化服务启动 (MODE=$MODE INTERVAL=${INTERVAL}s PSI_THRESHOLD=$PSI_THRESHOLD IDLE_KILL_MIN=${IDLE_KILL_MIN}min)"

    local fg now
    local start_epoch skip_reclaim last_fg
    start_epoch=$(date +%s)   # 开机保护: 启动后前 IDLE_KILL_MIN 分钟不杀任何应用
    skip_reclaim=0            # 回收无收益时置 1, 下一轮跳过防抖动
    fg=""
    last_fg=""
    now=$start_epoch

    while true; do
        load_cfg
        load_apps
        rotate_log

        if [ "$MEM_ENABLE" != "1" ]; then
            sleep 300
            continue
        fi

        fg=$(get_fg_pkg)
        now=$(date +%s)
        touch_last_used "$fg" "$now"

        # 切换触发回收: 前台应用变化时, 对"切走的旧前台"回收内存 (不杀进程)
        if [ "$SWITCH_RECLAIM" = "1" ] && [ -n "$last_fg" ] && [ -n "$fg" ] && [ "$fg" != "$last_fg" ]; then
            if ! is_whitelisted "$last_fg" && [ "$(get_app_mode "$last_fg")" != "off" ]; then
                reclaim_pkg "$last_fg"
                log "切换回收: $last_fg → $fg"
            fi
        fi
        [ -n "$fg" ] && last_fg="$fg"

        # 手动/WebUI 触发回收: 存在 reclaim_now 文件时立即回收一轮
        if [ -f "$USER_PATH/reclaim_now" ]; then
            rm -f "$USER_PATH/reclaim_now"
            collect_targets "$fg" | head -n "$MAX_PER_ROUND" | while read -r pid pkg mode; do
                reclaim_one "$pid" "$pkg" "$mode"
            done
            log "手动触发回收一轮"
        fi

        # last_used 表防膨胀: 超过 500 行时清理 (保留最近 200 条)
        if [ -f "$LAST_USED_FILE" ]; then
            local lu_lines
            lu_lines=$(wc -l <"$LAST_USED_FILE" 2>/dev/null)
            [ "${lu_lines:-0}" -gt 500 ] && tail -n 200 "$LAST_USED_FILE" >"$LAST_USED_FILE.tmp" && mv "$LAST_USED_FILE.tmp" "$LAST_USED_FILE"
        fi

        # 空闲淘汰 (开机保护期内跳过, 等 last_used 表建立)
        if [ "$IDLE_KILL_MIN" -gt 0 ] && [ $((now - start_epoch)) -ge $((IDLE_KILL_MIN * 60)) ]; then
            idle_kill "$fg" "$now"
        fi
        clean_push_apps "$fg" "$now"

        # 仅内存压力高时才回收, 不与系统 LMKD 抢活
        if [ "$skip_reclaim" = "1" ]; then
            skip_reclaim=0
        elif mem_pressure_high; then
            # 回收前后对比 MemAvailable, 记录实际释放量
            # 压力非常高时允许单轮多回收一些 (上限 50, 仍受 MAX_PER_ROUND 约束)
            local before after freed reclaim_limit full_avg
            reclaim_limit=$MAX_PER_ROUND
            full_avg=$(mem_pressure_full_avg)
            if [ -n "$full_avg" ] && [ $((full_avg)) -ge $((PSI_THRESHOLD * 2)) ]; then
                reclaim_limit=$((MAX_PER_ROUND * 2))
                [ "$reclaim_limit" -le 50 ] || reclaim_limit=50
            fi
            before=$(mem_available_kb)
            collect_targets "$fg" | head -n "$reclaim_limit" | while read -r pid pkg mode; do
                reclaim_one "$pid" "$pkg" "$mode"
            done
            after=$(mem_available_kb)
            freed=$((after - before))
            if [ "$freed" -gt 0 ]; then
                log "内存压力高, 回收一轮, 可用内存 +$((freed / 1024))MB"
            else
                log "内存压力高, 回收一轮 (可用内存变化 $((freed / 1024))MB), 下轮跳过"
                skip_reclaim=1
            fi
        fi
        sleep "$INTERVAL"
    done
}

main
