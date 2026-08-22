#!/system/bin/sh
#
# Copyright (C) 2021-2022 Matt Yang
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

BASEDIR="$(dirname $(readlink -f "$0"))"

# 初始化兜底: 覆盖未执行 setup.sh 的安装方式 (手动解压 zip 到模块目录/其他管理器等)
# 检测到关键配置缺失时, 后台静默补跑 setup.sh --silent:
#   不覆盖用户已有配置、不弹音量键交互、自动补齐权限 (busybox/cgi-bin 等)
if [ ! -f /sdcard/Android/yc/uperf/uperf.json ]; then
    (
        i=0
        while [ "$i" -lt 90 ]; do
            mkdir -p /sdcard/Android/yc/uperf 2>/dev/null
            if : >/sdcard/Android/yc/uperf/.init_test 2>/dev/null; then
                rm -f /sdcard/Android/yc/uperf/.init_test
                break
            fi
            sleep 2
            i=$((i + 1))
        done
        sh "$BASEDIR/script/setup.sh" --silent >/dev/null 2>&1
    ) &
fi

# 抓取开机崩溃日志, 只终止自己启动的 logcat 实例
crash_recuser() {
    rm -f "$BASEDIR/logcat.log"
    logcat -f "$BASEDIR/logcat.log" &
    local lg_pid=$!
    sleep 60
    kill "$lg_pid" 2>/dev/null
    rm -f "$BASEDIR/flag/need_recuser"
}

(crash_recuser &)
sh $BASEDIR/script/initsvc.sh

# 内存优化服务: 通用后台回收 + 推送应用进程清理
# 配置: /sdcard/Android/yc/uperf/mem_config.txt
# 白名单: /sdcard/Android/yc/uperf/mem_whitelist.txt
sh "$BASEDIR/script/memctl.sh" &

# 频率控制服务: 全局上限 + 小/中/大核 min/max (WebUI「频率限制」「CPU 频率范围」可改)
sh "$BASEDIR/script/freq_limit.sh" watch &

# 第三方插件 boot 阶段 (插件放在 /sdcard/Android/yc/uperf/plugins/, 后台执行不阻塞开机)
if [ -f "$BASEDIR/script/plugin.sh" ]; then
    MODDIR="$BASEDIR"
    . "$BASEDIR/script/plugin.sh"
    run_plugins boot &
fi

# WebUI 控制台 (http://127.0.0.1:16800, Magisk/KernelSU 模块详情页有入口)
sh "$BASEDIR/script/webuid.sh" start

# 待机优化 (息屏压频省电)

# 说明: 息屏只压 CPU 频率 (关大核 + 800MHz), 不干预应用 ——
#       不再强制 Doze / 开启系统省电模式 (会限制冻结后台应用即"息屏杀应用")。
#       息屏应用冻结/清理交给墓碑类专用模块 (本模块不集成);
#       频率限制的「息屏自动限频」可替代本段压频 (WebUI 可配)。

# 等待系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 10
done

# 额外等待时间确保系统服务就绪
sleep 30

# 配置参数
SLEEP_INTERVAL=60
USER_PATH=/sdcard/Android/yc/uperf
DOZE_WHITELIST="$USER_PATH/doze_whitelist.txt"
LOG_FILE="$USER_PATH/screen_log.txt"
BACKUP_FILE="$USER_PATH/screen_backup.txt"
LOG_TAG="DeepPowerSaver"
ENABLE_LOGGING=1 # 设置为0禁用日志

# 息屏压频开关 (安装时选择: 音量上=开启 音量下=关闭; KernelSU 默认开启; 可手动改文件)
SCREEN_SAVER=1
SCREEN_SAVER_CFG=$(grep "^SCREEN_SAVER=" "$USER_PATH/screen_saver.txt" 2>/dev/null | head -n 1 | cut -d= -f2)
[ -n "$SCREEN_SAVER_CFG" ] && SCREEN_SAVER=$SCREEN_SAVER_CFG
case "$SCREEN_SAVER" in 0|1) ;; *) SCREEN_SAVER=1 ;; esac

