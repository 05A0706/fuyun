#!/system/bin/sh
#
# Copyright (C) 2021-2022 Matt Yang
#
# Licensed under the Apache License, Version 2.0 (the License);
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an AS IS BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

BASEDIR=$(dirname $(readlink -f $0))
. $BASEDIR/pathinfo.sh
. $BASEDIR/libsysinfo.sh

# grep_prop 由 Magisk util_functions 提供, KernelSU 环境不存在时自备兼容实现
type grep_prop >/dev/null 2>&1 || grep_prop() {
    grep "^$1=" "$2" 2>/dev/null | head -n 1 | cut -d= -f2
}

# $1:error_message
abort() {
    echo "$1" >&2
    echo "! Uperf installation failed." >&2
    exit 1
}

# $1:file_node $2:owner $3:group $4:permission $5:secontext
set_perm() {
    chown $2:$3 $1
    chmod $4 $1
    chcon $5 $1
}

# $1:directory $2:owner $3:group $4:dir_permission $5:file_permission $6:secontext
set_perm_recursive() {
    find $1 -type d 2>/dev/null | while read dir; do
        set_perm $dir $2 $3 $4 $6
    done
    find $1 -type f -o -type l 2>/dev/null | while read file; do
        set_perm $file $2 $3 $5 $6
    done
}

install_uperf() {
    echo "- Finding platform specified config"
    echo "- ro.board.platform=$(getprop ro.board.platform)"
    echo "- ro.product.board=$(getprop ro.product.board)"

    local target
    local cfgname
    target=$(getprop ro.board.platform)
    cfgname=$(get_config_name "$target")
    if [ "$cfgname" = "unsupported" ]; then
        target=$(getprop ro.product.board)
        cfgname=$(get_config_name "$target")
    fi

    if [ "$cfgname" = "unsupported" ] || [ ! -f "$MODULE_PATH/config/$cfgname.json" ]; then
        abort "Target [$target] not supported."
    fi

    echo "- Uperf config is located at $USER_PATH"
    mkdir -p "$USER_PATH"
    [ -f "$USER_PATH/uperf.json" ] && mv -f "$USER_PATH/uperf.json" "$USER_PATH/uperf.json.bak"
    cp -f "$MODULE_PATH/config/$cfgname.json" "$USER_PATH/uperf.json"
    [ ! -e $USER_PATH/perapp_powermode.txt ] && cp $MODULE_PATH/config/perapp_powermode.txt $USER_PATH/perapp_powermode.txt
    [ ! -e $USER_PATH/mem_config.txt ] && cp $MODULE_PATH/config/mem_config.txt $USER_PATH/mem_config.txt
    [ ! -e $USER_PATH/mem_whitelist.txt ] && cp $MODULE_PATH/config/mem_whitelist.txt $USER_PATH/mem_whitelist.txt
    [ ! -e $USER_PATH/mem_apps.txt ] && cp $MODULE_PATH/config/mem_apps.txt $USER_PATH/mem_apps.txt
    [ ! -e $USER_PATH/idle_gov.txt ] && cp $MODULE_PATH/config/idle_gov.txt $USER_PATH/idle_gov.txt
    [ ! -e $USER_PATH/idle_whitelist.txt ] && cp $MODULE_PATH/config/idle_whitelist.txt $USER_PATH/idle_whitelist.txt
    [ ! -e $USER_PATH/freq_limit.txt ] && cp $MODULE_PATH/config/freq_limit.txt $USER_PATH/freq_limit.txt
    rm -rf $MODULE_PATH/config

    set_perm_recursive $BIN_PATH 0 0 0755 0755 u:object_r:system_file:s0
}

