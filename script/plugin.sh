#!/system/bin/sh
#
# plugin.sh - fuyun 第三方插件接口
#
# 安全变更 (F6): 插件目录由共享存储 /sdcard/.../plugins 迁至 root-only 的
#   /data/adb/uperf/plugins
# 原因: 共享存储下任何有存储权限的 App 放入 .sh / {"command":...} 即可在
#       boot/apply 阶段获得 root 命令执行 (写个文件即 root)。迁移后目录仅 root 可写,
#       消除"共享存储写文件即 root 执行"的攻击链。
#
# 第三方插件放在:
#   /data/adb/uperf/plugins/
#   - *.sh   传统 shell 插件
#   - *.json JSON 描述插件 (仅支持 file 字段指向本目录内脚本, 取消 command 直通 sh -c)
#
# JSON 插件格式 (F6: 只允许 file, 且必须位于插件目录内):
# {
#   "name": "example",
#   "enabled": true,
#   "stages": ["apply", "clear", "boot"],
#   "file": "/data/adb/uperf/plugins/example_plugin.sh"
# }
#
# 接口约定:
#   - 由本模块以独立子进程方式调用, 插件内可自由写日志到 stdout/stderr,
#     输出会追加到 /sdcard/Android/yc/uperf/plugin.log。
#   - 当前阶段 stage:
#       apply  频率控制已应用后
#       clear  频率控制已清除后
#       boot   模块开机服务就绪后
#   - 插件失败不会影响模块主功能, 返回码仅记录日志。
#
# 环境变量:
#   FUYUN_STAGE        当前阶段 (apply/clear/boot)
#   FUYUN_SOC          sdm8g2 / sdm8+ / unsupported
#   FUYUN_MODULE_DIR   模块安装目录
#   FUYUN_USER_PATH    用户配置目录
#   FUYUN_PLUGIN_DIR   插件目录

USER_PATH="${USER_PATH:-/sdcard/Android/yc/uperf}"
# F6: 插件目录迁至 root-only, 仅 root 可写 (杜绝共享存储写文件即 root 执行)
PLUGIN_DIR="/data/adb/uperf/plugins"
PLUGIN_LOG="$USER_PATH/plugin.log"
MODDIR="${MODDIR:-$(dirname "$(dirname "$(readlink -f "$0")")")}"

# 插件启用状态: 文件名带 .disabled 后缀 = 停用 (WebUI 插件管理器通过改名切换)
#   foo.sh         → 启用
#   foo.disabled.sh → 停用 (run_plugins 跳过)
#   uperf.*.json   → uperf 配置插件 (特调化, 仅由 WebUI "应用配置" 显式加载, 不自动执行)
plugin_disabled() {
    case "$1" in
        *.disabled.sh|*.disabled.json) return 0 ;;
    esac
    return 1
}

# 是否 uperf 配置插件 (uperf.<名称>.json, 非 JSON 描述插件)
plugin_is_config() {
    case "$1" in
        *uperf.*.json) return 0 ;;
    esac
    return 1
}

plugin_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$PLUGIN_LOG" 2>/dev/null
    local sz
    sz=$(stat -c %s "$PLUGIN_LOG" 2>/dev/null)
    [ "${sz:-0}" -gt 1048576 ] 2>/dev/null && { mv -f "$PLUGIN_LOG" "$PLUGIN_LOG.old"; : >"$PLUGIN_LOG"; }
}

# F6: 校验脚本路径是否位于插件目录内且非他人可写 (防止 .. 逃逸 / 提权)
plugin_path_ok() {
    local f="$1" real
    case "$f" in
        "$PLUGIN_DIR/"*) ;;
        *) plugin_log "拒绝: 脚本不在插件目录内: $f"; return 1 ;;
    esac
    real=$(readlink -f "$f" 2>/dev/null)
    case "$real" in
        "$PLUGIN_DIR/"*) ;;
        *) plugin_log "拒绝: 脚本经符号链接逃逸插件目录: $f"; return 1 ;;
    esac
    # 拒绝组/其他可写 (避免被低权限进程篡改后借 root 执行)
    perms=$(stat -c %a "$f" 2>/dev/null)
    case "$perms" in
        [0-7][0-7][0-7])
            oth=${perms#??}
            case "$oth" in
                *[2367]) plugin_log "拒绝: 脚本对他人可写 ($perms): $f"; return 1 ;;
            esac
            ;;
    esac
    return 0
}

