#!/system/bin/sh
# preset.sh - 配置预设 (一键应用 / 保存自定义)
# 用法:
#   preset.sh?action=list                          列出预设 (内置 4 档 + 自定义)
#   preset.sh?action=apply&name=balanced           应用预设 (写 fuyun.conf 对应分区 + 通知守护)
#   preset.sh?action=save&name=mycfg               把当前配置保存为自定义预设
#   preset.sh?action=delete&name=mycfg             删除自定义预设
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
NAME=$(qget name)

# 自定义预设名白名单
preset_name_ok() {
    case "$1" in
        ""|.*|*/*|*\\*|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

# 内置预设: 只改关键项, 其余保持用户现状; 应用后 touch 触发守护热加载 + 立即应用关核
apply_builtin() {
    case "$1" in
    balanced) # 均衡默认: 出厂值, 全核在线, 常规回收
        set_section_kv "$CFG" mem MODE hard
        set_section_kv "$CFG" mem PSI_THRESHOLD 30
        set_section_kv "$CFG" mem INTERVAL 300
        set_section_kv "$CFG" mem IDLE_KILL_MIN 5
        set_section_kv "$CFG" mem SWITCH_RECLAIM 1
        set_section_kv "$CFG" mem ZRAM_RECLAIM 1
        set_section_kv "$CFG" idle_gov IDLE_GOV 1
        set_section_kv "$CFG" idle_gov IDLE_POWER_W 0.8
        set_section_kv "$CFG" corectl CORECTL_ENABLE 0
        set_section_kv "$CFG" corectl BIG_OFF 0
        set_section_kv "$CFG" corectl MID_OFF 0
        set_section_kv "$CFG" corectl OFFSCREEN_OFF 0
        ;;
    power_save) # 日常省电: 关 1 大核, 息屏关核, 积极回收, 深度空闲联动
        set_section_kv "$CFG" mem MODE hard
        set_section_kv "$CFG" mem PSI_THRESHOLD 40
        set_section_kv "$CFG" mem INTERVAL 300
        set_section_kv "$CFG" mem IDLE_KILL_MIN 5
        set_section_kv "$CFG" mem SWITCH_RECLAIM 1
        set_section_kv "$CFG" mem ZRAM_RECLAIM 1
        set_section_kv "$CFG" idle_gov IDLE_GOV 1
        set_section_kv "$CFG" idle_gov IDLE_POWER_W 0.6
        set_section_kv "$CFG" corectl CORECTL_ENABLE 1
        set_section_kv "$CFG" corectl BIG_OFF 1
        set_section_kv "$CFG" corectl MID_OFF 0
        set_section_kv "$CFG" corectl OFFSCREEN_OFF 1
        set_section_kv "$CFG" corectl IDLE_OFF 1
        ;;
    game) # 游戏性能: 全核在线, 不压频, 不杀后台, 保守回收
        set_section_kv "$CFG" mem MODE soft
        set_section_kv "$CFG" mem PSI_THRESHOLD 60
        set_section_kv "$CFG" mem INTERVAL 600
        set_section_kv "$CFG" mem IDLE_KILL_MIN 0
        set_section_kv "$CFG" mem SWITCH_RECLAIM 1
        set_section_kv "$CFG" mem ZRAM_RECLAIM 0
        set_section_kv "$CFG" idle_gov IDLE_GOV 0
        set_section_kv "$CFG" corectl CORECTL_ENABLE 0
        set_section_kv "$CFG" corectl BIG_OFF 0
        set_section_kv "$CFG" corectl MID_OFF 0
        set_section_kv "$CFG" corectl OFFSCREEN_OFF 0
        ;;
    fast) # 极速: 全核在线, 零回收干预, 不压频
        set_section_kv "$CFG" mem MODE soft
        set_section_kv "$CFG" mem PSI_THRESHOLD 80
        set_section_kv "$CFG" mem INTERVAL 600
        set_section_kv "$CFG" mem IDLE_KILL_MIN 0
        set_section_kv "$CFG" mem SWITCH_RECLAIM 0
        set_section_kv "$CFG" mem ZRAM_RECLAIM 0
        set_section_kv "$CFG" mem CLEAN_CACHE_AFTER_KILL 0
        set_section_kv "$CFG" idle_gov IDLE_GOV 0
        set_section_kv "$CFG" corectl CORECTL_ENABLE 0
        set_section_kv "$CFG" corectl BIG_OFF 0
        set_section_kv "$CFG" corectl MID_OFF 0
        set_section_kv "$CFG" corectl OFFSCREEN_OFF 0
        ;;
    *) return 1 ;;
    esac
    return 0
}

# 预设名称 → 中文显示名
builtin_label() {
    case "$1" in
        balanced) echo "均衡默认" ;;
        power_save) echo "日常省电" ;;
        game) echo "游戏性能" ;;
        fast) echo "极速" ;;
    esac
}

case "$ACTION" in
list)
    json_headers
    printf '{"ok":true,"items":['
    first=1
    for p in balanced power_save game fast; do
        [ "$first" = "1" ] || printf ','
        printf '{"name":"%s","label":"%s","type":"builtin"}' "$p" "$(builtin_label "$p")"
        first=0
    done
    # 自定义预设 (presets 目录下的 .conf 快照)
    if [ -d "$PRESETS_DIR" ]; then
        for f in "$PRESETS_DIR"/*.conf; do
            [ -f "$f" ] || continue
            [ "$first" = "1" ] || printf ','
            printf '{"name":"%s","label":"自定义:%s","type":"custom"}' \
                "$(json_escape "$(basename "$f" .conf)")" "$(json_escape "$(basename "$f" .conf)")"
            first=0
        done
    fi
    printf ']}\n'
    ;;
apply)
    [ -n "$NAME" ] || { json_err "缺少预设名"; exit 0; }
    if apply_builtin "$NAME"; then
        # 立即应用核心开关 (关核热插拔)
        sh "$CORECTL_SCRIPT" apply 2>/dev/null
        # touch 触发各守护下一轮热加载
        touch "$CFG" 2>/dev/null
        json_ok "已应用预设: $(builtin_label "$NAME") (最多一个轮询周期生效)"
    else
        # 自定义预设: 整文件快照回写
        preset_name_ok "$NAME" || { json_err "无效的预设名"; exit 0; }
        [ -f "$PRESETS_DIR/$NAME.conf" ] || { json_err "预设不存在: $NAME"; exit 0; }
        cp -f "$CFG" "$CFG.bak" 2>/dev/null
        cp -f "$PRESETS_DIR/$NAME.conf" "$CFG" 2>/dev/null || { json_err "应用预设失败"; exit 0; }
        sh "$CORECTL_SCRIPT" apply 2>/dev/null
        touch "$CFG" 2>/dev/null
        json_ok "已应用自定义预设: $NAME (原配置已备份 .bak)"
    fi
    ;;
save)
    [ -n "$NAME" ] || { json_err "缺少预设名"; exit 0; }
    preset_name_ok "$NAME" || { json_err "预设名仅允许字母数字 _ -"; exit 0; }
    mkdir -p "$PRESETS_DIR" 2>/dev/null
    cp -f "$CFG" "$PRESETS_DIR/$NAME.conf" 2>/dev/null || { json_err "保存失败"; exit 0; }
    chmod 600 "$PRESETS_DIR/$NAME.conf" 2>/dev/null
    json_ok "已保存自定义预设: $NAME (含 mem/idle_gov/corectl 全部设置)"
    ;;
delete)
    [ -n "$NAME" ] || { json_err "缺少预设名"; exit 0; }
    preset_name_ok "$NAME" || { json_err "无效的预设名"; exit 0; }
    rm -f "$PRESETS_DIR/$NAME.conf" 2>/dev/null
    json_ok "已删除预设: $NAME"
    ;;
*)
    json_err "未知操作: $ACTION"
    ;;
esac
