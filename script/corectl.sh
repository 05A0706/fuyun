#!/system/bin/sh
#
# corectl.sh - fuyun CPU 核心开关 (热插拔)
#
# 作用: 按用户配置关闭大核/中核以降低功耗, 把"省电主杠杆"从"压频率"改为"关核心"。
#       - 常态: 用户配置关 N 颗大核 / N 颗中核 (BIG_OFF / MID_OFF)
#       - 深度空闲 (辅助调速器 auxgov.sh 联动): 额外把大核压到仅剩 1 颗
#       - 息屏 (可选, 用户开启 OFFSCREEN_OFF): 额外把大核压到仅剩 1 颗
# 安全约束 (必守):
#   - 绝不 offline cpu0 (cluster_cpus / all_hotplug_cpus 均把 cpu0 剔除)
#   - 小核簇永不参与关核 (KEEP_LITTLE 强制) —— 这是"大/中核可整簇关闭"的安全前提:
#     系统始终保有一整簇在线算力, 不会出现整机无核可用
#   - 大/中核允许整簇关闭 (关核数上限 = 该簇总数), 与内核热插拔/温控行为一致
#   - uperf 跑在 background cpuset (小核), 关大/中核不会把它钉死; 卸载/clear 一键全恢复
#
# 配置: /sdcard/Android/yc/uperf/fuyun.conf ([corectl] 分区)
# 日志: /sdcard/Android/yc/uperf/mem_log.txt (前缀 "核心开关:")
#
# 用法:
#   corectl.sh watch       守护循环 (默认)
#   corectl.sh apply       按当前配置应用一次
#   corectl.sh clear       恢复全部核心在线 (兜底)
#   corectl.sh --off <idle|screen>   叠加一层关核原因 (供 auxgov / 息屏调用)
#   corectl.sh --on  <idle|screen>   撤掉一层关核原因
#   corectl.sh status      输出核心开关状态 (key=value, 供 WebUI/status 读取)

USER_PATH=/sdcard/Android/yc/uperf
# 26w34.6-B 第四轮: 配置合并 → fuyun.conf [corectl] 分区
CFG="$USER_PATH/fuyun.conf"
STATE_FILE="$USER_PATH/corectl.state"
OVERLAY_FILE="$USER_PATH/corectl.overlay"
LOG="$USER_PATH/corectl.log.txt"

# ---------- 日志 (F8: 独立日志文件 + 轮转, 不再写入 mem_log.txt) ----------
# 公共工具库 (rotate_log 等)
BASEDIR="$(dirname "$(readlink -f "$0")")"
[ -f "$BASEDIR/libcommon.sh" ] && . "$BASEDIR/libcommon.sh"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 核心开关: $*" >>"$LOG"
    rotate_log "$LOG"
}

# ---------- 屏幕状态 (与 service.sh 同款双判断) ----------
screen_on() {
    dumpsys power 2>/dev/null | grep -qE "mWakefulness=Awake|mHoldingDisplaySuspendBlocker=true"
}

# ---------- 叠加层 (idle/screen 触发源) ----------
# 叠加层存于 OVERLAY_FILE (每行一个原因), 跨进程共享 (auxgov 与 watch 都用)
overlay_add() {
    local r="$1"
    [ -f "$OVERLAY_FILE" ] || : >"$OVERLAY_FILE"
    grep -qx "$r" "$OVERLAY_FILE" 2>/dev/null && return 0
    echo "$r" >>"$OVERLAY_FILE"
}
overlay_del() {
    [ -f "$OVERLAY_FILE" ] || return 0
    grep -vx "$1" "$OVERLAY_FILE" >"$OVERLAY_FILE.tmp" 2>/dev/null
    mv -f "$OVERLAY_FILE.tmp" "$OVERLAY_FILE"
    [ -s "$OVERLAY_FILE" ] || rm -f "$OVERLAY_FILE"
}
overlay_has() {
    [ -f "$OVERLAY_FILE" ] || return 1
    grep -qx "$1" "$OVERLAY_FILE" 2>/dev/null
}

# ---------- cpufreq policy / cluster 识别 ----------
cpufreq_policies() {
    ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null
}

