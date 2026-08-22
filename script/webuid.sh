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
# 16800 = 0x4198, 本地回环地址 127.0.0.1 在 /proc/net/tcp 中为 0100007F
PORT_HEX=4198
PIDFILE="/data/local/tmp/webuid.pid"
LOGFILE="/data/local/tmp/webuid.log"

log() { echo "[webuid] $(date '+%m-%d %H:%M:%S') $*" >>"$LOGFILE"; }

# 端口占用检测: 直接查 /proc/net/tcp, 不依赖 nc (部分设备无 nc/-z)
port_in_use() {
    grep -qE "^ *[0-9]+: 0100007F:$PORT_HEX " /proc/net/tcp 2>/dev/null && return 0
    grep -qE "^ *[0-9]+: 0100007F:$PORT_HEX " /proc/net/tcp6 2>/dev/null && return 0
    return 1
}

# HTTP 自检: wget / curl 任一可用即可, 都没有则仅依赖端口检查
http_ping() {
    if command -v wget >/dev/null 2>&1; then
        wget -q -O /dev/null "$1" 2>/dev/null && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fs -o /dev/null "$1" 2>/dev/null && return 0
    fi
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
    # 自愈: 确保 CGI 脚本可执行 (部分安装流程会丢失 +x, 导致 API 全部 403)
    chmod 755 "$WEBROOT"/cgi-bin/*.sh 2>/dev/null

    port_in_use && { log "port $PORT already in use, skip"; return 0; }
    [ -d "$WEBROOT" ] || { log "webroot missing: $WEBROOT"; return 1; }

    local httpd args pid
    case "$(find_httpd)" in
    toybox)
        httpd="toybox httpd"
        args="-c /cgi-bin"
        ;;
    busybox)
        httpd="$MODDIR/bin/busybox/busybox httpd"
        args=""
        ;;
    none)
        log "no httpd available, WebUI disabled"
        return 1
        ;;
    esac

    # 1) 先试前台模式 (-f, 进程 PID 可控; 部分旧版不支持则自动回退)
    $httpd -f -p 127.0.0.1:$PORT -h "$WEBROOT" $args >>"$LOGFILE" 2>&1 &
    pid=$!
    sleep 1
    if port_in_use; then
        echo "$pid" >"$PIDFILE"
        if http_ping "http://127.0.0.1:$PORT/cgi-bin/status.sh"; then
            log "started OK on 127.0.0.1:$PORT (pid $pid)"
        else
            log "port in use, API self-check failed (pid $pid)"
        fi
        return 0
    fi
    kill "$pid" 2>/dev/null

    # 2) 回退默认模式
    $httpd -p 127.0.0.1:$PORT -h "$WEBROOT" $args >>"$LOGFILE" 2>&1 &
    pid=$!
    sleep 1
    if port_in_use; then
        echo "$pid" >"$PIDFILE"
        if http_ping "http://127.0.0.1:$PORT/cgi-bin/status.sh"; then
            log "started OK on 127.0.0.1:$PORT (pid $pid)"
        else
            log "port in use, API self-check failed (pid $pid)"
        fi
        return 0
    fi
    kill "$pid" 2>/dev/null

    log "httpd failed to start on 127.0.0.1:$PORT"
    return 1
}

stop() {
    # 先杀 PID 文件记录
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
    fi
    # 兜底: 按命令行特征清理本模块 httpd (兼容 httpd 自行 daemonize 的情况)
    command -v pkill >/dev/null 2>&1 && pkill -f "httpd.*127\\.0\\.0\\.1:$PORT" 2>/dev/null
    sleep 1
    if port_in_use; then
        log "stopped (port still in use by other process)"
    else
        log "stopped"
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
