#!/system/bin/sh
#
# lib.sh - WebUI CGI 公共函数 (被 cgi-bin 下各 API 脚本 source)
#
# 输出约定: 全部 API 返回 JSON, 带 CORS 头 (允许 WebView 跨源访问)

USER_PATH=/sdcard/Android/yc/uperf
# 26w34.6-B 第四轮: 配置合并 → fuyun.conf / whitelist.txt (分区格式)
CFG="$USER_PATH/fuyun.conf"          # [mem]
WL="$USER_PATH/whitelist.txt"        # [mem]
APPS_FILE="$USER_PATH/mem_apps.txt"
LOG="$USER_PATH/mem_log.txt"
POWERMODE_FILE="$USER_PATH/cur_powermode.txt"
RECLAIM_NOW="$USER_PATH/reclaim_now"
IDLE_CFG="$USER_PATH/fuyun.conf"     # [idle_gov]
IDLE_WL="$USER_PATH/whitelist.txt"   # [idle_gov]
GOV_STATE_FILE="$USER_PATH/idle_gov.state"
DOZE_WL="$USER_PATH/whitelist.txt"   # [doze]
PERAPP_FILE="$USER_PATH/perapp_powermode.txt"
UPERF_JSON="$USER_PATH/uperf.json"
CORECTL_CFG="$USER_PATH/fuyun.conf"  # [corectl]
AUTOMATION_FILE="$USER_PATH/automation.txt"
# 预设目录 (root-only; 自定义预设快照)
PRESETS_DIR=/data/adb/uperf/presets
# 模块根目录 (由 webroot/cgi-bin/ 向上推导), 替代硬编码 /data/adb/modules/uperf
MODDIR="$(dirname "$(dirname "$(dirname "$(readlink -f "$0")")")")"
CORECTL_SCRIPT="$MODDIR/script/corectl.sh"

# 分区配置工具 (section_body / set_section_kv / get_section_kv / migrate_legacy) 复用守护脚本的 libcommon.sh
[ -f "$MODDIR/script/libcommon.sh" ] && . "$MODDIR/script/libcommon.sh"

# WebUI 访问令牌 (F5): 仅 root 可读, 由 webuid.sh 启动时生成。
# 注意: 这是防御纵深, 无法彻底解决回环接口被任意本地 App 访问的问题
# (详见 docs/code-review 1.1); 彻底修复需 Magisk/KernelSU 管理器在请求外带令牌。
WEBUI_TOKEN_FILE=/data/adb/uperf/.webui_token

# JSON 头 (页面与 API 同源, 不再返回 CORS 通配头, 收紧跨源暴露面)
json_headers() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
}

# $1: JSON 字符串
json_out() {
    json_headers
    printf '%s\n' "$1"
}

json_ok() {
    json_out "{\"ok\":true,\"msg\":\"$(json_escape "$1")\"}"
}

json_err() {
    json_out "{\"ok\":false,\"msg\":\"$(json_escape "$1")\"}"
}

# URL 解码 (POSIX 安全): %b 只保证八进制转义, 先把 %HH 转成 \OOO
# (dash 等 shell 的 printf %b 不识别 \xHH, 直接 sed+%b 会把 %7C 留成字面量)
url_decode() {
    local s="$1" out="" ch pair
    while [ -n "$s" ]; do
        ch=${s%"${s#?}"}
        case "$ch" in
            +)
                out="${out} "
                s=${s#?}
                ;;
            %)
                pair=${s#%}
                pair=${pair%"${pair#??}"}
                case "$pair" in
                    [0-9A-Fa-f][0-9A-Fa-f])
                        out="${out}$(printf '%b' "\\$(printf '%03o' "0x$pair")")"
                        s=${s#%??}
                        ;;
                    *)
                        out="${out}%"
                        s=${s#?}
                        ;;
                esac
                ;;
            *)
                out="${out}${ch}"
                s=${s#?}
                ;;
        esac
    done
    printf '%s' "$out"
}

