#!/system/bin/sh
#
# customize.sh - 模块安装脚本 (KernelSU 原生 / Magisk v23+ 通用)
#
# KernelSU: KSU=true, zip 解压到当前工作目录, 需要自行复制到 MODPATH
# Magisk:   文件已由 Magisk 解压到 MODPATH, customize.sh 存在时优先于
#           update-binary 执行 (旧版 Magisk 仍走 META-INF/update-binary)
#
# 两种环境统一交给 setup.sh 完成配置复制与权限设置。
#

ui_print() { echo "$1"; }

MODID=$(grep -E '^id=' "$MODPATH/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2)
[ -n "$MODID" ] || MODID=$(grep -E '^id=' module.prop 2>/dev/null | cut -d= -f2)
[ -n "$MODID" ] || MODID=uperf
[ -n "$MODPATH" ] || MODPATH="/data/adb/modules/$MODID"

SRC=$(pwd)

ui_print "******************************"
ui_print " fuyun $(grep -E '^version=' "$MODPATH/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2)"
ui_print " module installer (KSU/Magisk)"
ui_print "******************************"

# 复制模块文件到模块目录 (排除 META-INF 与 customize.sh 自身)
copy_files() {
    local src="$1" dst="$2"
    mkdir -p "$dst"
    for f in "$src"/*; do
        name=$(basename "$f")
        case "$name" in
            META-INF|customize.sh) continue ;;
        esac
        cp -af "$f" "$dst/"
    done
}

if [ "$KSU" = "true" ]; then
    # KernelSU: 当前目录即 zip 解压目录
    [ -f "$SRC/module.prop" ] || { ui_print "! Cannot locate module files, abort."; exit 1; }
    copy_files "$SRC" "$MODPATH"
elif [ ! -f "$MODPATH/module.prop" ]; then
    # Magisk 兜底: 正常情况文件已解压到 MODPATH, 缺失时才从当前目录复制
    if [ -f "$SRC/module.prop" ]; then
        copy_files "$SRC" "$MODPATH"
    else
        ui_print "! Cannot locate module files, abort."
        exit 1
    fi
fi

ui_print "- Running module installer"
if ! sh "$MODPATH/script/setup.sh"; then
    ui_print "! setup.sh failed"
    exit 1
fi

# setup.sh 未覆盖的根级脚本权限 (防 zip 权限丢失导致 action.sh 无法执行)
chmod 755 "$MODPATH/action.sh" "$MODPATH/install.sh" "$MODPATH/uninstall.sh" 2>/dev/null

ui_print "- Done"
exit 0
