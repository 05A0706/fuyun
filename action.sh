#!/system/bin/sh
# Credit @tryigitx
if [[ $(getprop ro.build.version.sdk) -lt 34 ]]; then
    resetprop debug.hwui.renderer skiavk
fi

# Vip Features -If you do not have a VIP driver, it may also cause instability during bootup.-
resetprop ro.hwui.use_vulkan true

echo " "
echo "Vulkan 已重新激活"
echo " "