# JSON 字符串转义: 反斜杠与双引号 (日志/配置文件内容行使用)
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# 解析 QUERY_STRING: 输出 "key value" 行 (URL 解码 %XX, + 转空格)
parse_query() {
    local kv k v
    echo "$QUERY_STRING" | tr '&' '\n' | while IFS='=' read -r kv v; do
        k=$(url_decode "$kv")
        v=$(url_decode "$v")
        echo "$k $v"
    done
}

# $1: key; 从 QUERY_STRING 中取值
qget() {
    local want="$1" k v
    parse_query | while read -r k v; do
        [ "$k" = "$want" ] && { echo "$v"; return; }
    done
}

# 读取 fuyun.conf [mem] 分区某键的值
get_cfg() {
    [ -f "$CFG" ] || return 0
    grep "^$1=" "$CFG" 2>/dev/null | head -n 1 | cut -d= -f2
}

# 一次性读出配置分区中的多个键, 输出 "key=value" 行
# $1: 文件  $2: 分区  $3...: 键名
# 语义与原先的 grep "^k=" | head -n 1 | cut -d= -f2 一致: 只取首次出现的键, 去行内注释与首尾空白;
# 未匹配的键不输出 (调用方保留自己的默认值)。
read_keys() {
    [ -f "$1" ] || return 0
    local f="$1" sec="$2"
    shift 2
    section_body "$f" "$sec" 2>/dev/null | awk -v want=" $* " '
        {
            line = $0
            sub(/#.*/, "", line)
            p = index(line, "=")
            if (p == 0) next
            k = substr(line, 1, p - 1)
            v = substr(line, p + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k != "" && index(want, " " k " ") > 0 && !(k in seen)) {
                seen[k] = 1
                print k "=" v
            }
        }
    ' 2>/dev/null
}

# 校验键名白名单 (防注入), $1=key → 合法返回 0
cfg_key_valid() {
    case "$1" in
        MEM_ENABLE|MODE|INTERVAL|PSI_THRESHOLD|HARD_RECLAIM|MAX_PER_ROUND|IDLE_KILL_MIN|SWITCH_RECLAIM|PUSH_KEEP|KEEP_CMDLINE)
            return 0 ;;
    esac
    return 1
}

# 校验模式值
mode_valid() {
    case "$1" in
        powersave|balance|performance|fast) return 0 ;;
    esac
    return 1
}

# 校验回收模式值
reclaim_mode_valid() {
    case "$1" in
        soft|hard|kill|off) return 0 ;;
    esac
    return 1
}

# 写 mem 分区配置: $1=key $2=value (保留注释与其余键, 原子替换)
set_cfg() {
    set_section_kv "$CFG" mem "$1" "$2"
}

