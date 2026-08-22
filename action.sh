#!/system/bin/sh
# fuyun action: 音量上 = 开启 Vulkan, 音量下 = 还原 OpenGL
# 状态持久化到 /data/adb/uperf/vulkan.state, 开机由 post-fs-data.sh 按状态应用

STATE_DIR=/data/adb/uperf
STATE_FILE="$STATE_DIR/vulkan.state"
USER_STATE=/sdcard/Android/yc/uperf/vulkan.state

mkdir -p "$STATE_DIR" 2>/dev/null
mkdir -p /sdcard/Android/yc/uperf 2>/dev/null

vulkan_on() {
    resetprop ro.hwui.use_vulkan true
    resetprop debug.hwui.renderer skiavk
    resetprop debug.renderengine.backend skiavkthreaded
    resetprop debug.renderengine.vulkan true
    resetprop debug.renderengine.graphite true
    resetprop debug.egl.hw 1
    echo 1 >"$STATE_FILE" 2>/dev/null
    echo 1 >"$USER_STATE" 2>/dev/null
    echo " "
    echo "Vulkan 已开启"
    echo " "
}

vulkan_off() {
    resetprop ro.hwui.use_vulkan false
    resetprop debug.hwui.renderer opengl
    resetprop debug.renderengine.backend threaded
    resetprop debug.renderengine.vulkan false
    resetprop debug.renderengine.graphite false
    resetprop debug.egl.hw 0
    echo 0 >"$STATE_FILE" 2>/dev/null
    echo 0 >"$USER_STATE" 2>/dev/null
    echo " "
    echo "已还原 OpenGL"
    echo " "
}

echo "=============================="
echo " 音量上 = 开启 Vulkan"
echo " 音量下 = 还原 OpenGL"
echo " 10 秒无按键自动退出"
echo "=============================="

tmpf=/data/local/tmp/fuyun_vk_key.txt
rm -f "$tmpf"
getevent -qlc 1 >"$tmpf" 2>/dev/null &
gpid=$!
waited=0
while kill -0 "$gpid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
done
if kill -0 "$gpid" 2>/dev/null; then
    kill "$gpid" 2>/dev/null
    choice=""
else
    # 只认按下事件 (DOWN), 过滤抬手 (UP) 防止误判
    choice=$(awk '{ print $3, $4 }' "$tmpf" | grep 'KEY_' | awk '$2 == "DOWN" || $2 == "" { print $1 }')
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