# 首次创建插件目录与说明文件
init_plugin_dir() {
    mkdir -p "$PLUGIN_DIR" 2>/dev/null
    chmod 700 "$PLUGIN_DIR" 2>/dev/null
    chown root:root "$PLUGIN_DIR" 2>/dev/null
    # F6: 旧共享存储插件目录迁移提示 (不自动搬运, 避免带入未知脚本)
    local old_dir="$USER_PATH/plugins"
    if [ -d "$old_dir" ] && [ -n "$(ls -A "$old_dir" 2>/dev/null)" ]; then
        plugin_log "发现旧插件目录 $old_dir, 新目录已改为 root-only $PLUGIN_DIR; 请人工确认后迁移, 旧目录不再自动加载"
    fi
    # 内置示例插件: 首次放入插件目录 (默认停用 .disabled, 由 WebUI/终端启用)
    local example="$MODDIR/plugin_examples/example_plugin.sh"
    if [ -f "$example" ] && [ ! -e "$PLUGIN_DIR/example_plugin.sh" ] && [ ! -e "$PLUGIN_DIR/example_plugin.sh.disabled" ]; then
        cp -f "$example" "$PLUGIN_DIR/example_plugin.sh.disabled" 2>/dev/null
        chmod 700 "$PLUGIN_DIR/example_plugin.sh.disabled" 2>/dev/null
        chown root:root "$PLUGIN_DIR/example_plugin.sh.disabled" 2>/dev/null
        plugin_log "已放入内置示例插件 (默认停用): $PLUGIN_DIR/example_plugin.sh.disabled"
    fi
    if [ ! -f "$PLUGIN_DIR/README.txt" ]; then
        cat >"$PLUGIN_DIR/README.txt" <<'EOF'
fuyun 第三方插件目录 (root-only)
=================================

安全说明 (F6): 本目录位于 /data/adb/uperf/plugins, 仅 root 可写。
旧版位于共享存储 /sdcard/Android/yc/uperf/plugins, 任何有存储权限的 App
放入脚本即可借本模块获得 root 执行, 已弃用。请只把可信脚本放到本目录。

支持三种插件:

1. Shell 插件 (*.sh)
   直接放到本目录即可, 模块按阶段调用:
     sh <plugin>.sh <stage>

2. JSON 描述插件 (*.json, 非 uperf.*.json)
   直接放到本目录即可自动导入。仅支持 file 字段, 且必须指向本目录内脚本
   (不再支持 command 直通 sh -c, 那是高危的"写 JSON 即 root 执行"入口):
   {
     "name": "example",
     "enabled": true,
     "stages": ["apply", "clear", "boot"],
     "file": "/data/adb/uperf/plugins/example_plugin.sh"
   }

3. uperf 配置插件 (uperf.<名称>.json) —— 特调化
   把 uperf 配置放到本目录并命名为 uperf.<名称>.json (如 uperf.sdm8e.json),
   即可在 WebUI「管理 → 插件」里一键"应用此配置" (自动备份当前配置并重启 uperf)。
   可放多套配置互相切换, 适合分享特调。

停用插件: 文件名加 .disabled 后缀 (foo.sh → foo.disabled.sh), 模块会自动跳过;
WebUI 插件管理器可一键启用/停用/删除。

可用阶段:
  apply   频率控制已应用后
  clear   频率控制已清除后
  boot    模块开机服务就绪后

可用环境变量:
  FUYUN_STAGE         当前阶段
  FUYUN_SOC           当前 SoC 配置名
  FUYUN_MODULE_DIR    模块目录
  FUYUN_USER_PATH     用户配置目录
  FUYUN_PLUGIN_DIR    本插件目录

插件输出会写入 plugin.log, 插件失败不影响模块主功能。
EOF
        chmod 600 "$PLUGIN_DIR/README.txt" 2>/dev/null
    fi
}

# 当前 SoC 配置名 (兼容 libsysinfo)
plugin_soc_name() {
    if type get_config_name >/dev/null 2>&1; then
        get_config_name "$(getprop ro.board.platform)" 2>/dev/null
    else
        getprop ro.board.platform 2>/dev/null
    fi
}

