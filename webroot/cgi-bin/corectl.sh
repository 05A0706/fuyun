#!/system/bin/sh
# corectl.sh - 核心开关 查询与设置
# 用法: corectl.sh?action=get
#       corectl.sh?action=set&key=CORECTL_ENABLE&value=1
#       corectl.sh?action=clear
. "$(dirname "$0")/lib.sh"
require_token

ACTION=$(qget action)

# 读取配置键 (带默认值回退)
cfg_get() {
    local k="$1" v
    v=$(get_section_kv "$CORECTL_CFG" corectl "$k")
    [ -n "$v" ] || v="$2"
    echo "$v"
}

# 写 fuyun.conf [corectl] 分区 (保留注释与其余键)
cfg_set() {
    set_section_kv "$CORECTL_CFG" corectl "$1" "$2"
}

# 调用底层脚本查询状态 (key=value 输出)
corectl_status() {
    sh "$CORECTL_SCRIPT" status 2>/dev/null
}

kv() {
    echo "$1" | grep "^$2=" | head -n 1 | cut -d= -f2
}

case "$ACTION" in
get)
    json_headers
    INFO=$(corectl_status)
    ENABLE=$(kv "$INFO" ENABLE);     [ -n "$ENABLE" ]     || ENABLE=0
    OFFSCREEN=$(kv "$INFO" OFFSCREEN_OFF); [ -n "$OFFSCREEN" ] || OFFSCREEN=0
    IDLE_OFF=$(kv "$INFO" IDLE_OFF); [ -n "$IDLE_OFF" ]    || IDLE_OFF=1
    BIG_OFF=$(kv "$INFO" BIG_OFF);   [ -n "$BIG_OFF" ]     || BIG_OFF=0
    MID_OFF=$(kv "$INFO" MID_OFF);   [ -n "$MID_OFF" ]     || MID_OFF=0
    KEEP_LITTLE=$(kv "$INFO" KEEP_LITTLE); [ -n "$KEEP_LITTLE" ] || KEEP_LITTLE=1
    BIG_TOTAL=$(kv "$INFO" BIG_TOTAL);     [ -n "$BIG_TOTAL" ]     || BIG_TOTAL=0
    MID_TOTAL=$(kv "$INFO" MID_TOTAL);     [ -n "$MID_TOTAL" ]     || MID_TOTAL=0
    LITTLE_TOTAL=$(kv "$INFO" LITTLE_TOTAL); [ -n "$LITTLE_TOTAL" ] || LITTLE_TOTAL=0
    ONLINE_BIG=$(kv "$INFO" ONLINE_BIG);   [ -n "$ONLINE_BIG" ]   || ONLINE_BIG=0
    ONLINE_MID=$(kv "$INFO" ONLINE_MID);   [ -n "$ONLINE_MID" ]   || ONLINE_MID=0
    ONLINE_LITTLE=$(kv "$INFO" ONLINE_LITTLE); [ -n "$ONLINE_LITTLE" ] || ONLINE_LITTLE=0
    OV_IDLE=$(kv "$INFO" OVERLAY_IDLE);     [ -n "$OV_IDLE" ]      || OV_IDLE=0
    OV_SCREEN=$(kv "$INFO" OVERLAY_SCREEN); [ -n "$OV_SCREEN" ]    || OV_SCREEN=0
    OFFLINED=$(kv "$INFO" OFFLINE_LIST)
    ACTIVE=0
    [ -n "$OFFLINED" ] && ACTIVE=1

    printf '{'
    printf '"ok":true,'
    printf '"enable":%s,' "$ENABLE"
    printf '"offscreen":%s,' "$OFFSCREEN"
    printf '"idle_off":%s,' "$IDLE_OFF"
    printf '"big_off":%s,' "$BIG_OFF"
    printf '"mid_off":%s,' "$MID_OFF"
    printf '"keep_little":%s,' "$KEEP_LITTLE"
    printf '"big_total":%s,' "$BIG_TOTAL"
    printf '"mid_total":%s,' "$MID_TOTAL"
    printf '"little_total":%s,' "$LITTLE_TOTAL"
    printf '"online_big":%s,' "$ONLINE_BIG"
    printf '"online_mid":%s,' "$ONLINE_MID"
    printf '"online_little":%s,' "$ONLINE_LITTLE"
    printf '"overlay_idle":%s,' "$OV_IDLE"
    printf '"overlay_screen":%s,' "$OV_SCREEN"
    printf '"active":%s,' "$ACTIVE"
    printf '"offlined":"%s"' "$OFFLINED"
    printf '}\n'
    ;;
set)
    KEY=$(qget key)
    VAL=$(qget value)
    case "$KEY" in
        CORECTL_ENABLE|OFFSCREEN_OFF|IDLE_OFF|KEEP_LITTLE)
            valid_bool "$VAL" || { json_err "value must be 0 or 1"; exit 0; }
            ;;
        BIG_OFF|MID_OFF)
            valid_uint "$VAL" || { json_err "value must be a non-negative integer"; exit 0; }
            ;;
        *) json_err "invalid key: $KEY"; exit 0 ;;
    esac
    # 关核数上限校验 (不超过该簇总数; 小核簇永不参与关核, 故允许整簇关闭大/中核)
    if [ "$KEY" = "BIG_OFF" ] && [ "$BIG_TOTAL" -gt 0 ] 2>/dev/null; then
        [ "$VAL" -gt "$BIG_TOTAL" ] 2>/dev/null && { json_err "BIG_OFF 最多 $BIG_TOTAL (本机大核共 $BIG_TOTAL 颗)"; exit 0; }
    fi
    if [ "$KEY" = "MID_OFF" ] && [ "$MID_TOTAL" -gt 0 ] 2>/dev/null; then
        [ "$VAL" -gt "$MID_TOTAL" ] 2>/dev/null && { json_err "MID_OFF 最多 $MID_TOTAL (本机中核共 $MID_TOTAL 颗)"; exit 0; }
    fi
    cfg_set "$KEY" "$VAL"
    sh "$CORECTL_SCRIPT" apply 2>/dev/null
    json_ok "$KEY=$VAL 已保存并应用"
    ;;
clear)
    sh "$CORECTL_SCRIPT" clear 2>/dev/null
    json_ok "已恢复全部核心在线"
    ;;
*)
    json_err "unknown action: $ACTION"
    ;;
esac
