#!/system/bin/sh
#
# memctl.sh - fuyun 通用内存优化服务
#
# 功能:
#   1. 内存压力驱动的后台应用回收 (soft / hard / kill)
#   2. 推送应用进程保护清理 (原"微信QQ优化"的通用化, 支持任意应用)
#
# 配置:   /sdcard/Android/yc/uperf/fuyun.conf ([mem] 分区)
# 白名单: /sdcard/Android/yc/uperf/mem_whitelist.txt (支持 com.xxx.* 前缀规则)
# 分应用: /sdcard/Android/yc/uperf/mem_apps.txt
# 日志:   /sdcard/Android/yc/uperf/mem_log.txt

USER_PATH=/sdcard/Android/yc/uperf
# 26w34.6-B 第四轮: 配置合并 → fuyun.conf [mem] 分区 / whitelist.txt [mem] 分区
# (旧 mem_config.txt / mem_whitelist.txt 由 migrate_legacy 自动转换)
CFG="$USER_PATH/fuyun.conf"
WL="$USER_PATH/whitelist.txt"
APPS_FILE="$USER_PATH/mem_apps.txt"
LOG="$USER_PATH/mem_log.txt"
LAST_USED_FILE="$USER_PATH/last_used.txt"

# 公共工具库 (get_fg_pkg / wl_rules / wl_hit / rotate_log 等)
BASEDIR="$(dirname "$(readlink -f "$0")")"
[ -f "$BASEDIR/libcommon.sh" ] && . "$BASEDIR/libcommon.sh"

# 默认参数 (fuyun.conf [mem] 分区可覆盖, 配置修改后最多一个轮询周期生效)
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

# zram 主动压制 / 杀后清理
ZRAM_RECLAIM=1
ZRAM_RECLAIM_SIZE=64M
ZRAM_IDLE_MIN=5
CLEAN_CACHE_AFTER_KILL=1
TRIM_CACHE_SIZE=512M
KILLED_ANY=0

# 分应用策略表 (由 load_apps 填充): "pkg:mode pkg:mode ..."
APPS_RULES=""

# 单轮扫描缓存 (由 scan_procs / 各预计算函数填充, 供本轮所有消费者复用)
# PROC_TABLE:        " pid pkg uid pid pkg uid ..." 扁平列表 (每 3 个一组)
# IDLE_PKGS:         " pkg pkg ..." 本轮判定为闲置超时的包名
# ZRAM_RECENT_PKGS:  " pkg pkg ..." ZRAM_IDLE_MIN 分钟内已压制过的包名
# WL_EXACT/WL_PREFIX: 内存回收白名单 (精确包名 / 前缀通配)
PROC_TABLE=""
IDLE_PKGS=""
ZRAM_RECENT_PKGS=""
WL_EXACT=""
WL_PREFIX=""

# (辅助调速器已抽到 script/auxgov.sh 作为独立守护, 见其文件头)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"
}

# (rotate_log 复用 libcommon.sh 的实现, 调用: rotate_log "$LOG")

# 读取配置 (仅白名单键, 逐键赋值, 不用 eval 防 /sdcard 配置注入)
# 26w34.6-B: 从 fuyun.conf 的 [mem] 分区读取
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
            ZRAM_RECLAIM)   ZRAM_RECLAIM=$v ;;
            ZRAM_RECLAIM_SIZE) ZRAM_RECLAIM_SIZE=$v ;;
            ZRAM_IDLE_MIN)  ZRAM_IDLE_MIN=$v ;;
            CLEAN_CACHE_AFTER_KILL) CLEAN_CACHE_AFTER_KILL=$v ;;
            TRIM_CACHE_SIZE) TRIM_CACHE_SIZE=$v ;;
        esac
    done <<EOF
