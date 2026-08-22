#!/system/bin/sh
#
# customize.sh - KernelSU 原生安装脚本
#
# KernelSU 安装模块时优先执行本脚本 (zip 内存在 customize.sh 时),
# 不再走 Magisk update-binary 兼容流程 (该流程在 KernelSU 下易出问题)。
# Magisk 安装时忽略本脚本, 仍走 META-INF/update-binary 标准流程。
#
# KernelSU 环境变量:
#   KSU=true, MODPATH=模块安装路径, 当前工作目录=zip 解压目录

# 非 KernelSU 环境直接退出 (Magisk 走 META-INF 流程)
[ "$KSU" = "true" ] || exit 0

ui_print() { echo "$1"; }

# 当前工作目录 = zip 解压目录, 先于任何使用处定义
SRC=$(pwd)

MODID=$(grep -E '^id=' "$SRC/module.prop" 2>/dev/null | cut -d= -f2)
[ -n "$MODID" ] || MODID=uperf
[ -n "$MODPATH" ] || MODPATH="/data/adb/modules/$MODID"

ui_print "******************************"
ui_print " fuyun $(grep -E '^version=' "$SRC/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2)"
ui_print " KernelSU native installer"
ui_print "******************************"

# 复制模块文件到模块目录 (排除 META-INF 与 customize.sh 自身)
if [ ! -f "$SRC/module.prop" ]; then
    ui_print "! Cannot locate module files, abort."
    exit 1
fi
mkdir -p "$MODPATH"
for f in "$SRC"/*; do
    name=$(basename "$f")
    case "$name" in
        META-INF|customize.sh) continue ;;
    esac
    cp -af "$f" "$MODPATH/"
done

# 交给 setup.sh 完成平台配置复制与权限设置
# (KernelSU 环境下 setup.sh 自动跳过音量键交互)
ui_print "- Running module installer"
if ! sh "$MODPATH/script/setup.sh"; then
    ui_print "! setup.sh failed"
    exit 1
fi

ui_print "- Done"
exit 0