# 运行一个 JSON 描述插件
# $1: json 文件  $2: stage, 其余参数透传
run_json_plugin() {
    local file="$1" stage="$2"
    [ -n "$stage" ] || return 0
    shift 2
    local content enabled name stages_json script_file rc
    content=$(tr -d '\n\r' <"$file" 2>/dev/null)
    [ -n "$content" ] || return 0
    enabled=$(echo "$content" | sed -n 's/.*"enabled"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -n 1)
    [ -z "$enabled" ] && enabled=true
    [ "$enabled" = "true" ] || return 0
    name=$(echo "$content" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"\\]*\(\\.[^"\\]*\)*\)".*/\1/p' | head -n 1 | sed 's/\\"/"/g; s/\\\\/\\/g')
    stages_json=$(echo "$content" | sed -n 's/.*"stages"[[:space:]]*:[[:space:]]*\(\[[^]]*\]\).*/\1/p' | head -n 1)
    if [ -n "$stages_json" ]; then
        echo "$stages_json" | grep -q "\"$stage\"" || return 0
    fi
    # F6: 不再解析 command 字段 (高危直通 sh -c); 仅允许 file 且须通过准入校验
    script_file=$(echo "$content" | sed -n 's/.*"file"[[:space:]]*:[[:space:]]*"\([^"\\]*\(\\.[^"\\]*\)*\)".*/\1/p' | head -n 1 | sed 's/\\"/"/g; s/\\\\/\\/g')
    if echo "$content" | grep -q '"command"'; then
        plugin_log "skip-json $stage ${name:-$(basename "$file")} 拒绝 command 字段 (F6 已禁用)"
        return 0
    fi
    if [ -n "$script_file" ]; then
        if [ -f "$script_file" ] && plugin_path_ok "$script_file"; then
            plugin_log "run-json $stage ${name:-$(basename "$file")} (file $script_file)"
            if command -v timeout >/dev/null 2>&1; then
                FUYUN_STAGE="$stage" \
                FUYUN_SOC="$(plugin_soc_name)" \
                FUYUN_MODULE_DIR="$MODDIR" \
                FUYUN_USER_PATH="$USER_PATH" \
                FUYUN_PLUGIN_DIR="$PLUGIN_DIR" \
                timeout 5 sh "$script_file" "$@" >>"$PLUGIN_LOG" 2>&1
            else
                FUYUN_STAGE="$stage" \
                FUYUN_SOC="$(plugin_soc_name)" \
                FUYUN_MODULE_DIR="$MODDIR" \
                FUYUN_USER_PATH="$USER_PATH" \
                FUYUN_PLUGIN_DIR="$PLUGIN_DIR" \
                sh "$script_file" "$@" >>"$PLUGIN_LOG" 2>&1
            fi
            rc=$?
            plugin_log "done-json $stage ${name:-$(basename "$file")} rc=$rc"
        else
            plugin_log "skip-json $stage ${name:-$(basename "$file")} 拒绝 file (不存在或准入失败): $script_file"
        fi
    else
        plugin_log "skip-json $stage ${name:-$(basename "$file")} no valid file"
    fi
}

# $1: stage, 其余参数透传给插件
run_plugins() {
    local stage="$1"
    [ -n "$stage" ] || return 0
    init_plugin_dir
    [ -d "$PLUGIN_DIR" ] || return 0
    shift
    local plugin rc
    for plugin in "$PLUGIN_DIR"/*.sh; do
        [ -f "$plugin" ] || continue
        # 跳过停用插件 (*.disabled.sh)
        plugin_disabled "$plugin" && continue
        plugin_path_ok "$plugin" || continue
        plugin_log "run $stage $(basename "$plugin")"
        if command -v timeout >/dev/null 2>&1; then
            FUYUN_STAGE="$stage" \
            FUYUN_SOC="$(plugin_soc_name)" \
            FUYUN_MODULE_DIR="$MODDIR" \
            FUYUN_USER_PATH="$USER_PATH" \
            FUYUN_PLUGIN_DIR="$PLUGIN_DIR" \
            timeout 5 sh "$plugin" "$@" >>"$PLUGIN_LOG" 2>&1
        else
            FUYUN_STAGE="$stage" \
            FUYUN_SOC="$(plugin_soc_name)" \
            FUYUN_MODULE_DIR="$MODDIR" \
            FUYUN_USER_PATH="$USER_PATH" \
            FUYUN_PLUGIN_DIR="$PLUGIN_DIR" \
            sh "$plugin" "$@" >>"$PLUGIN_LOG" 2>&1
        fi
        rc=$?
        plugin_log "done $stage $(basename "$plugin") rc=$rc"
    done
    local j
    for j in "$PLUGIN_DIR"/*.json; do
        [ -f "$j" ] || continue
        # 跳过停用插件与 uperf 配置插件 (配置插件仅由 WebUI "应用配置" 显式加载)
        plugin_disabled "$j" && continue
        plugin_is_config "$j" && continue
        run_json_plugin "$j" "$stage" "$@"
    done
}
