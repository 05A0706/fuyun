#!/system/bin/sh
# fuyun action: 音量上 = 开启 Vulkan, 音量下 = 还原 OpenGL
# 状态持久化到 /data/adb/uperf/vulkan.state, 开机由 post-fs-data.sh 按状态应用

STATE_DIR=/data/adb/uperf
STATE_FILE="$STATE_DIR/vulkan.state"
USER_STATE=/sdcard/Android/yc/uperf/vulkan.state

mkdir -p "$STATE_DIR" 2>/dev/null
mkdir -p /sdcard/Android/yc/uperf 2>/dev/null

# resetprop 不可用时退回 setprop (避免脚本中断)
if command -v resetprop >/dev/null 2>&1; then
    PROP=resetprop
else
    PROP=setprop
fi

vulkan_on() {
    $PROP ro.hwui.use_vulkan true
    $PROP debug.hwui.renderer skiavk
    $PROP debug.renderengine.backend skiavkthreaded
    $PROP debug.renderengine.vulkan true
    $PROP debug.renderengine.graphite true
    $PROP debug.egl.hw 1
    echo 1 >"$STATE_FILE" 2>/dev/null
    echo 1 >"$USER_STATE" 2>/dev/null
    echo " "
    echo "Vulkan 已开启"
    echo " "
}

vulkan_off() {
    $PROP ro.hwui.use_vulkan false
    $PROP debug.hwui.renderer opengl
    $PROP debug.renderengine.backend threaded
    $PROP debug.renderengine.vulkan false
    $PROP debug.renderengine.graphite false
    $PROP debug.egl.hw 0
    echo 0 >"$STATE_FILE" 2>/dev/null
    echo 0 >"$USER_STATE" 2>/dev/null
    echo " "
    echo "已还原 OpenGL"
    echo " "
}

# 从 getevent 输出中提取「音量上/音量下 按下」(只认 DOWN, 过滤抬手 UP)。
# 不依赖字段位置, 兼容带/不带时间戳、toybox/AOSP getevent 的多种输出格式。
read_key() {
    awk '
        /KEY_VOLUMEUP/   && /DOWN/ { print "KEY_VOLUMEUP";   exit }
        /KEY_VOLUMEDOWN/ && /DOWN/ { print "KEY_VOLUMEDOWN"; exit }
    ' "$1" 2>/dev/null
}

echo "=============================="
echo " 音量上 = 开启 Vulkan"
echo " 音量下 = 还原 OpenGL"
echo " 10 秒无按键自动退出"
echo "=============================="

tmpf=/data/local/tmp/fuyun_vk_key.txt
rm -f "$tmpf"
choice=

if command -v getevent >/dev/null 2>&1; then
    # 读多个事件覆盖 DOWN+UP 事件对; 收到按键立即退出, 10 秒无按键自动超时
    getevent -qlc 8 >"$tmpf" 2>/dev/null &
    gpid=$!
    waited=0
    while [ "$waited" -lt 20 ]; do
        grep -qE 'KEY_VOLUME(UP|DOWN).*DOWN' "$tmpf" 2>/dev/null && break
        kill -0 "$gpid" 2>/dev/null || break
        sleep 0.5
        waited=$((waited + 1))
    done
    kill "$gpid" 2>/dev/null
    choice=$(read_key "$tmpf")
fi
rm -f "$tmpf"

case "$choice" in
    KEY_VOLUMEUP)
        vulkan_on
        ;;
    KEY_VOLUMEDOWN)
        vulkan_off
        ;;
    *)
        echo " "
        echo "未检测到按键，未更改"
        if [ -f "$STATE_FILE" ]; then
            cur=$(cat "$STATE_FILE" 2>/dev/null)
            if [ "$cur" = "1" ]; then
                echo "当前状态: Vulkan"
            else
                echo "当前状态: OpenGL"
            fi
        fi
        echo " "
        ;;
esac
