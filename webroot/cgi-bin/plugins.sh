#!/system/bin/sh
# plugins.sh - 插件管理器 (WebUI)
# 用法:
#   plugins.sh?action=list                         列出全部插件
#   plugins.sh?action=enable&name=foo.sh           启用插件 (去 .disabled 后缀)
#   plugins.sh?action=disable&name=foo.sh          停用插件 (加 .disabled 后缀)
#   plugins.sh?action=delete&name=foo.sh           删除插件
#   plugins.sh?action=apply_config&name=uperf.xxx.json  应用 uperf 配置插件 (备份+重启 uperf)
#   plugins.sh?action=log&lines=50                 查看 plugin.log
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)
NAME=$(qget name)

# 插件目录 (root-only, 与 script/plugin.sh 保持一致)
PLUGIN_DIR=/data/adb/uperf/plugins
PLUGIN_LOG="$USER_PATH/plugin.log"
# 模块根目录 (webroot/cgi-bin/ → 模块根)
MODDIR="$(dirname "$(dirname "$(dirname "$(readlink -f "$0")")")")"
UPERF_BIN="$MODDIR/bin/uperf"

# 文件名白名单 (禁路径穿越): 仅字母数字 _ . - 且不以 . 开头
name_ok() {
    case "$1" in
        ""|.|..|.*) return 1 ;;
        */*) return 1 ;;
        *\\*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# 是否停用 (.*.disabled.* 后缀)
is_disabled() {
    case "$1" in
        *.disabled.sh|*.disabled.json) return 0 ;;
    esac
    return 1
}

# 是否 uperf 配置插件
is_config() {
    case "$1" in
        *uperf.*.json) return 0 ;;
    esac
    return 1
}

# 是否为 JSON 描述插件 (非配置类 .json)
is_json_plugin() {
    case "$1" in
        *.json) return 0 ;;
    esac
    return 1
}

# 应用 uperf 配置插件: 备份当前配置 → 复制 → 重启 uperf → 清 auxgov 深度状态
apply_config() {
    local src="$PLUGIN_DIR/$NAME" bak
    [ -f "$src" ] || { json_err "插件不存在: $NAME"; exit 0; }
    [ -f "$UPERF_JSON" ] && cp -f "$UPERF_JSON" "$UPERF_JSON.bak" 2>/dev/null
    cp -f "$src" "$UPERF_JSON" 2>/dev/null || { json_err "复制配置失败"; exit 0; }
    chmod 644 "$UPERF_JSON" 2>/dev/null
    # 清除辅助调速器深度空闲状态, 避免残留参数/备份干扰新配置
    rm -f "$USER_PATH/idle_gov.state" "$USER_PATH/uperf.json.idlebak" 2>/dev/null
    # 重启 uperf
    if [ -x "$UPERF_BIN" ]; then
        killall uperf 2>/dev/null
        sleep 0.5
        [ -f "$USER_PATH/uperf_log.txt" ] && mv -f "$USER_PATH/uperf_log.txt" "$USER_PATH/uperf_log.txt.bak" 2>/dev/null
        nohup "$UPERF_BIN" "$UPERF_JSON" -o "$USER_PATH/uperf_log.txt" >/dev/null 2>&1 &
        json_ok "已应用配置 $NAME (原配置已备份 .bak, uperf 已重启)"
    else
        json_err "uperf 二进制缺失, 配置已写入但未重启"
    fi
}

case "$ACTION" in
list)
    json_headers
    printf '{"ok":true,"items":['
    first=1
    # 脚本插件
    for f in "$PLUGIN_DIR"/*.sh; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        [ "$first" = "1" ] || printf ','
        printf '{"type":"script","name":"%s","enabled":%s}' "$(json_escape "$bn")" "$(is_disabled "$bn" && echo false || echo true)"
        first=0
    done
    # JSON 描述插件 (跳过停用后缀)
    for f in "$PLUGIN_DIR"/*.json; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        is_config "$bn" && continue
        [ "$first" = "1" ] || printf ','
        printf '{"type":"json","name":"%s","enabled":%s}' "$(json_escape "$bn")" "$(is_disabled "$bn" && echo false || echo true)"
        first=0
    done
    # uperf 配置插件 (特调化)
    for f in "$PLUGIN_DIR"/*uperf*.json; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        is_config "$bn" || continue
        [ "$first" = "1" ] || printf ','
        # 判断当前是否正在使用该配置
        applied=0
        [ -f "$UPERF_JSON" ] && cmp -s "$UPERF_JSON" "$f" 2>/dev/null && applied=1
        printf '{"type":"config","name":"%s","enabled":true,"applied":%s}' "$(json_escape "$bn")" "$applied"
        first=0
    done
    printf ']}\n'
    ;;
enable|disable)
    [ -n "$NAME" ] || { json_err "missing name"; exit 0; }
    name_ok "$NAME" || { json_err "invalid name"; exit 0; }
    # 只允许操作插件目录内文件
    [ -f "$PLUGIN_DIR/$NAME" ] || { json_err "插件不存在: $NAME"; exit 0; }
    bn=$(basename "$NAME")
    if [ "$ACTION" = "enable" ]; then
        is_disabled "$bn" || { json_err "插件已是启用状态"; exit 0; }
        new=$(printf '%s' "$bn" | sed 's/\.disabled\.sh$/.sh/; s/\.disabled\.json$/.json/')
        mv -f "$PLUGIN_DIR/$bn" "$PLUGIN_DIR/$new" 2>/dev/null && json_ok "已启用 $new" || json_err "启用失败"
    else
        is_disabled "$bn" && { json_err "插件已是停用状态"; exit 0; }
        new=$(printf '%s' "$bn" | sed 's/\.sh$/.disabled.sh/; s/\.json$/.disabled.json/')
        mv -f "$PLUGIN_DIR/$bn" "$PLUGIN_DIR/$new" 2>/dev/null && json_ok "已停用 $bn (改为 $new)" || json_err "停用失败"
    fi
    ;;
delete)
    [ -n "$NAME" ] || { json_err "missing name"; exit 0; }
    name_ok "$NAME" || { json_err "invalid name"; exit 0; }
    [ -f "$PLUGIN_DIR/$NAME" ] || { json_err "插件不存在: $NAME"; exit 0; }
    bn=$(basename "$NAME")
    rm -f "$PLUGIN_DIR/$bn" 2>/dev/null && json_ok "已删除 $bn" || json_err "删除失败"
    ;;
apply_config)
    [ -n "$NAME" ] || { json_err "missing name"; exit 0; }
    name_ok "$NAME" || { json_err "invalid name"; exit 0; }
    is_config "$NAME" || { json_err "仅支持应用 uperf.*.json 配置插件"; exit 0; }
    apply_config
    ;;
log)
    LINES=$(qget lines)
    [ -n "$LINES" ] || LINES=50
    echo "$LINES" | grep -qE '^[0-9]+$' || LINES=50
    json_headers
    printf '{"ok":true,"lines":['
    first=1
    if [ -f "$PLUGIN_LOG" ]; then
        tail -n "$LINES" "$PLUGIN_LOG" 2>/dev/null | while IFS= read -r line; do
            [ "$first" = "1" ] || printf ','
            esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g;s/"/\\"/g')
            printf '"%s"' "$esc"
            first=0
        done
    fi
    printf ']}\n'
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