$(section_body "$CFG" mem)
EOF

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
    case "$ZRAM_RECLAIM" in 0|1) ;; *) ZRAM_RECLAIM=1 ;; esac
    echo "$ZRAM_RECLAIM_SIZE" | grep -qE '^[0-9]+[KMG]?$' || ZRAM_RECLAIM_SIZE=64M
    case "$ZRAM_IDLE_MIN" in
        ''|*[!0-9]*) ZRAM_IDLE_MIN=5 ;;
    esac
    [ "$ZRAM_IDLE_MIN" -le 1440 ] || ZRAM_IDLE_MIN=5
    case "$CLEAN_CACHE_AFTER_KILL" in 0|1) ;; *) CLEAN_CACHE_AFTER_KILL=1 ;; esac
    echo "$TRIM_CACHE_SIZE" | grep -qE '^[0-9]+[KMG]?$' || TRIM_CACHE_SIZE=512M
}

# (load_idle_cfg 已随辅助调速器移至 script/auxgov.sh)

# 刷新内存白名单 (每轮一次; 仅加载内存回收白名单 [mem] 分区, 调速器白名单由 auxgov.sh 自行加载)
load_whitelists() {
    WL_EXACT=$(section_body "$WL" mem | wl_rules exact)
    WL_PREFIX=$(section_body "$WL" mem | wl_rules prefix)
}

# $1: 包名; 返回 0 = 在白名单内(受保护)
# 外置白名单支持两种写法: 精确包名 / 前缀通配 (如 com.tencent.*)
# 命中判定复用 libcommon.sh 的 wl_hit
is_whitelisted() {
    local pkg="$1"
    [ -n "$pkg" ] || return 1
    wl_hit "$WL_EXACT" "$WL_PREFIX" "$pkg" && return 0
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
# 闲置判定改用本轮预计算的 IDLE_PKGS (原实现每个进程 grep|awk|tail 一次 last_used.txt)
idle_kill() {
    local fg="$1" now="$2" pid pkg uid mode g=0
    case "$-" in *f*) ;; *) g=1; set -f ;; esac
    set -- $PROC_TABLE
    [ "$g" = "1" ] && set +f
    while [ $# -ge 3 ]; do
        pid=$1; pkg=$2; uid=$3
        shift 3
        [ "$pkg" = "$fg" ] && continue
        is_whitelisted "$pkg" && continue
        mode=$(get_app_mode "$pkg")
        [ "$mode" = "off" ] && continue
        case " $IDLE_PKGS " in *" $pkg "*) ;; *) continue ;; esac
        am kill "$pkg" 2>/dev/null
        KILLED_ANY=1
        log "空闲淘汰: $pkg (闲置超 ${IDLE_KILL_MIN} 分钟)"
    done
}

# (get_fg_pkg 复用 libcommon.sh 的实现)

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

