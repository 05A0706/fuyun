#!/system/bin/sh
#
# webuid.sh - WebUI HTTP 服务 (busybox/toybox httpd)
# 监听 127.0.0.1:16800, 仅本机可访问; root 运行
#
# 工作方式:
#   管理器 (Magisk/KernelSU) 打开模块 WebUI 时加载 webroot/index.html,
#   页面通过 CORS 直接访问 http://127.0.0.1:16800/cgi-bin/ (本服务),
#   混合内容被拦截时自动跳转到 http://127.0.0.1:16800/ 同源访问。
#
# 用法: webuid.sh start|stop|status|restart

BASEDIR="$(dirname "$(readlink -f "$0")")"
MODDIR="${BASEDIR%\/script}"
WEBROOT="$MODDIR/webroot"
PORT=16800
# 16800 = 0x4198; 回环地址 127.0.0.1 在 /proc/net/tcp 中为 0100007F, 任意地址为 00000000
PORT_HEX=4198
PIDFILE="/data/local/tmp/webuid.pid"
LOGFILE="/data/local/tmp/webuid.log"

log() { echo "[webuid] $(date '+%m-%d %H:%M:%S') $*" >>"$LOGFILE"; }

# 端口占用检测: 直接查 /proc/net/tcp, 不依赖 nc (部分设备无 nc/-z)
port_in_use() {
    grep -qE "^ *[0-9]+: (0100007F|00000000):$PORT_HEX " /proc/net/tcp 2>/dev/null && return 0
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
    # 优先模块自带 busybox httpd: 行为可控, 已确认支持 CGI 与 [ip:]port 格式
    # (osm0sis busybox v1.31.1, 编译了 FEATURE_HTTPD_CGI)
    if [ -x "$MODDIR/bin/busybox/busybox" ] && "$MODDIR/bin/busybox/busybox" httpd --help 2>&1 | grep -q '\-p'; then
        echo "busybox"
        return
    fi
    # 其次 toybox httpd (部分设备/版本 -p 只接受纯端口, 启动时自动回退)
    if toybox httpd --help 2>&1 | grep -q '\-c'; then
        echo "toybox"
        return
    fi
    echo "none"
}

# 尝试启动 httpd (前台/默认模式 x IP:PORT/纯PORT 共 4 种组合)
try_boot() {
    local mode addr pid
    for mode in "-f" ""; do
        for addr in "127.0.0.1:$PORT" "$PORT"; do
            $httpd $mode -p "$addr" -h "$WEBROOT" $args >>"$LOGFILE" 2>&1 &
            pid=$!
            sleep 1
            if port_in_use; then
                echo "$pid" >"$PIDFILE"
                if http_ping "http://127.0.0.1:$PORT/cgi-bin/status.sh"; then
                    log "started OK (mode=[$mode] addr=$addr pid=$pid)"
                else
                    log "port in use, API self-check failed (mode=[$mode] addr=$addr pid=$pid)"
                fi
                return 0
            fi
            kill "$pid" 2>/dev/null
        done
    done
    return 1
}

start() {
    # 自愈1: Windows 打包易产生 CRLF 行尾 —— CGI 脚本由 httpd execve 直接执行,
    # 内核按 shebang 找解释器时 "#!/system/bin/sh\r" 尾部 \r 导致解释器不存在,
    # 症状: 页面能打开 (静态文件正常) 但 API 全部失败 (连不上API)。此处幂等转 LF。
    for f in "$MODDIR"/script/*.sh "$MODDIR"/common/*.sh \
             "$MODDIR"/action.sh "$MODDIR"/install.sh "$MODDIR"/uninstall.sh \
             "$MODDIR"/customize.sh "$WEBROOT"/cgi-bin/*.sh; do
        [ -f "$f" ] || continue
        if grep -q "$(printf '\r')" "$f" 2>/dev/null; then
            tr -d "$(printf '\r')" <"$f" >"$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
            log "fixed CRLF: $f"
        fi
    done
    # 自愈2: KernelSU 等管理器解压 zip 可能不保留权限位, 启动前统一修复
    # (busybox 无 +x 会导致 find_httpd 检测失败, 脚本无 +x 会导致 CGI 403)
    chmod 755 "$MODDIR/bin/busybox/busybox" "$MODDIR/bin/uperf" "$MODDIR/action.sh" 2>/dev/null
    chmod 755 "$MODDIR"/script/*.sh "$MODDIR"/common/*.sh 2>/dev/null
    chmod 755 "$WEBROOT"/cgi-bin/*.sh 2>/dev/null

    [ -d "$WEBROOT" ] || { log "webroot missing: $WEBROOT"; return 1; }

    if port_in_use; then
        # 升级/重装场景: 旧 httpd 进程可能仍占用端口, 先清理再启动
        if command -v pkill >/dev/null 2>&1; then
            pkill -f "httpd.*$PORT" 2>/dev/null
            sleep 1
        fi
        if port_in_use; then
            log "port $PORT still in use by other process, skip"
            return 0
        fi
        log "killed stale httpd on port $PORT, restarting"
    fi

    case "$(find_httpd)" in
    busybox)
        httpd="$MODDIR/bin/busybox/busybox httpd"
        args=""
        ;;
    toybox)
        httpd="toybox httpd"
        args="-c /cgi-bin"
        ;;
    none)
        log "no httpd available, WebUI disabled"
        return 1
        ;;
    esac
    log "using $httpd"

    # 立即尝试一轮; 开机早期环境未就绪时自动重试 3 轮
    if try_boot; then
        return 0
    fi
    for retry in 1 2 3; do
        log "boot attempt $retry/3 failed, retrying in 3s"
        sleep 3
        try_boot && return 0
    done
    log "httpd failed to start on 127.0.0.1:$PORT (all attempts exhausted)"
    return 1
}

stop() {
    # 先杀 PID 文件记录
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
    fi
    # 兜底: 按命令行特征清理本模块 httpd (兼容 httpd 自行 daemonize / 纯端口绑定的情况)
    command -v pkill >/dev/null 2>&1 && pkill -f "httpd.*$PORT" 2>/dev/null
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