# $1: policy 路径; 输出 little|mid|big|unknown
cluster_of_policy() {
    local p="$1" rel maxf count mincpu maxcpu cpus a b i c bestf f
    rel=$(cat "$p/related_cpus" 2>/dev/null)
    [ -n "$rel" ] || rel=$(cat "$p/affected_cpus" 2>/dev/null)
    [ -n "$rel" ] || { echo "unknown"; return; }
    cpus=""
    for c in $rel; do
        case "$c" in
            *-*)
                a=${c%-*}; b=${c#*-}; i=$a
                while [ "$i" -le "$b" ] 2>/dev/null; do
                    cpus="$cpus $i"; i=$((i + 1))
                done
                ;;
            *)
                case "$c" in ''|*[!0-9]*) ;; *) cpus="$cpus $c" ;; esac
                ;;
        esac
    done
    count=0; mincpu=999; maxcpu=0
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
    # 大核: 单核且是全局最高频
    if [ "$count" -eq 1 ] && [ "$maxf" -ge "$bestf" ] 2>/dev/null; then
        echo "big"; return
    fi
    # 小核: 包含 cpu0
    if [ "$mincpu" = "0" ]; then
        echo "little"; return
    fi
    echo "mid"
}

# $1: little|mid|big; 输出该簇可热插拔的 cpu 列表 (升序, 已排除 cpu0)
policy_cpus() {
    local p="$1" rel a b i c out=""
    rel=$(cat "$p/related_cpus" 2>/dev/null)
    [ -n "$rel" ] || rel=$(cat "$p/affected_cpus" 2>/dev/null)
    [ -n "$rel" ] || return 0
    for c in $rel; do
        case "$c" in
            *-*)
                a=${c%-*}; b=${c#*-}; i=$a
                while [ "$i" -le "$b" ] 2>/dev/null; do
                    out="$out $i"; i=$((i + 1))
                done
                ;;
            *)
                case "$c" in ''|*[!0-9]*) ;; *) out="$out $c" ;; esac
                ;;
        esac
    done
    echo $out
}

cluster_cpus() {
    local want="$1" p cpus c cl out=""
    for p in $(cpufreq_policies); do
        cl=$(cluster_of_policy "$p")
        [ "$cl" = "$want" ] || continue
        cpus=$(policy_cpus "$p")
        for c in $cpus; do
            [ "$c" = "0" ] && continue
            case " $out " in *" $c "*) ;; *) out="$out $c" ;; esac
        done
    done
    echo $out | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' '
}

# 全部可热插拔核 (升序, 已排除 cpu0)
all_hotplug_cpus() {
    local d c out=""
    for d in /sys/devices/system/cpu/cpu[0-9]*; do
        c=${d##*/cpu}
        case "$c" in ''|*[!0-9]*) continue ;; esac
        [ "$c" = "0" ] && continue
        [ -f "$d/online" ] || continue
        out="$out $c"
    done
    echo $out | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' '
}

cpu_count() {
    echo "$1" | tr ' ' '\n' | grep -v '^$' | grep -c .
}

# ---------- 配置读取 ----------
# 26w34.6-B: 从 fuyun.conf 的 [corectl] 分区读取
load_cfg() {
    CORECTL_ENABLE=0
    OFFSCREEN_OFF=0
    IDLE_OFF=1
    BIG_OFF=0
    MID_OFF=0
    KEEP_LITTLE=1
    [ -f "$CFG" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        [ -n "$v" ] || continue
        case "$k" in
            CORECTL_ENABLE) CORECTL_ENABLE=$v ;;
            OFFSCREEN_OFF)  OFFSCREEN_OFF=$v ;;
            IDLE_OFF)       IDLE_OFF=$v ;;
            BIG_OFF)        BIG_OFF=$v ;;
            MID_OFF)        MID_OFF=$v ;;
            KEEP_LITTLE)    KEEP_LITTLE=$v ;;
        esac
    done <<EOF
$(section_body "$CFG" corectl)
EOF
    case "$CORECTL_ENABLE" in 0|1) ;; *) CORECTL_ENABLE=0 ;; esac
    case "$OFFSCREEN_OFF"  in 0|1) ;; *) OFFSCREEN_OFF=0 ;; esac
    case "$IDLE_OFF"       in 0|1) ;; *) IDLE_OFF=1 ;; esac
    case "$KEEP_LITTLE"    in 0|1) ;; *) KEEP_LITTLE=1 ;; esac
    case "$BIG_OFF" in ''|*[!0-9]*) BIG_OFF=0 ;; esac
    case "$MID_OFF" in ''|*[!0-9]*) MID_OFF=0 ;; esac
}