# ===== 白名单分区行操作 (whitelist.txt) =====
# 行归一: 去行内注释与首尾空白 (用于去重/删除匹配)
# 分区内添加一行 (去重): $1=文件 $2=分区 $3=行内容
add_section_line() {
    local f="$1" s="$2" line="$3" tmp
    tmp="$f.tmp"
    awk -v s="$s" -v line="$line" '
    function norm(s,   i) {
        i = index(s, "#"); if (i) s = substr(s, 1, i - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    function flush(   i) { for (i = 1; i <= bn; i++) print buf[i]; bn = 0 }
    {
        if ($0 ~ /^\[/) {
            flush()
            # 离开目标分区: 若未重复, 在分区末尾补插
            if (inseg && !dup) print line
            if ($0 == "[" s "]") seen_sec = 1
            inseg = ($0 == "[" s "]")
            dup = 0
            print
            next
        }
        if (inseg) {
            if (norm($0) == line) { dup = 1; next }
        }
        buf[++bn] = $0
    }
    END {
        flush()
        if (inseg && !dup) print line          # 目标分区是最后一个分区: 末尾补插
        else if (!seen_sec) { print "[" s "]"; print line }  # 分区不存在: 创建
    }
    ' "$f" >"$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$f"
}

# 分区内删除一行 (按去注释后的内容匹配): $1=文件 $2=分区 $3=行内容
del_section_line() {
    local f="$1" s="$2" line="$3" tmp
    tmp="$f.tmp"
    awk -v s="$s" -v line="$line" '
    function norm(s,   i) {
        i = index(s, "#"); if (i) s = substr(s, 1, i - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    $0 == "[" s "]" { inseg = 1 }
    inseg && $0 ~ /^\[/ && $0 != "[" s "]" { inseg = 0 }
    inseg && norm($0) == line { next }
    { print }
    ' "$f" >"$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$f"
}

# ==================== F5: WebUI 访问认证 ====================
# 校验请求是否携带正确令牌。令牌由 webuid.sh 生成于 WEBUI_TOKEN_FILE (0600)。
# 取参顺序: QUERY_STRING 的 token= → HTTP_X_TOKEN 头 (CGI 由 httpd 注入为 HTTP_* 变量)。
# 若令牌文件不存在 (理论上 webuid 启动即生成) 则放行, 保证不把控制台锁死。
require_token() {
    [ -f "$WEBUI_TOKEN_FILE" ] || return 0
    local expect given
    expect=$(cat "$WEBUI_TOKEN_FILE" 2>/dev/null)
    [ -n "$expect" ] || return 0
    given=$(qget token)
    [ -z "$given" ] && given="$HTTP_X_TOKEN"
    [ "$given" = "$expect" ] && return 0
    json_err "未授权 (缺少或无效的访问令牌)"
    exit 0
}

# ==================== F7: 统一配置校验 + 原子写入 + 回滚 ====================
# 值校验工具 (复用, 避免各 CGI 各自写 grep 正则)
valid_bool() { case "$1" in 0|1) return 0 ;; esac; return 1; }
valid_uint() { echo "$1" | grep -qE '^[0-9]+$'; }
valid_int()  { echo "$1" | grep -qE '^-?[0-9]+$'; }
valid_pkg()  { echo "$1" | grep -qE '^[a-zA-Z0-9_.]+$'; }
valid_pkg_prefix() { echo "$1" | grep -qE '^[a-zA-Z0-9_.]+(\*)?$'; }
# $1=值, 其余参数为允许的枚举值
valid_enum() {
    local v="$1"; shift
    local a
    for a in "$@"; do [ "$v" = "$a" ] && return 0; done
    return 1
}
# 数字范围 (含端点): $1=值 $2=min $3=max
valid_range() {
    valid_int "$1" || return 1
    [ "$1" -ge "$2" ] 2>/dev/null || return 1
    [ "$1" -le "$3" ] 2>/dev/null || return 1
    return 0
}
# sed 模式字面量转义 (集中到 lib, 各 CGI 不再各写一份)
sed_escape() {
    printf '%s' "$1" | sed 's/\./\\./g; s/\*/\\*/g; s/\[/\\[/g; s/\]/\\]/g; s/\^/\\^/g; s/\$/\\$/g; s#/#\\/#g'
}

# 原子写入: 写 tmp 后 rename, 写前保留一份 .bak 备份 (仅最近一份)
atomic_write() {  # $1=目标文件 内容经 stdin
    local f="$1" tmp
    [ -f "$f" ] && cp -f "$f" "$f.bak" 2>/dev/null
    tmp="$f.tmp"
    cat >"$tmp"
    mv -f "$tmp" "$f"
}

# 对文件做整文件原子替换 (供 sed -i 类操作包装, 保证原子 + 自动备份)
# 用法: atomic_sed <file> <sed-args...>   (sed 输出即新内容)
atomic_sed() {
    local f="$1"; shift
    [ -f "$f" ] && cp -f "$f" "$f.bak" 2>/dev/null
    local tmp="$f.tmp"
    sed "$@" "$f" >"$tmp" 2>/dev/null && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# key=value 写入 (保留注释与其余键, 原子替换 + 自动备份)
set_kv_file() {  # $1=file $2=key $3=value
    local f="$1" k="$2" v="$3" tmp found=0
    tmp="$f.tmp"; : >"$tmp"
    if [ -f "$f" ]; then
        while IFS='=' read -r kk vv; do
            if [ "$kk" = "$k" ]; then
                echo "$k=$v" >>"$tmp"
                found=1
            else
                echo "$kk=$vv" >>"$tmp"
            fi
        done <"$f"
    fi
    [ "$found" = "0" ] && echo "$k=$v" >>"$tmp"
    mv -f "$tmp" "$f"
}
