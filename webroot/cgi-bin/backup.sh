#!/system/bin/sh
# backup.sh - 配置导入/导出与一键备份 (F3)
# 用法:
#   backup.sh?action=export          导出全部配置为带版本号 tar.gz (base64 返回)
#   POST backup.sh?action=import     导入 base64 打包的配置 (覆盖, 导入前自动 .bak)
#
# 备份范围: 内存/调速/核心/Doze/白名单/分应用/uperf.json —— 即整套调参
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)

# 受信任的配置文件 (导入时仅允许这些, 防目录穿越)
# 26w34.6-B: 配置合并为 fuyun.conf / whitelist.txt
BACKUP_FILES="fuyun.conf whitelist.txt mem_apps.txt perapp_powermode.txt uperf.json automation.txt"
VERSION=$(grep '^version' "$MODDIR/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2)
[ -n "$VERSION" ] || VERSION="unknown"

# 校验导入包内条目: 文件名全部在白名单 + 拒绝符号链接/设备/管道 + 拒绝绝对路径与 .. 穿越
whitelist_only() {
    local arc="$1" ok=1
    while IFS= read -r entry; do
        set -- $entry
        local perms="$1" f="" w
        for w in $entry; do f=$w; done   # 取最后一个字段 (文件名)
        # 拒绝符号链接/块设备/字符设备/管道 (防止借 root 复制任意文件)
        case "$perms" in
            l*|b*|c*|p*) ok=0; break ;;
        esac
        # 拒绝绝对路径与 .. 穿越
        case "$f" in
            /*|*\.\./*|\.\.*) ok=0; break ;;
        esac
        case "$f" in
            ./) continue ;;
            ./*) f=${f#./} ;;
        esac
        case " $BACKUP_FILES " in
            *" $f "*) ;;
            *) ok=0; break ;;
        esac
    done <<EOF
$(tar -tzvf "$arc" 2>/dev/null)
EOF
    [ "$ok" = "1" ]
}

case "$ACTION" in
export)
    tmpd=$(mktemp -d /data/local/tmp/fuyun_bak.XXXXXX 2>/dev/null)
    [ -n "$tmpd" ] || { json_err "无法创建临时目录"; exit 0; }
    cnt=0
    for f in $BACKUP_FILES; do
        if [ -f "$USER_PATH/$f" ]; then
            cp -f "$USER_PATH/$f" "$tmpd/$f" 2>/dev/null && cnt=$((cnt + 1))
        fi
    done
    ts=$(date '+%Y%m%d_%H%M%S')
    arc="$tmpd/fuyun_config_${VERSION}_${ts}.tar.gz"
    ( cd "$tmpd" && tar -czf "$arc" . ) 2>/dev/null
    if [ ! -f "$arc" ]; then
        rm -rf "$tmpd" 2>/dev/null
        json_err "打包失败"
        exit 0
    fi
    b64=$(base64 "$arc" 2>/dev/null | tr -d '\n')
    rm -rf "$tmpd" 2>/dev/null
    json_headers
    printf '{"ok":true,"count":%s,"version":"%s","name":"%s","data":"%s"}\n' \
        "$cnt" "$VERSION" "$(basename "$arc")" "$b64"
    ;;
import)
    if [ "$REQUEST_METHOD" = "POST" ]; then
        BODY=$(cat)
    else
        BODY=$(qget data)
    fi
    [ -n "$BODY" ] || { json_err "内容为空"; exit 0; }
    [ "${#BODY}" -le 4194304 ] 2>/dev/null || { json_err "内容过大 (>4MB)"; exit 0; }
    tmpd=$(mktemp -d /data/local/tmp/fuyun_imp.XXXXXX 2>/dev/null)
    [ -n "$tmpd" ] || { json_err "无法创建临时目录"; exit 0; }
    printf '%s' "$BODY" | base64 -d 2>/dev/null >"$tmpd/arc.tar.gz"
    if ! tar -tzf "$tmpd/arc.tar.gz" >/dev/null 2>&1; then
        rm -rf "$tmpd" 2>/dev/null
        json_err "不是有效的备份包"
        exit 0
    fi
    if ! whitelist_only "$tmpd/arc.tar.gz"; then
        rm -rf "$tmpd" 2>/dev/null
        json_err "备份包含未授权文件, 已拒绝 (仅允许配置文件)"
        exit 0
    fi
    ( cd "$tmpd" && tar -xzf "$tmpd/arc.tar.gz" ) 2>/dev/null
    mkdir -p "$USER_PATH"
    restored=""
    for f in $BACKUP_FILES; do
        # 仅接受常规文件 (拒绝符号链接, whitelist_only 已过滤但双重保险)
        if [ -f "$tmpd/$f" ] && [ ! -L "$tmpd/$f" ]; then
            [ -f "$USER_PATH/$f" ] && cp -f "$USER_PATH/$f" "$USER_PATH/$f.bak" 2>/dev/null
            cp -f "$tmpd/$f" "$USER_PATH/$f" 2>/dev/null && restored="$restored $f"
        fi
    done
    rm -rf "$tmpd" 2>/dev/null
    json_ok "已还原:${restored} (原文件已备份为 .bak, 建议重载配置)"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
