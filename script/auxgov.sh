#!/system/bin/sh
#
# auxgov.sh - fuyun 辅助调速器 (深度空闲动态降频 + 联动关核)
#
# 独立守护进程: 前台应用持续低 CPU 占用时, 把 uperf 各档位 idle 场景的功率预算
# 调低并重启 uperf, 压制空闲频率; 一旦 CPU 回升/切换应用/命中白名单/性能档/息屏立即还原。
# 安全设计: 只改 uperf 的 idle 场景参数 —— 触摸瞬间 uperf 自动切 touch 场景,
#           深度参数只作用于真正的空闲段, 交互性能不受影响。
# 深度空闲期间联动 corectl.sh 关核 (受 fuyun.conf [corectl] 的 IDLE_OFF / CORECTL_ENABLE 约束)。
#
# 配置:   /sdcard/Android/yc/uperf/fuyun.conf ([idle_gov] 分区)
# 白名单: /sdcard/Android/yc/uperf/idle_whitelist.txt (支持 com.xxx.* 前缀通配)

USER_PATH=/sdcard/Android/yc/uperf
# 26w34.6-B 第四轮: 配置合并 → fuyun.conf [idle_gov] 分区 / whitelist.txt [idle_gov] 分区
IDLE_CFG_FILE="$USER_PATH/fuyun.conf"
IDLE_WL_FILE="$USER_PATH/whitelist.txt"
UPERF_JSON="$USER_PATH/uperf.json"
UPERF_JSON_BAK="$USER_PATH/uperf.json.idlebak"
GOV_STATE_FILE="$USER_PATH/idle_gov.state"
BASEDIR="$(dirname "$(readlink -f "$0")")"
BIN_DIR="$BASEDIR/bin"

# (F8: 独立日志文件 + 轮转, 不再写入 mem_log.txt)
AUXGOV_LOG="$USER_PATH/auxgov.log.txt"
# 公共工具库 (get_fg_pkg / wl_rules / wl_hit / rotate_log 等)
[ -f "$BASEDIR/libcommon.sh" ] && . "$BASEDIR/libcommon.sh"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$AUXGOV_LOG"
    rotate_log "$AUXGOV_LOG"
}
# ---------- 辅助调速器 (深度空闲压频) ----------
# 前台应用持续低 CPU 占用(如停留在静态页面)时, 把 uperf 各档位 idle 场景的功率预算
# 调低并重启 uperf, 压制空闲频率; 一旦 CPU 回升/切换应用/命中白名单/性能档位/息屏立即还原。
# 安全设计: 只改 uperf 的 idle 场景参数 —— 触摸瞬间 uperf 自动切 touch 场景,
#           深度参数只作用于真正的空闲段, 交互性能不受影响。
# 配置:   /sdcard/Android/yc/uperf/fuyun.conf ([idle_gov] 分区)
# 白名单: /sdcard/Android/yc/uperf/idle_whitelist.txt (支持 com.xxx.* 前缀通配)

# 默认参数 (fuyun.conf [idle_gov] 分区可覆盖, 配置修改后最多一个轮询周期生效)
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
GOV_VALS="" # 进入深度空闲前的原始 idle 功率值序列 (| 分隔, 供退出时逐键还原)

# (get_fg_pkg 复用 libcommon.sh 的实现; 缓存变量与逻辑保留在本文件)
# 前台包名缓存 (避免每轮多次 dumpsys, 提升轮询效率)
FG_CACHE=""
FG_CACHE_TS=0
FG_CACHE_TTL=5

# 带 TTL 缓存的前台包名查询 (5s 内复用, 减少 dumpsys 开销)
get_fg_pkg_cached() {
    local now
    now=$(date +%s)
    if [ -n "$FG_CACHE" ] && [ $((now - FG_CACHE_TS)) -lt "$FG_CACHE_TTL" ]; then
        return 0
    fi
    FG_CACHE=$(get_fg_pkg)
    FG_CACHE_TS=$now
}

# 读取辅助调速器配置 (仅白名单键, 与 load_cfg 相同防注入策略)
# 26w34.6-B: 从 fuyun.conf 的 [idle_gov] 分区读取
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
    done <<EOF
$(section_body "$IDLE_CFG_FILE" idle_gov)
EOF
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

# 调速器白名单读入内存 (精确包名 + 前缀通配), 每轮一次
# 26w34.6-B: 从 whitelist.txt 的 [idle_gov] 分区读取
load_whitelists() {
    IDLE_WL_EXACT=$(section_body "$IDLE_WL_FILE" idle_gov | wl_rules exact)
    IDLE_WL_PREFIX=$(section_body "$IDLE_WL_FILE" idle_gov | wl_rules prefix)
}

# ============ 辅助调速器: 深度空闲压频 ============

# 屏幕状态 (与 service.sh 同款双判断, 兼容不同版本 dumpsys 输出)
is_screen_on() {
    dumpsys power 2>/dev/null | grep -qE "mWakefulness=Awake|mHoldingDisplaySuspendBlocker=true"
}