# 确保日志目录存在
mkdir -p /sdcard/Android/yc/uperf
chmod 755 /sdcard/Android/yc/uperf

# 初始化日志文件
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DeepPowerSaver 服务启动" > $LOG_FILE
chmod 644 $LOG_FILE

# 日志函数 (函数名不用 log, 避免遮蔽系统 log 命令导致无限递归)
log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"

    # 输出到logcat (使用完整路径, 防止再被同名函数遮蔽)
    [ "$ENABLE_LOGGING" = "1" ] && /system/bin/log -p i -t "$LOG_TAG" "$1"

    # 输出到文件
    echo "$msg" >> $LOG_FILE

    # 限制日志大小（最大1MB）
    log_size=$(stat -c %s $LOG_FILE 2>/dev/null)
    [ "$log_size" -gt 1048576 ] && {
        mv $LOG_FILE $LOG_FILE.old
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志文件轮转" > $LOG_FILE
    }
}

# 获取屏幕状态 (双判断, 兼容不同版本 dumpsys 输出)
is_screen_on() {
    dumpsys power 2>/dev/null | grep -qE "mWakefulness=Awake|mHoldingDisplaySuspendBlocker=true"
}

# 应用Doze白名单 (开机执行一次, 仅豁免不杀应用; 系统原生 Doze 时推送不受影响)
apply_doze_whitelist() {
    log_msg "应用Doze白名单..."
    while read -r package; do
        # 跳过空行和注释
        package=$(echo "$package" | sed 's/#.*//' | xargs)
        [ -z "$package" ] && continue
        
        # 检查应用是否存在 (精确匹配, 避免 com.tencent.mm 误匹配子包)
        if pm list packages | grep -q "^package:$package$"; then
            # 应用加入电池优化白名单
            dumpsys deviceidle whitelist +"$package"
            log_msg "  已添加白名单: $package"
        else
            log_msg "  应用不存在: $package"
        fi
    done < "$DOZE_WHITELIST"
}

# 优化CPU设置 - 息屏时关闭大核 (仅频率/核心, 不干预应用)
optimize_cpu_power() {
    log_msg "优化CPU设置 - 关闭大核心..."
    # 获取CPU核心信息
    CPU_CORES=$(ls /sys/devices/system/cpu/ | grep 'cpu[0-9]\+')
    BIG_CORES=""
    
    # 检测大核心（假设大核频率 > 1.5GHz）
    for core in $CPU_CORES; do
        if [ -f "/sys/devices/system/cpu/$core/cpufreq/cpuinfo_max_freq" ]; then
            max_freq=$(cat "/sys/devices/system/cpu/$core/cpufreq/cpuinfo_max_freq")
            if [ "$max_freq" -gt 1500000 ]; then
                BIG_CORES="$BIG_CORES $core"
            fi
        fi
    done
    
    # 关闭大核心
    for core in $BIG_CORES; do
        if [ -f "/sys/devices/system/cpu/$core/online" ]; then
            echo 0 > "/sys/devices/system/cpu/$core/online"
            log_msg "  关闭核心: $core"
        fi
    done
    
    # 设置CPU调度参数
    # 先备份原始 governor, 亮屏时按备份还原 (不再硬编码 schedutil 覆盖用户配置)
    : > "$BACKUP_FILE"
    for policy in $(ls /sys/devices/system/cpu/cpufreq/ | grep 'policy[0-9]'); do
        if [ -f "/sys/devices/system/cpu/cpufreq/$policy/scaling_governor" ]; then
            echo "$policy $(cat "/sys/devices/system/cpu/cpufreq/$policy/scaling_governor")" >> "$BACKUP_FILE"
            echo powersave > "/sys/devices/system/cpu/cpufreq/$policy/scaling_governor"
            log_msg "  设置调度器: $policy → powersave"
        fi
        if [ -f "/sys/devices/system/cpu/cpufreq/$policy/scaling_max_freq" ]; then
            echo "800000" > "/sys/devices/system/cpu/cpufreq/$policy/scaling_max_freq"
            log_msg "  设置最大频率: $policy → 800MHz"
        fi
    done
}

