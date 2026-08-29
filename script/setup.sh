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
    # 主配置 (fuyun.conf 三合一) 与白名单 (whitelist.txt 三合一) 首次安装复制
    [ ! -e $USER_PATH/fuyun.conf ] && cp $MODULE_PATH/config/fuyun.conf $USER_PATH/fuyun.conf
    [ ! -e $USER_PATH/whitelist.txt ] && cp $MODULE_PATH/config/whitelist.txt $USER_PATH/whitelist.txt
    [ ! -e $USER_PATH/perapp_powermode.txt ] && cp $MODULE_PATH/config/perapp_powermode.txt $USER_PATH/perapp_powermode.txt
    [ ! -e $USER_PATH/mem_apps.txt ] && cp $MODULE_PATH/config/mem_apps.txt $USER_PATH/mem_apps.txt
    rm -rf $MODULE_PATH/config

    set_perm_recursive $BIN_PATH 0 0 0755 0755 u:object_r:system_file:s0
}

# 息屏省电策略选择 (choose_screen_saver) 已删除: 旧版息屏压频接口无对应功能,
# 关核改由 fuyun.conf [corectl] 用户配置驱动 (见 script/corectl.sh)。
## fuck OpenGL!
echo --- ---- --- --- --- --- --- --- ---
echo "浮云新调度，新的开始 —— fuyun 0.2-rc1"
sleep 1
echo "此调度四改自yc9559、李诗雅和NekoNemo"
sleep 1
echo "原版Uperf开源地址* https://github.com/yc9559/uperf/ 感谢yc大佬的奠基！"
sleep 0.5
echo "感谢酷安@yc9559@NekoNemo 为调度打下坚固的基础！"
echo "感谢志愿者酷安@雾兮雨 为调度提供了大量测试和反馈"
echo "调度不适配请及时联系本作者  反馈酷安@洗碗河没有地铁 QQ群1098223606"
echo "有任何bug问题以及偏见"
echo "马上提出"
echo "作者第一时间处理"
echo "认真看更新日志"
echo "认真看更新日志"
echo "认真看更新日志"
echo "--- ---- --- --- --- --- --- --- ---"
sleep 0.2
echo "更新日志 —— 0.2-rc1 (里程碑)"
echo "【核心变更】告别频率压制，拥抱核心开关
- 移除全部频率压制: 删除 freq_limit.sh 及其配置, 不再绑载冻结限制 CPU 频率
- 新增核心开关(热插拔关核): corectl.sh 守护, 常态关大/中核、息屏额外关核、
  深度空闲联动关核; 安全约束: 绝不关 cpu0、小核始终在线、大/中核可整簇关闭

【模块化与架构优化】
- 辅助调速器独立成模块 auxgov.sh: 深度空闲联动关核, 退出自动恢复,
  修复深度参数残留(用户改过 uperf.json 也正确合并)
- 内存管理精简: memctl.sh 1000→637 行, am kill 替代 kill -9,
  支持 IDLE_KILL_MIN=0 跳过闲置计算, 回收即时响应
- 看门狗与日志拆分: 异常退出自动拉起, corectl/auxgov 日志独立轮转

【配置体系大升级】
- 配置文件合并 11→7: fuyun.conf([mem]/[idle_gov]/[corectl]) +
  whitelist.txt([mem]/[idle_gov]/[doze]), 旧文件自动迁移(.legacy 可回退)
- Ordinary/Expert 分级: 默认只显示高频项, 低频项折叠进专家区
- 配置预设: 均衡默认/日常省电/游戏性能/极速 一键应用, 支持自定义预设
- 统一配置校验与原子写入: 写前自动 .bak, uperf.json 括号平衡校验

【插件系统全面强化】
- WebUI 插件管理器: 列表/启停/删除/看日志, 插件目录迁移 root-only
- 配置插件(特调化): uperf.<名称>.json 一键应用(自动备份+重启 uperf)
- 内置示例插件演示阶段与环境变量

【机型特调扩充】
- 新增 8 Gen3(sdm8g3)/8 Elite(sdm8e)/8s Elite(sdm8e5),
  更新 sdm8+/sdm8g2 为资料版(games_moba/dynamic_boost 等)

【WebUI 功能与体验】
- 实时运行曲线(F4): Canvas 绘制大/中/小核频率+内存+温度
- 配置导入/导出与一键备份(F3): 带版本号 tar.gz, 防路径穿越
- 场景自动化规则引擎(F2): 充电/电量/时段/屏幕触发
- 重启 uperf 按钮/Vulkan 状态展示/分应用性能模式/日志增强/版本显示
- 安全加固: WebUI 令牌认证, 插件 command 直通取消, 路径逃逸校验

【修复与细节】
- 卸载残留/路径硬编码/CGI 校验与守护对齐/备份导入防御/健壮性提升/
  公共函数抽取/命名统一/文档文案清理"
echo "--- ---- --- --- --- --- --- --- ---"
# KernelSU 安装无终端按键环境 (getevent 拿不到按键会死循环), 直接安装
if [ "$KSU" = "true" ]; then
    echo "KernelSU 环境, 跳过按键确认"
    install_uperf
else
    echo "0.2-rc1 里程碑版本, 配置体系有破坏性变更(旧文件会自动迁移)"
    echo "按音量上继续 音量下退出"
    choice=
    while [ -z "$choice" ]; do
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
SDKV=$(getprop ro.system.build.version.sdk)
case "$SDKV" in ''|*[!0-9]*) SDKV=$(getprop ro.build.version.sdk) ;; esac
case "$SDKV" in
    ''|*[!0-9]*) abort "! Cannot read Android SDK version." ;;
    *) [ "$SDKV" -lt 29 ] && echo "! Unsupported android version detected (API $SDKV), please upgrade." && abort "! Android API level too low." ;;
esac
echo " - 添加Vulkan完成"
echo " "
echo "窝补药补习啊！"
echo " "