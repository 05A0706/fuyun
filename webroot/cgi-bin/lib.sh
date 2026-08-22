#!/system/bin/sh
#
# lib.sh - WebUI CGI 公共函数 (被 cgi-bin 下各 API 脚本 source)
#
# 输出约定: 全部 API 返回 JSON, 带 CORS 头 (允许 WebView 跨源访问)

USER_PATH=/sdcard/Android/yc/uperf
CFG="$USER_PATH/mem_config.txt"
WL="$USER_PATH/mem_whitelist.txt"
APPS_FILE="$USER_PATH/mem_apps.txt"
LOG="$USER_PATH/mem_log.txt"
POWERMODE_FILE="$USER_PATH/cur_powermode.txt"
RECLAIM_NOW="$USER_PATH/reclaim_now"
IDLE_CFG="$USER_PATH/idle_gov.txt"
IDLE_WL="$USER_PATH/idle_whitelist.txt"
GOV_STATE_FILE="$USER_PATH/idle_gov.state"
DOZE_WL="$USER_PATH/doze_whitelist.txt"
PERAPP_FILE="$USER_PATH/perapp_powermode.txt"
UPERF_JSON="$USER_PATH/uperf.json"
FREQ_CFG="$USER_PATH/freq_limit.txt"
FREQ_RANGE_CFG="$USER_PATH/freq_range.txt"
FREQ_MASK_SRC=/data/local/tmp/fuyun_freq_cap_

# JSON 头 + CORS (WebUI 页面由 Magisk/KSU 内置服务提供, 跨源访问本 API)
json_headers() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
}

# $1: JSON 字符串
json_out() {
    json_headers
    printf '%s\n' "$1"
}

json_ok() {
    json_out "{\"ok\":true,\"msg\":\"$1\"}"
}

json_err() {
    json_out "{\"ok\":false,\"msg\":\"$1\"}"
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

# 读取 mem_config.txt 某键的值
get_cfg() {
    [ -f "$CFG" ] || return 0
    grep "^$1=" "$CFG" 2>/dev/null | head -n 1 | cut -d= -f2
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

# 写 mem_config.txt: $1=key $2=value (保留注释与其余键)
set_cfg() {
    local key="$1" val="$2" tmp
    tmp="$CFG.tmp"
    : >"$tmp"
    local found=0
    while IFS='=' read -r k v; do
        if [ "$k" = "$key" ]; then
            echo "$key=$val" >>"$tmp"
            found=1
        else
            echo "$k=$v" >>"$tmp"
        fi
    done <"$CFG"
    [ "$found" = "0" ] && echo "$key=$val" >>"$tmp"
    mv "$tmp" "$CFG"
}
