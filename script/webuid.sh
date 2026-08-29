#!/system/bin/sh
#
# webuid.sh - WebUI HTTP 服务 (toybox/busybox httpd)
# 监听 127.0.0.1:16800, 仅本机可访问; root 运行
#
# 工作方式:
#   管理器 (Magisk/KernelSU) 打开模块 WebUI 时加载 webroot/index.html,
#   页面检测到 https 环境后自动跳转到 http://127.0.0.1:16800/ (本服务),
#   页面与 API 同源, 无混合内容拦截。
#
# 用法: webuid.sh start|stop|status|restart

BASEDIR="$(dirname "$(readlink -f "$0")")"
MODDIR="${BASEDIR%\/script}"
WEBROOT="$MODDIR/webroot"
PORT=16800
PIDFILE="/data/local/tmp/webuid.pid"
LOGFILE="/data/local/tmp/webuid.log"

# F5: WebUI 访问令牌 (root-only, 由 CGI 的 require_token 校验)
WEBUI_TOKEN_DIR=/data/adb/uperf
WEBUI_TOKEN_FILE="$WEBUI_TOKEN_DIR/.webui_token"
WEBUI_TOKEN_VAL=""

log() { echo "[webuid] $(date '+%m-%d %H:%M:%S') $*" >>"$LOGFILE"; }

port_in_use() {
    # 直接探测 HTTP 服务 (不依赖 nc -z: 部分 ROM 的 nc 不支持 -z 会误判端口空闲)
    toybox wget -q -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && return 0
    return 1
}

find_httpd() {
    # 优先 toybox httpd, 仅当支持 -c (CGI) 时可用
    if toybox httpd --help 2>&1 | grep -q '\-c'; then
        echo "toybox"
        return
    fi
    # 其次模块自带 busybox httpd (cgi-bin 目录自动按 CGI 处理)
    if [ -x "$MODDIR/bin/busybox/busybox" ] && "$MODDIR/bin/busybox/busybox" httpd --help 2>&1 | grep -q '\-p'; then
        echo "busybox"
        return
    fi
    echo "none"
}

start() {
    port_in_use && { log "port $PORT already in use, skip"; return 0; }
    [ -d "$WEBROOT" ] || { log "webroot missing: $WEBROOT"; return 1; }

    # F5: 生成访问令牌并注入页面 (必须在 httpd 启动前完成)
    gen_webui_token

    case "$(find_httpd)" in
    toybox)
        # toybox httpd: -c 指定 CGI 前缀
        toybox httpd -p 127.0.0.1:$PORT -h "$WEBROOT" -c /cgi-bin >>"$LOGFILE" 2>&1 &
        ;;
    busybox)
        # busybox httpd: /cgi-bin/ 路径自动按 CGI 执行
        "$MODDIR/bin/busybox/busybox" httpd -p 127.0.0.1:$PORT -h "$WEBROOT" >>"$LOGFILE" 2>&1 &
        ;;
    none)
        log "no httpd available, WebUI disabled"
        return 1
        ;;
    esac

    local pid=$!
    echo "$pid" >"$PIDFILE"
    sleep 1

    # 自检: 请求 status API (带上令牌, 否则会被 require_token 拒绝)
    if toybox wget -q -O /dev/null "http://127.0.0.1:$PORT/cgi-bin/status.sh?token=$WEBUI_TOKEN_VAL" 2>/dev/null; then
        log "started OK on 127.0.0.1:$PORT (pid $pid)"
    elif port_in_use; then
        log "port in use after start (assume OK)"
    else
        log "httpd self-check FAILED (pid $pid)"
    fi
}

# F5: 生成 WebUI 令牌 (root-only), 并注入 index.html 供页面携带
# 注意: 这是纵深防御; 直接回环访问的本地 App 也能从 index.html 读到令牌,
# 完整修复需 Magisk/KernelSU 管理器在请求外带令牌 (见 lib.sh 注释)。
gen_webui_token() {
    mkdir -p "$WEBUI_TOKEN_DIR" 2>/dev/null
    local t=""
    if [ -r /dev/urandom ]; then
        t=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    fi
    [ -n "$t" ] || t="$(date +%s%N)$$"
    echo "$t" >"$WEBUI_TOKEN_FILE"
    chmod 600 "$WEBUI_TOKEN_FILE" 2>/dev/null
    chown root:root "$WEBUI_TOKEN_FILE" 2>/dev/null
    WEBUI_TOKEN_VAL="$t"
    inject_token_to_page "$t"
}

# 把令牌幂等写入 index.html 的 const WEBUI_TOKEN = "..."; 行
inject_token_to_page() {
    local t="$1" page="$WEBROOT/index.html"
    [ -f "$page" ] || return 0
    sed -i "s/const WEBUI_TOKEN *= *\"[^\"]*\";/const WEBUI_TOKEN = \"$t\";/" "$page" 2>/dev/null
}

stop() {
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
        log "stopped"
    else
        log "not running"
    fi
}

status() {
    if port_in_use; then
        echo "running on 127.0.0.1:$PORT"
        return 0
    fi
    echo "stopped"
    return 1
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *)       echo "usage: webuid.sh start|stop|status|restart" ;;
esac
