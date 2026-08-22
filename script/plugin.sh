#!/system/bin/sh
#
# plugin.sh - fuyun 第三方插件接口
#
# 第三方插件放在:
#   /sdcard/Android/yc/uperf/plugins/
#   - *.sh   传统 shell 插件
#   - *.json JSON 描述插件 (可直接放到 plugins 目录导入)
#
# JSON 插件格式:
# {
#   "name": "example",
#   "enabled": true,
#   "stages": ["apply", "clear", "boot"],
#   "command": "echo hello >> /sdcard/Android/yc/uperf/plugin_test.log"
# }
# 或
# {
#   "name": "example",
#   "enabled": true,
#   "stages": ["apply"],
#   "file": "/data/adb/modules/uperf/script/example_plugin.sh"
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
PLUGIN_DIR="$USER_PATH/plugins"
PLUGIN_LOG="$USER_PATH/plugin.log"
MODDIR="${MODDIR:-$(dirname "$(dirname "$(readlink -f "$0")")")}"

plugin_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$PLUGIN_LOG" 2>/dev/null
}

# 首次创建插件目录与说明文件
init_plugin_dir() {
    mkdir -p "$PLUGIN_DIR" 2>/dev/null
    if [ ! -f "$PLUGIN_DIR/README.txt" ]; then
        cat >"$PLUGIN_DIR/README.txt" <<'EOF'
fuyun 第三方插件目录
====================

支持两种插件:

1. Shell 插件 (*.sh)
   直接放到本目录即可, 模块按阶段调用:
     sh <plugin>.sh <stage>

2. JSON 插件 (*.json)
   直接放到本目录即可自动导入, 格式示例:
   {
     "name": "example",
     "enabled": true,
     "stages": ["apply", "clear", "boot"],
     "command": "echo hello >> /sdcard/Android/yc/uperf/plugin_test.log"
   }
   或使用 file 字段指向要执行的脚本:
   {
     "name": "example",
     "stages": ["apply"],
     "file": "/data/adb/modules/uperf/script/example_plugin.sh"
   }

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
    local content enabled name stages_json command script_file rc
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
    command=$(echo "$content" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"\\]*\(\\.[^"\\]*\)*\)".*/\1/p' | head -n 1 | sed 's/\\"/"/g; s/\\\\/\\/g')
    script_file=$(echo "$content" | sed -n 's/.*"file"[[:space:]]*:[[:space:]]*"\([^"\\]*\(\\.[^"\\]*\)*\)".*/\1/p' | head -n 1 | sed 's/\\"/"/g; s/\\\\/\\/g')
    if [ -n "$command" ]; then
        plugin_log "run-json $stage ${name:-$(basename "$file")} (command)"
        if command -v timeout >/dev/null 2>&1; then
            FUYUN_STAGE="$stage" \
            FUYUN_SOC="$(plugin_soc_name)" \
            FUYUN_MODULE_DIR="$MODDIR" \
            FUYUN_USER_PATH="$USER_PATH" \
            FUYUN_PLUGIN_DIR="$PLUGIN_DIR" \
            timeout 5 sh -c "$command" >>"$PLUGIN_LOG" 2>&1
        else
            FUYUN_STAGE="$stage" \
            FUYUN_SOC="$(plugin_soc_name)" \
            FUYUN_MODULE_DIR="$MODDIR" \
            FUYUN_USER_PATH="$USER_PATH" \
            FUYUN_PLUGIN_DIR="$PLUGIN_DIR" \
            sh -c "$command" >>"$PLUGIN_LOG" 2>&1
        fi
        rc=$?
        plugin_log "done-json $stage ${name:-$(basename "$file")} rc=$rc"
    elif [ -n "$script_file" ]; then
        if [ -f "$script_file" ]; then
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
            plugin_log "skip-json $stage ${name:-$(basename "$file")} missing file $script_file"
        fi
    else
        plugin_log "skip-json $stage ${name:-$(basename "$file")} no command/file"
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
        run_json_plugin "$j" "$stage" "$@"
    done
}