# ---------- 计算目标 offline 集合 (空格分隔 cpu 列表) ----------
compute_target() {
    local big_list mid_list nbig nmid big_off mid_off pull t
    big_list=$(cluster_cpus big)
    mid_list=$(cluster_cpus mid)
    nbig=$(cpu_count "$big_list")
    nmid=$(cpu_count "$mid_list")
    # 安全约束 (逐条对应文件头说明):
    #   - cpu0 永不 offline —— cluster_cpus() / all_hotplug_cpus() 已把 cpu0 剔除
    #   - 小核簇永不参与关核 (KEEP_LITTLE) —— 保证系统始终保有一整簇在线算力,
    #     因此"关掉全部大/中核"是安全的, 不会出现整机无核可用的情况
    #   - 大/中核允许整簇关闭 (关核数上限 = 该簇总数), 与内核热插拔/温控行为一致;
    #     若按"每簇至少留 1 核"的保守约束, 8+ Gen1 / 8 Gen2 的大核簇通常只有 cpu7
    #     一颗, 关大核将永远无法生效, 本功能会形同虚设。

    big_off=$BIG_OFF; mid_off=$MID_OFF
    case "$big_off" in ''|*[!0-9]*) big_off=0 ;; esac
    case "$mid_off" in ''|*[!0-9]*) mid_off=0 ;; esac
    # 上限 = 簇总数 (允许整簇关闭); 用 -gt 而非 -ge, 保证 big_off==nbig 合法
    [ "$big_off" -gt "$nbig" ] 2>/dev/null && big_off=$nbig
    [ "$big_off" -lt 0 ] 2>/dev/null && big_off=0
    [ "$mid_off" -gt "$nmid" ] 2>/dev/null && mid_off=$nmid
    [ "$mid_off" -lt 0 ] 2>/dev/null && mid_off=0

    # 叠加层: 深度空闲(auxgov 联动)或息屏, 额外关闭全部大核
    # (中核维持基线不动 —— 大核是功耗大头, 留着中核保住唤醒/亮屏时的响应)
    pull=0
    overlay_has idle   && [ "$IDLE_OFF" = "1" ]       && pull=1
    overlay_has screen && [ "$OFFSCREEN_OFF" = "1" ]  && pull=1
    if [ "$pull" = "1" ] && [ "$nbig" -gt 0 ]; then
        big_off=$nbig
    fi

    # 取各簇最高序号的 N 颗核 offline
    t=""
    [ "$big_off" -gt 0 ] 2>/dev/null && \
        t="$t $(echo "$big_list" | tr ' ' '\n' | grep -v '^$' | sort -rn | head -n "$big_off" | tr '\n' ' ')"
    [ "$mid_off" -gt 0 ] 2>/dev/null && \
        t="$t $(echo "$mid_list" | tr ' ' '\n' | grep -v '^$' | sort -rn | head -n "$mid_off" | tr '\n' ' ')"
    echo $t | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' '
}

# ---------- 应用 ----------
apply() {
    local target t cpu online
    load_cfg
    if [ "$CORECTL_ENABLE" != "1" ]; then
        # 总开关关闭: 全部在线, 清叠加层与状态
        for cpu in $(all_hotplug_cpus); do
            online=$(cat /sys/devices/system/cpu/cpu$cpu/online 2>/dev/null)
            [ "$online" = "1" ] && continue
            echo 1 >/sys/devices/system/cpu/cpu$cpu/online 2>/dev/null
        done
        rm -f "$OVERLAY_FILE" "$STATE_FILE"
        return 0
    fi
    target=$(compute_target)
    # offline 目标集合中的核
    for cpu in $target; do
        online=$(cat /sys/devices/system/cpu/cpu$cpu/online 2>/dev/null)
        [ "$online" = "0" ] && continue
        if echo 0 >/sys/devices/system/cpu/cpu$cpu/online 2>/dev/null; then
            log "offline cpu$cpu"
        fi
    done
    # 其余可热插拔核: 若曾 offline 但已不在目标, 恢复 online
    for cpu in $(all_hotplug_cpus); do
        case " $target " in *" $cpu "*) continue ;; esac
        online=$(cat /sys/devices/system/cpu/cpu$cpu/online 2>/dev/null)
        [ "$online" = "1" ] && continue
        if echo 1 >/sys/devices/system/cpu/cpu$cpu/online 2>/dev/null; then
            log "online cpu$cpu"
        fi
    done
    echo "$target" >"$STATE_FILE"
}