# 恢复CPU设置 - 亮屏时恢复
restore_cpu_power() {
    log_msg "恢复CPU设置 - 启用所有核心..."
    # 重新启用所有CPU核心
    for core in $(ls /sys/devices/system/cpu/ | grep 'cpu[0-9]\+'); do
        if [ -f "/sys/devices/system/cpu/$core/online" ]; then
            echo 1 > "/sys/devices/system/cpu/$core/online"
            log_msg "  启用核心: $core"
        fi
    done
    
    # 恢复CPU调度参数 (优先从备份还原原始 governor)
    if [ -f "$BACKUP_FILE" ]; then
        while read -r policy gov; do
            [ -n "$gov" ] || continue
            if [ -f "/sys/devices/system/cpu/cpufreq/$policy/scaling_governor" ]; then
                echo "$gov" > "/sys/devices/system/cpu/cpufreq/$policy/scaling_governor"
                log_msg "  恢复调度器: $policy → $gov"
            fi
        done < "$BACKUP_FILE"
    else
        # 无备份文件(旧版本升级残留场景): 回退默认调度器
        for policy in $(ls /sys/devices/system/cpu/cpufreq/ | grep 'policy[0-9]'); do
            if [ -f "/sys/devices/system/cpu/cpufreq/$policy/scaling_governor" ]; then
                echo schedutil > "/sys/devices/system/cpu/cpufreq/$policy/scaling_governor"
                log_msg "  恢复调度器: $policy → schedutil"
            fi
        done
    fi

    # 恢复原始最大频率 (所有 policy)
    for policy in $(ls /sys/devices/system/cpu/cpufreq/ | grep 'policy[0-9]'); do
        if [ -f "/sys/devices/system/cpu/cpufreq/$policy/scaling_max_freq" ]; then
            if [ -f "/sys/devices/system/cpu/cpufreq/$policy/cpuinfo_max_freq" ]; then
                max_freq=$(cat "/sys/devices/system/cpu/cpufreq/$policy/cpuinfo_max_freq")
                echo "$max_freq" > "/sys/devices/system/cpu/cpufreq/$policy/scaling_max_freq"
                log_msg "  恢复最大频率: $policy → $((max_freq/1000))MHz"
            fi
        fi
    done
}

# 获取CPU状态信息
get_cpu_status() {
    local status="CPU状态: "
    for core in $(ls /sys/devices/system/cpu/ | grep 'cpu[0-9]\+'); do
        if [ -f "/sys/devices/system/cpu/$core/online" ]; then
            state=$(cat "/sys/devices/system/cpu/$core/online")
            status="${status}CPU${core:3}:$state "
        fi
    done
    echo "$status"
}

# 主服务循环
log_msg "深度省电服务已启动 (息屏压频: $([ "$SCREEN_SAVER" = "1" ] && echo 开 || echo 关))"
log_msg "设备信息: $(getprop ro.product.model) | Android $(getprop ro.build.version.release)"
log_msg "日志文件: $LOG_FILE"
log_msg "白名单文件: $DOZE_WHITELIST"

# 初始白名单应用 (仅一次, 不杀应用)
apply_doze_whitelist

LAST_SCREEN_STATE="on"

# 初始状态记录
if is_screen_on; then
    log_msg "当前屏幕状态: 亮屏"
else
    log_msg "当前屏幕状态: 息屏"
fi
log_msg "$(get_cpu_status)"

while true; do
    if is_screen_on; then
        # 屏幕亮起
        if [ "$LAST_SCREEN_STATE" != "on" ]; then
            log_msg "检测到屏幕亮起"
            [ "$SCREEN_SAVER" = "1" ] && restore_cpu_power
            LAST_SCREEN_STATE="on"
            log_msg "$(get_cpu_status)"
        fi
    else
        # 屏幕关闭
        if [ "$LAST_SCREEN_STATE" != "off" ]; then
            log_msg "检测到屏幕关闭"
            sleep 5 # 等待系统进入待机状态
            [ "$SCREEN_SAVER" = "1" ] && optimize_cpu_power
            LAST_SCREEN_STATE="off"
            log_msg "$(get_cpu_status)"
        fi
    fi
    
    sleep $SLEEP_INTERVAL
done