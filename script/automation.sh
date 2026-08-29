#!/system/bin/sh
#
# automation.sh - fuyun 场景自动化规则引擎 (F2)
#
# 与 perapp(按前台应用) 维度互补: 按 充电状态 / 电量 / 时段 / 屏幕 触发策略。
#
# 规则文件: /sdcard/Android/yc/uperf/automation.txt
# 每行格式: <触发条件> => <动作>   (# 开头注释, 重启保留)
#   触发条件:
#     charging          正在充电
#     discharging       未充电
#     battery<20        电量低于 20%
#     battery>80        电量高于 80%
#     screen_on         屏幕亮
#     screen_off        屏幕灭
#     time 23:00-07:00  时段 (支持跨午夜, 如 23:00-07:00)
#   动作:
#     mode powersave|balance|performance|fast   切换性能模式
#     bigoff N          关大核数 (0=不关)
#     midoff N          关中核数 (0=不关)
# 多条规则按出现顺序求值, 同类型动作以"最后匹配"为准。
#
# 安全: 仅写 cur_powermode.txt / fuyun.conf [corectl] 并调用既有入口, 不引入新攻击面。

USER_PATH=/sdcard/Android/yc/uperf
AUTOMATION_FILE="$USER_PATH/automation.txt"
POWERMODE_FILE="$USER_PATH/cur_powermode.txt"
# 26w34.6-B: 核心开关配置合并进 fuyun.conf [corectl] 分区
CORECTL_CFG="$USER_PATH/fuyun.conf"
MODDIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
CORECTL_SCRIPT="$MODDIR/script/corectl.sh"
POWERCFG=/data/powercfg.sh

# 公共工具库 (rotate_log 等)
[ -f "$MODDIR/script/libcommon.sh" ] && . "$MODDIR/script/libcommon.sh"

log() {
    echo "[$(date '+%m-%d %H:%M:%S')] 自动化: $*" >>"$USER_PATH/automation.log.txt"
    rotate_log "$USER_PATH/automation.log.txt"
}

battery_level() {
    dumpsys battery 2>/dev/null | grep -i 'level' | head -n 1 | grep -oE '[0-9]+'
}
is_charging() {
    dumpsys battery 2>/dev/null | grep -iE 'AC powered: true|USB powered: true|Wireless powered: true|status: 2' | grep -qiE 'true|2'
}
screen_on() {
    dumpsys power 2>/dev/null | grep -qE 'mWakefulness=Awake|mHoldingDisplaySuspendBlocker=true'
}
now_minutes() {
    date +%H:%M | awk -F: '{print $1*60+$2}'
}

# 时间区间匹配 (支持跨午夜)
time_in_range() {
    local r="$1" now ta tb a b
    a=$(echo "$r" | cut -d- -f1 | tr -d ' ')
    b=$(echo "$r" | cut -d- -f2 | tr -d ' ')
    now=$(now_minutes)
    ta=$(echo "$a" | awk -F: '{print $1*60+$2}')
    tb=$(echo "$b" | awk -F: '{print $1*60+$2}')
    if [ "$ta" -le "$tb" ]; then
        [ "$now" -ge "$ta" ] && [ "$now" -lt "$tb" ]
    else
        [ "$now" -ge "$ta" ] || [ "$now" -lt "$tb" ]
    fi
}

trigger_match() {
    local t="$1" lvl
    case "$t" in
        charging)    is_charging ;;
        discharging) ! is_charging ;;
        screen_on)   screen_on ;;
        screen_off)  ! screen_on ;;
        battery\<*)  lvl=$(battery_level); [ -n "$lvl" ] && [ "$lvl" -lt "${t#battery<}" ] 2>/dev/null ;;
        battery\>*)  lvl=$(battery_level); [ -n "$lvl" ] && [ "$lvl" -gt "${t#battery>}" ] 2>/dev/null ;;
        time\ *)     time_in_range "${t#time }" ;;
        *)           return 1 ;;
    esac
}

apply_mode() {
    local m="$1" cur
    [ -f "$POWERMODE_FILE" ] && cur=$(cat "$POWERMODE_FILE" 2>/dev/null)
    [ "$cur" = "$m" ] && return 0
    echo "$m" >"$POWERMODE_FILE" 2>/dev/null
    [ -f "$POWERCFG" ] && sh "$POWERCFG" "$m" 2>/dev/null
    log "切换性能模式 -> $m"
}

# 写 fuyun.conf [corectl] 分区键 (复用 libcommon 的 set_section_kv, 保留注释与其余键)
set_corectl_key() {
    set_section_kv "$CORECTL_CFG" corectl "$1" "$2"
}

apply_corectl() {
    local big="$1" mid="$2" changed=0 cur
    if [ -n "$big" ]; then
        cur=$(get_section_kv "$CORECTL_CFG" corectl BIG_OFF)
        [ "$cur" != "$big" ] && { set_corectl_key BIG_OFF "$big"; changed=1; }
    fi
    if [ -n "$mid" ]; then
        cur=$(get_section_kv "$CORECTL_CFG" corectl MID_OFF)
        [ "$cur" != "$mid" ] && { set_corectl_key MID_OFF "$mid"; changed=1; }
    fi
    [ "$changed" = "1" ] && { sh "$CORECTL_SCRIPT" apply 2>/dev/null; log "调整关核 BIG_OFF=$big MID_OFF=$mid"; }
}

eval_rules() {
    [ -f "$AUTOMATION_FILE" ] || return 0
    local desired_mode="" big="" mid="" line trg act
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        trg=$(printf '%s' "$line" | sed 's/=>.*//' | xargs)
        act=$(printf '%s' "$line" | sed 's/.*=>//' | xargs)
        [ -n "$trg" ] && [ -n "$act" ] || continue
        trigger_match "$trg" || continue
        case "$act" in
            mode\ *)   desired_mode=$(echo "$act" | awk '{print $2}') ;;
            bigoff\ *) big=$(echo "$act" | awk '{print $2}') ;;
            midoff\ *) mid=$(echo "$act" | awk '{print $2}') ;;
        esac
    done <"$AUTOMATION_FILE"
    case "$desired_mode" in
        powersave|balance|performance|fast) apply_mode "$desired_mode" ;;
    esac
    apply_corectl "$big" "$mid"
}

init_defaults() {
    mkdir -p "$USER_PATH"
    if [ ! -f "$AUTOMATION_FILE" ]; then
        cat >"$AUTOMATION_FILE" <<'EOF'
# fuyun 场景自动化规则 (F2)
# 每行: <触发条件> => <动作>   (# 开头为注释, 重启保留)
# 触发条件:
#   charging      正在充电
#   discharging   未充电
#   battery<20    电量低于 20%
#   battery>80    电量高于 80%
#   screen_on     屏幕亮
#   screen_off    屏幕灭
#   time 23:00-07:00   时段 (支持跨午夜)
# 动作:
#   mode powersave|balance|performance|fast   切换性能模式
#   bigoff N       关大核数 (0=不关)
#   midoff N       关中核数 (0=不关)
# 多条规则按序求值, 同类型动作以"最后匹配"为准。
#
# 示例 (取消注释生效):
# charging => mode performance
# battery<20 => mode powersave
# screen_off => bigoff 1
# time 23:00-07:00 => mode powersave
EOF
    fi
}

main() {
    init_defaults
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 10; done
    sleep 5
    log "自动化守护启动"
    while true; do
        eval_rules
        sleep 30
    done
}
main