# $1: 包名; 返回 0 = 命中调速器白名单 (不压制频率)
# 规则已由 load_whitelists 读入内存 (调速器 5~10s 一轮, 逐次重读文件开销明显)
# 命中判定复用 libcommon.sh 的 wl_hit
idle_wl_hit() {
    local pkg="$1"
    [ -n "$pkg" ] || return 1
    wl_hit "$IDLE_WL_EXACT" "$IDLE_WL_PREFIX" "$pkg"
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

# 提取文件中所有 cpu.slowLimitPower 的值 (按出现顺序, | 分隔; 无该键输出空)
idle_power_vals() {
    grep -oE '"cpu\.slowLimitPower"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' "$1" 2>/dev/null |
        grep -oE '[0-9]+(\.[0-9]+)?$' | tr '\n' '|' | sed 's/|$//'
}

# 深度空闲期间用户修改过 uperf.json 时, 逐键还原 idle 功率预算
# 按"键出现顺序"对齐 (每 idle 块最多一个该键, 块序=键序), 只动该键:
#   - 备份中原有的键 → 还原为原值
#   - 备份中没有的键 (深度空闲时 patch 插入的) → 删除该行并修正前一行尾逗号
# 用户对 uperf.json 的其他修改原样保留
restore_idle_power() {
    local f="$1" bak="$2" tmp vals n
    tmp="$f.tmp"
    vals=$(idle_power_vals "$bak")
    n=0
    [ -n "$vals" ] && n=$(echo "$vals" | awk -F'|' '{print NF}')
    awk -v n="$n" -v vals="$vals" '
    BEGIN { split(vals, arr, "|"); k = 0; pend = "" }
    {
        if ($0 ~ /"cpu\.slowLimitPower"[[:space:]]*:/) {
            k++
            if (k <= n) {
                if (match($0, /"cpu\.slowLimitPower"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
                    $0 = substr($0, 1, RSTART - 1) "\"cpu.slowLimitPower\": " arr[k] substr($0, RSTART + RLENGTH)
                }
                if (pend != "") { print pend; pend = "" }
                print
                next
            }
            # 备份中无此键 (深度空闲时插入的): 删除本行, 顺带去掉前一行尾逗号
            if (pend != "") { sub(/,[[:space:]]*$/, "", pend); print pend; pend = "" }
            next
        }
        if (pend != "") print pend
        pend = $0
    }
    END { if (pend != "") print pend }
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
    # 记录原始 idle 功率值序列 (供退出时逐键还原, 用户改过 uperf.json 也能正确合并)
    GOV_VALS=$(idle_power_vals "$UPERF_JSON_BAK")
    echo "deep $pid $pkg $mt $GOV_VALS" >"$GOV_STATE_FILE"
    restart_uperf
    # 联动关核: 深度空闲期间关闭大核(可选中核), 受 fuyun.conf [corectl] 的 IDLE_OFF 约束
    [ -x "$BASEDIR/corectl.sh" ] && sh "$BASEDIR/corectl.sh" --off idle 2>/dev/null
    log "辅助调速: 进入深度空闲 $pkg (cpu<${IDLE_CPU_THD}% 持续≥${IDLE_TIMEOUT}s), idle 功率预算 ${IDLE_POWER_W}W"
    GOV_STATE=deep
    GOV_PID=$pid
    GOV_PKG=$pkg
    GOV_MTIME=$mt
    GOV_STREAK=0
    # GOV_PREV 保留: 深度状态首个巡检即可基于旧窗口检测 CPU 回升, 退出响应更快
}

# 退出深度空闲: 还原配置 → 重启 uperf
# 深度空闲期间用户若修改了 uperf.json (mtime 变化), 逐键还原 idle 功率预算,
# 保留用户的其他修改 (不再整文件覆盖, 深度参数也不会残留)
exit_deep_idle() {
    local cur_mt
    [ -f "$GOV_STATE_FILE" ] || { GOV_STATE=mild; return 0; }
    cur_mt=$(stat -c %Y "$UPERF_JSON" 2>/dev/null)
    if [ -n "$GOV_MTIME" ] && [ "$cur_mt" = "$GOV_MTIME" ]; then
        mv -f "$UPERF_JSON_BAK" "$UPERF_JSON" 2>/dev/null
    else
        if [ -f "$UPERF_JSON_BAK" ] && restore_idle_power "$UPERF_JSON" "$UPERF_JSON_BAK"; then
            log "辅助调速: 退出深度空闲, uperf.json 期间被修改 — 已自动还原 idle 功率预算, 其余修改保留 (原始配置仍留于 .idlebak)"
        else
            log "辅助调速: 退出深度空闲, uperf.json 期间被修改, 自动还原失败, 请手动检查 idle 功率 (原始配置留于 .idlebak)"
        fi
        # .idlebak 保留作为额外备份, 用户可手动恢复
    fi
    rm -f "$GOV_STATE_FILE"
    restart_uperf
    # 联动恢复核心: 退出深度空闲时交还 corectl 决策 (若息屏等其它触发仍要关核, corectl 会保持)
    [ -x "$BASEDIR/corectl.sh" ] && sh "$BASEDIR/corectl.sh" --on idle 2>/dev/null
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
            GOV_VALS=$5
        else
            rm -f "$GOV_STATE_FILE"
        fi
    fi
    log "辅助调速器启动 (IDLE_GOV=$IDLE_GOV 间隔=${IDLE_INTERVAL}s 超时=${IDLE_TIMEOUT}s 阈值=${IDLE_CPU_THD}% 功率=${IDLE_POWER_W}W)"
    while true; do
        load_idle_cfg
        load_whitelists
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

# 首次运行兜底: 配置由 setup.sh 复制模板 (或 migrate_legacy 转换), 键由默认值回退
init_defaults() {
    mkdir -p "$USER_PATH"
    # 旧版多文件配置 → fuyun.conf/whitelist.txt 迁移 (幂等, 见 libcommon.sh)
    migrate_legacy "$USER_PATH"
    [ -f "$IDLE_CFG_FILE" ] || : >"$IDLE_CFG_FILE"
    [ -f "$IDLE_WL_FILE" ] || : >"$IDLE_WL_FILE"
}


main() {
    init_defaults
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 10; done
    sleep 5
    idle_gov_loop
}
main