# 息屏省电策略选择 (安装时询问; 升级时保留用户已有选择; 可事后改 screen_saver.txt)
# 说明: 息屏只压 CPU 频率 (关大核+800MHz), 不干预应用 (无 force-idle/省电模式)
choose_screen_saver() {
    [ -f "$USER_PATH/screen_saver.txt" ] && return 0 # 升级保留用户选择
    local choice= tmpf gpid waited
    echo "---"
    echo "息屏省电压频 (不杀应用, 息屏关大核+800MHz):"
    echo "  音量上 = 开启 (推荐, 墓碑冻结应用+本模块压频)"
    echo "  音量下 = 关闭 (息屏完全交给系统/墓碑)"
    echo "  10 秒无按键默认开启"
    if [ "$KSU" = "true" ]; then
        echo "KernelSU 环境, 默认开启"
        echo "SCREEN_SAVER=1" >"$USER_PATH/screen_saver.txt"
        return 0
    fi
    # getevent 阻塞式等待按键: 放后台 + 主循环限时 10 秒, 超时默认开启
    # (直接轮询时间戳会因 getevent 阻塞而永远轮不到; getevent 失败也会走超时兜底)
    tmpf="${TMPDIR:-/data/local/tmp}/fuyun_key.txt"
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
        # 只认按下事件 (DOWN), 过滤抬手 (UP) 防止把刚按过音量上的抬起误当选择
        choice=$(awk '{ print $3, $4 }' "$tmpf" | grep 'KEY_' | awk '$2 == "DOWN" || $2 == "" { print $1 }')
    fi
    rm -f "$tmpf"
    case "$choice" in
        KEY_VOLUMEDOWN)
            echo "息屏压频: 关闭"
            echo "SCREEN_SAVER=0" >"$USER_PATH/screen_saver.txt"
            ;;
        *)
            echo "息屏压频: 开启"
            echo "SCREEN_SAVER=1" >"$USER_PATH/screen_saver.txt"
            ;;
    esac
}
## fuck OpenGL!
echo --- ---- --- --- --- --- --- --- ---
echo "浮云 26w34.5-B"
sleep 1
echo "此调度四改自yc9559、李诗雅和NekoNemo"
sleep 1
echo "原版Uperf开源地址* https://github.com/yc9559/uperf/ 感谢yc大佬的奠基！"
sleep 0.5
echo "感谢coolapk@NekoNemo为调度打下坚固的基础！"
echo "调度不适配请及时联系本作者  反馈酷安@洗碗河没有地铁 QQ群1098223606"
echo "有任何bug问题以及偏见"
echo "马上甩群里"
echo "作者第一时间处理"
echo "认真看更新日志"
echo "认真看更新日志"
echo "认真看更新日志"
echo "--- ---- --- --- --- --- --- --- ---"
sleep 0.2
echo "更新日志
- 新增频率限制 (WebUI 可切换, 保留动态频率)
- 优化sdm8+和sdm8g2在各模式的核心分配
- WebUI 新增高级设置与 Doze 白名单管理
- 全部模式禁用 GPU Boost
- memctl 优化与稳定性修复"
echo "--- ---- --- --- --- --- --- --- ---"
# KernelSU 安装无终端按键环境 (getevent 拿不到按键会死循环), 直接安装
if [ "$KSU" = "true" ]; then
    echo "KernelSU 环境, 跳过按键确认"
    install_uperf
    choose_screen_saver
else
    echo "这是一个beta更新 稳定性未知，请谨慎安装"
    echo "按音量上继续 音量下退出"
    choice=
    while [ $choice =  ]; do
           choice=$(getevent -qlc 1 2>/dev/null | awk '{ print $3 }' | grep 'KEY_')
          sleep 0.2
    done
    case $choice in
        KEY_POWER)
            echo "你取消了安装"
            exit 1
            ;;
        KEY_VOLUMEDOWN)
            echo "你取消了安装"
            exit 1
            ;;
        KEY_VOLUMEUP)
            echo "开始安装"
            install_uperf
            choose_screen_saver
            sleep 0.5
            echo "安装成功"
    ;;
    esac
fi

# 确保运行/执行权限 (zip 内权限可能不含 +x, 尤其 cgi-bin 需 httpd 直接执行)
chmod 755 "$MODULE_PATH"/bin/uperf "$MODULE_PATH"/bin/busybox/busybox \
    "$MODULE_PATH"/script/*.sh "$MODULE_PATH"/common/*.sh \
    "$MODULE_PATH"/webroot/cgi-bin/*.sh 2>/dev/null
# info
echo "添加Vulkan支持ing"
SOC=`getprop ro.soc.model`
MODVER=`grep_prop version $MODPATH/module.prop`
MODVERCODE=`grep_prop versionCode $MODPATH/module.prop`
echo " "
echo " - 检查系统兼容性..."
ROMV=`getprop ro.build.host`
if [ $ROMV != "xiaomi.eu" ]; then
echo " - Success"
else
echo " "
echo "❗ 不受支持的系统"
echo " "
fi
echo " "
echo " - 检查安卓版本..."
[ $(getprop ro.system.build.version.sdk) -lt 29 ] && echo "! Unsupported android version detected, please upgrade." && abort
echo " - 添加Vulkan完成"
echo " "
echo "窝补药补习啊！"
echo " "