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

# WebUI 控制台 (http://127.0.0.1:16800, Magisk/KernelSU 模块详情页有入口)
sh "$BASEDIR/script/webuid.sh" start

# 待机优化

# 等待系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 10
done

# 额外等待时间确保系统服务就绪
sleep 30

# 配置参数
SLEEP_INTERVAL=60
DOZE_WHITELIST="/sdcard/Android/yc/uperf/doze_whitelist.txt"
LOG_FILE="/sdcard/Android/yc/uperf/screen_log.txt"
BACKUP_FILE="/sdcard/Android/yc/uperf/screen_backup.txt"
LOG_TAG="DeepPowerSaver"
ENABLE_LOGGING=1 # 设置为0禁用日志

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

# 应用Doze白名单
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

# 优化CPU设置 - 息屏时关闭大核
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

# 启用深度Doze模式
enable_deep_doze() {
    log_msg "启用深度Doze模式..."
    # 强制进入Doze模式
    dumpsys deviceidle force-idle
    
    # 设置Doze参数（Android 15兼容）
    settings put global device_idle_constants \
        "inactive_to=30000,waiting_to=30000,idle_to=60000,sensing_to=0,locating_to=0"
    
    # 应用白名单
    apply_doze_whitelist
    
    # 启用系统省电模式
    cmd power set-mode 1
    
    log_msg "深度Doze模式已启用"
}

# 禁用深度Doze模式
disable_deep_doze() {
    log_msg "禁用深度Doze模式..."
    # 退出Doze模式
    dumpsys deviceidle unforce
    
    # 恢复默认Doze参数
    settings put global device_idle_constants ""
    
    # 禁用系统省电模式
    cmd power set-mode 0
    
    log_msg "深度Doze模式已禁用"
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
log_msg "深度省电服务已启动"
log_msg "设备信息: $(getprop ro.product.model) | Android $(getprop ro.build.version.release)"
log_msg "日志文件: $LOG_FILE"
log_msg "白名单文件: $DOZE_WHITELIST"

# 初始白名单应用
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
            restore_cpu_power
            disable_deep_doze
            LAST_SCREEN_STATE="on"
            log_msg "$(get_cpu_status)"
        fi
    else
        # 屏幕关闭
        if [ "$LAST_SCREEN_STATE" != "off" ]; then
            log_msg "检测到屏幕关闭"
            sleep 5 # 等待系统进入待机状态
            optimize_cpu_power
            enable_deep_doze
            LAST_SCREEN_STATE="off"
            log_msg "$(get_cpu_status)"
        fi
    fi
    
    sleep $SLEEP_INTERVAL
done