clear_all() {
    local cpu
    for cpu in $(all_hotplug_cpus); do
        echo 1 >/sys/devices/system/cpu/cpu$cpu/online 2>/dev/null
    done
    rm -f "$OVERLAY_FILE" "$STATE_FILE"
    log "已恢复全部核心在线"
}

# ---------- 状态输出 (供 WebUI / status.sh) ----------
cmd_status() {
    local big_list mid_list lit_list nbig nmid nlit
    local obig omid olit t cpu online
    load_cfg
    big_list=$(cluster_cpus big);  nbig=$(cpu_count "$big_list")
    mid_list=$(cluster_cpus mid);  nmid=$(cpu_count "$mid_list")
    lit_list=$(cluster_cpus little); nlit=$(cpu_count "$lit_list")
    obig=0; omid=0; olit=0
    for cpu in $big_list; do
        online=$(cat /sys/devices/system/cpu/cpu$cpu/online 2>/dev/null)
        [ "$online" = "1" ] || obig=$((obig + 1))
    done
    for cpu in $mid_list; do
        online=$(cat /sys/devices/system/cpu/cpu$cpu/online 2>/dev/null)
        [ "$online" = "1" ] || omid=$((omid + 1))
    done
    for cpu in $lit_list; do
        online=$(cat /sys/devices/system/cpu/cpu$cpu/online 2>/dev/null)
        [ "$online" = "1" ] || olit=$((olit + 1))
    done
    t=$(compute_target)
    echo "ENABLE=$CORECTL_ENABLE"
    echo "OFFSCREEN_OFF=$OFFSCREEN_OFF"
    echo "IDLE_OFF=$IDLE_OFF"
    echo "BIG_OFF=$BIG_OFF"
    echo "MID_OFF=$MID_OFF"
    echo "KEEP_LITTLE=$KEEP_LITTLE"
    echo "BIG_TOTAL=$nbig"
    echo "MID_TOTAL=$nmid"
    echo "LITTLE_TOTAL=$nlit"
    echo "ONLINE_BIG=$obig"
    echo "ONLINE_MID=$omid"
    echo "ONLINE_LITTLE=$olit"
    echo "OVERLAY_IDLE=$(overlay_has idle && echo 1 || echo 0)"
    echo "OVERLAY_SCREEN=$(overlay_has screen && echo 1 || echo 0)"
    echo "OFFLINE_LIST=$t"
}

# ---------- 守护循环 ----------
watch_loop() {
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 5
    done
    # /sdcard 需用户解锁后才可写
    local tf=/sdcard/Android/.PERMISSION_TEST
    : >"$tf" 2>/dev/null
    until [ -f "$tf" ]; do
        : >"$tf" 2>/dev/null
        sleep 2
    done
    rm -f "$tf"

    init_defaults
    while true; do
        load_cfg
        if [ "$CORECTL_ENABLE" = "1" ] && [ "$OFFSCREEN_OFF" = "1" ]; then
            if screen_on; then
                overlay_del screen; apply
                sleep 30
            else
                overlay_add screen; apply
                # 息屏期间改为 5s 巡检: 亮屏后要尽快把核心拉回来,
                # 否则"刚亮屏却只跑小核"的卡顿是可以直接感知的
                sleep 5
            fi
        else
            overlay_del screen; apply
            sleep 30
        fi
    done
}

# ---------- 首次运行兜底: 配置由 setup.sh 复制模板 (或 migrate_legacy 转换), 键由默认值回退 ----------
init_defaults() {
    mkdir -p "$USER_PATH"
    # 旧版多文件配置 → fuyun.conf/whitelist.txt 迁移 (幂等, 见 libcommon.sh)
    migrate_legacy "$USER_PATH"
    [ -f "$CFG" ] || : >"$CFG"
}

case "$1" in
    watch)  watch_loop ;;
    apply)  init_defaults; apply ;;
    clear)  clear_all ;;
    status) cmd_status ;;
    --off)  r="$2"; case "$r" in idle|screen) overlay_add "$r"; load_cfg; apply ;; *) ;; esac ;;
    --on)   r="$2"; case "$r" in idle|screen) overlay_del "$r"; load_cfg; apply ;; *) ;; esac ;;
    *)      watch_loop ;;
esac