# 一次性扫描 /proc, 结果写入全局 PROC_TABLE (扁平列表: "pid pkg uid" 为一组)
# 原 collect_targets / idle_kill / zram_push_idle 各扫一遍 /proc, 合并为单轮一次。
# 排除规则与原实现逐条保持一致: cmdline 为空 / 含冒号 / 系统路径 / zygote / uid<10000。
# uid 改从 /proc/<pid>/status 读取 (替代 stat -c %u), 省去每个进程一次 fork。
scan_procs() {
    local d pid cmdline pkg uid line
    PROC_TABLE=""
    for d in /proc/[0-9]*; do
        [ -d "$d" ] || continue
        pid=${d##*/}
        [ -r "$d/cmdline" ] || continue
        cmdline=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)
        [ -n "$cmdline" ] || continue
        pkg=${cmdline%% *}
        case "$pkg" in
            *:*|/system/*|/vendor/*|/apex/*|zygote|zygote64) continue ;;
        esac
        uid=""
        while IFS= read -r line; do
            case "$line" in
                Uid:*) set -- $line; uid=$2; break ;;
            esac
        done <"$d/status" 2>/dev/null
        case "$uid" in ''|*[!0-9]*) continue ;; esac
        [ "$uid" -ge 10000 ] || continue
        PROC_TABLE="$PROC_TABLE $pid $pkg $uid"
    done
}

# 输出闲置超过 IDLE_KILL_MIN 分钟的包名 (空格分隔), 单轮一次 awk
# 未出现在 last_used.txt 的包不输出 —— 与原 is_idle 的保守策略一致 (无记录视为不空闲)
idle_pkgs() {
    awk -v now="$1" -v min="$((IDLE_KILL_MIN * 60))" '
        NF >= 2 { ts[$1] = $2 }
        END { for (p in ts) if (now - ts[p] >= min) printf "%s ", p }
    ' "$LAST_USED_FILE" 2>/dev/null
}

# 输出 ZRAM_IDLE_MIN 分钟内已压制过的包名 (空格分隔), 单轮一次 awk
zram_recent_pkgs() {
    awk -v now="$1" -v min="$((ZRAM_IDLE_MIN * 60))" '
        NF >= 2 { ts[$1] = $2 }
        END { for (p in ts) if (now - ts[p] < min) printf "%s ", p }
    ' "$ZRAM_PUSHED_FILE" 2>/dev/null
}

# 收集可回收目标, 输出 "pid pkg mode" (每行一行)
# 排除: 系统/原生进程(uid<10000)、系统组件、前台应用、白名单、per-app off
# 数据来源: 本轮 scan_procs 的缓存 (不再自行扫描 /proc)
collect_targets() {
    local fg="$1" pid pkg uid mode g=0
    case "$-" in *f*) ;; *) g=1; set -f ;; esac # 临时关 glob, 防止包名中的特殊字符被展开
    set -- $PROC_TABLE
    [ "$g" = "1" ] && set +f
    while [ $# -ge 3 ]; do
        pid=$1; pkg=$2; uid=$3
        shift 3
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

# ============ zram 主动压制 ============
# 把空闲后台进程的匿名内存换出到 zram, 进程保活、冷启动更快

ZRAM_PUSHED_FILE="$USER_PATH/zram_pushed.txt"

# zram 是否启用 (swap 中存在 zram)
zram_enabled() {
    swapon -s 2>/dev/null | grep -qi zram
}

# $1: pid; 尝试 cgroup v2 anon 回收 (换出到 zram), 失败自动忽略
push_pid_to_zram() {
    local pid="$1" cg
    cg=$(awk -F: '{print $NF}' "/proc/$pid/cgroup" 2>/dev/null | head -n 1)
    [ -n "$cg" ] || return 1
    [ -w "/sys/fs/cgroup$cg/memory.reclaim" ] || return 1
    echo "1 $ZRAM_RECLAIM_SIZE" >"/sys/fs/cgroup$cg/memory.reclaim" 2>/dev/null
}

# $1: 包名 $2: now; 记录压制时间
# (对应的"上次压制时间"查询已改为单轮一次的 zram_recent_pkgs 预计算, 不再逐包 grep|awk|tail)
zram_mark_pushed() {
    sed -i "/^$1 /d" "$ZRAM_PUSHED_FILE" 2>/dev/null
    echo "$1 $2" >>"$ZRAM_PUSHED_FILE" 2>/dev/null
}

# 对满足条件的空闲进程尝试压入 zram
# $1: 前台包名 $2: now
# 闲置判定用 IDLE_PKGS, "近期已压制"判定用 ZRAM_RECENT_PKGS (均为本轮预计算, 零逐进程 fork)
zram_push_idle() {
    [ "$ZRAM_RECLAIM" = "1" ] || return 0
    zram_enabled || return 0
    local fg="$1" now="$2" pid pkg uid mode g=0
    case "$-" in *f*) ;; *) g=1; set -f ;; esac
    set -- $PROC_TABLE
    [ "$g" = "1" ] && set +f
    while [ $# -ge 3 ]; do
        pid=$1; pkg=$2; uid=$3
        shift 3
        [ "$pkg" = "$fg" ] && continue
        is_whitelisted "$pkg" && continue
        mode=$(get_app_mode "$pkg")
        [ "$mode" = "off" ] && continue
        case " $IDLE_PKGS " in *" $pkg "*) ;; *) continue ;; esac
        # 距上次压制不足 ZRAM_IDLE_MIN 分钟则跳过
        case " $ZRAM_RECENT_PKGS " in *" $pkg "*) continue ;; esac
        if push_pid_to_zram "$pid"; then
            zram_mark_pushed "$pkg" "$now"
            log "zram 压制: $pkg pid=$pid"
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
            # 与 idle_kill 一致用 am kill (保留任务栈, 避免 SIGKILL 丢失未落盘数据)
            am kill "$pkg" 2>/dev/null
            log "清理 $pkg 非推送进程 pid=$pid [$cmdline]"
        done
    done
}

init_defaults() {
    mkdir -p "$USER_PATH"
    # 旧版多文件配置 → fuyun.conf/whitelist.txt 迁移 (幂等, 见 libcommon.sh)
    migrate_legacy "$USER_PATH"
    # 主配置/白名单由 setup.sh 复制 (或 migrate_legacy 转换); 兜底创建空文件, 键由默认值回退
    [ -f "$CFG" ] || : >"$CFG"
    [ -f "$WL" ] || : >"$WL"
    if [ ! -f "$APPS_FILE" ]; then
        cat >"$APPS_FILE" <<'EOF'
# fuyun 分应用回收策略: 每行 "包名 模式", # 开头为注释, 重启保留
# 模式: soft / hard / kill / off (off=永不回收, 等同白名单)
# 未列出的应用使用 fuyun.conf [mem] 的全局 MODE
EOF
    fi
}

main() {
    init_defaults
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
        load_whitelists
        rotate_log "$LOG"

        if [ "$MEM_ENABLE" != "1" ]; then
            sleep 300
            continue
        fi

        fg=$(get_fg_pkg)
        now=$(date +%s)
        touch_last_used "$fg" "$now"

        # 本轮只做一次 /proc 扫描与闲置表预计算, 供 idle_kill / zram_push_idle /
        # collect_targets 复用 (原先三处各自全量扫描并逐进程读文件)
        scan_procs
        # IDLE_KILL_MIN=0 (关闭杀进程) 时跳过闲置表计算, 省一轮 awk
        IDLE_PKGS=""
        [ "$IDLE_KILL_MIN" -gt 0 ] && IDLE_PKGS=$(idle_pkgs "$now")
        ZRAM_RECENT_PKGS=$(zram_recent_pkgs "$now")

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
        # zram 压制记录防膨胀
        if [ -f "$ZRAM_PUSHED_FILE" ]; then
            local zp_lines
            zp_lines=$(wc -l <"$ZRAM_PUSHED_FILE" 2>/dev/null)
            [ "${zp_lines:-0}" -gt 500 ] && tail -n 200 "$ZRAM_PUSHED_FILE" >"$ZRAM_PUSHED_FILE.tmp" && mv "$ZRAM_PUSHED_FILE.tmp" "$ZRAM_PUSHED_FILE"
        fi

        # 空闲淘汰 (开机保护期内跳过, 等 last_used 表建立)
        KILLED_ANY=0
        if [ "$IDLE_KILL_MIN" -gt 0 ] && [ $((now - start_epoch)) -ge $((IDLE_KILL_MIN * 60)) ]; then
            idle_kill "$fg" "$now"
        fi
        # 杀进程后清理系统缓存 (可选)
        if [ "$KILLED_ANY" = "1" ] && [ "$CLEAN_CACHE_AFTER_KILL" = "1" ]; then
            pm trim-caches "$TRIM_CACHE_SIZE" 2>/dev/null
            log "空闲淘汰后触发缓存清理 (${TRIM_CACHE_SIZE})"
            KILLED_ANY=0
        fi
        clean_push_apps "$fg" "$now"
        # 主动把空闲后台进程匿名内存压入 zram (进程保活)
        zram_push_idle "$fg" "$now"

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
        # 短间隔探测式睡眠: WebUI/终端的 reclaim_now 触发可即时响应,
        # 不必等满一个轮询周期 (原实现最长等 INTERVAL=300s 才响应)
        slept=0
        while [ "$slept" -lt "$INTERVAL" ]; do
            [ -f "$USER_PATH/reclaim_now" ] && break
            sleep 5
            slept=$((slept + 5))
        done
    done
}

main
