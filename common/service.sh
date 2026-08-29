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

# MODROOT: 模块根目录 (含 script/ 子目录)。
# 仓库内 service.sh 位于 common/, 但 Magisk 部署时位于模块根;
# 两种布局都正确解析: 优先 BASEDIR/script, 否则取父目录。
if [ -d "$BASEDIR/script" ]; then
    MODROOT="$BASEDIR"
elif [ -d "$(dirname "$BASEDIR")/script" ]; then
    MODROOT="$(dirname "$BASEDIR")"
else
    MODROOT="$BASEDIR"
fi

# F8: 复用 libcommon 的统一日志轮转
if [ -f "$MODROOT/script/libcommon.sh" ]; then
    . "$MODROOT/script/libcommon.sh"
fi

# 抓取开机崩溃日志, 只终止自己启动的 logcat 实例
# 仅在 post-fs-data.sh 判定上次开机异常 (留下 flag/need_crashlog) 时才抓日志,
# 正常开机不再无条件跑 60 秒 logcat 并往模块目录写全量日志。
crash_recuser() {
    rm -f "$BASEDIR/logcat.log"
    if [ -f "$BASEDIR/flag/need_crashlog" ]; then
        logcat -f "$BASEDIR/logcat.log" &
        local lg_pid=$!
        sleep 60
        kill "$lg_pid" 2>/dev/null
        rm -f "$BASEDIR/flag/need_crashlog"
    fi
    rm -f "$BASEDIR/flag/need_recuser"
}

(crash_recuser &)
sh $BASEDIR/script/initsvc.sh

# 内存优化服务: 通用后台回收 + 推送应用进程清理
# 配置: /sdcard/Android/yc/uperf/fuyun.conf ([mem] 分区)
# 白名单: /sdcard/Android/yc/uperf/mem_whitelist.txt
sh "$BASEDIR/script/memctl.sh" &

# 辅助调速器: 深度空闲联动关核 (独立守护, 见 auxgov.sh)
sh "$BASEDIR/script/auxgov.sh" &

# 场景自动化规则引擎 (F2): 按充电/电量/时段/屏幕触发策略, 与 perapp 维度互补
sh "$BASEDIR/script/automation.sh" &

# 核心开关服务: 用户配置关/开核心, 替代旧的"冻结式压频"(已删除)
# 配置: /sdcard/Android/yc/uperf/fuyun.conf ([corectl] 分区)
sh "$BASEDIR/script/corectl.sh" watch &

# 第三方插件 boot 阶段 (插件放在 /sdcard/Android/yc/uperf/plugins/, 后台执行不阻塞开机)
if [ -f "$BASEDIR/script/plugin.sh" ]; then
    MODDIR="$BASEDIR"
    . "$BASEDIR/script/plugin.sh"
    run_plugins boot &
fi

# WebUI 控制台 (http://127.0.0.1:16800, Magisk/KernelSU 模块详情页有入口)
sh "$BASEDIR/script/webuid.sh" start

# ============ F8: 进程看门狗 ============
# 监督 memctl / auxgov / corectl(watch) 子进程, 异常退出自动拉起并记录原因,
# 使模块更"自愈": 守护进程崩溃后调度不再静默失效。
watchdog() {
    local wlog="$USER_PATH/watchdog.log.txt" sz
    while true; do
        if ! pgrep -f "script/memctl.sh" >/dev/null 2>&1; then
            echo "[$(date '+%m-%d %H:%M:%S')] watchdog: memctl 未在运行, 拉起" >>"$wlog"
            sh "$MODROOT/script/memctl.sh" >/dev/null 2>&1 &
        fi
        if ! pgrep -f "script/auxgov.sh" >/dev/null 2>&1; then
            echo "[$(date '+%m-%d %H:%M:%S')] watchdog: auxgov 未在运行, 拉起" >>"$wlog"
            sh "$MODROOT/script/auxgov.sh" >/dev/null 2>&1 &
        fi
        if ! pgrep -f "corectl.sh watch" >/dev/null 2>&1; then
            echo "[$(date '+%m-%d %H:%M:%S')] watchdog: corectl(watch) 未在运行, 拉起" >>"$wlog"
            sh "$MODROOT/script/corectl.sh" watch >/dev/null 2>&1 &
        fi
        sz=$(stat -c %s "$wlog" 2>/dev/null)
        [ "${sz:-0}" -gt 1048576 ] 2>/dev/null && { mv -f "$wlog" "$wlog.old"; : >"$wlog"; }
        sleep 30
    done
}
(watchdog &)

# ============ 息屏待机 ============
#
# 旧的"息屏压频"(关大核 + 冻结 scaling_max_freq + 切 powersave) 与"频率压制"
# (freq_limit.sh 的 bind-mount 冻结上限) 均已移除。省电主杠杆改为"关核心":
#   - 用户可在 fuyun.conf [corectl] 分区配置常态关大核/中核数量, 以及在息屏时额外关核;
#   - 辅助调速器 auxgov.sh 进入深度空闲时联动 corectl.sh 关大核, 退出即恢复。
# 两种关核都由 corectl.sh 统一执行, 且遵守"绝不关 cpu0 / 每簇至少留 1 核 / 小核常在线"。
# 本脚本不再直接写 scaling_max_freq / governor, 也不再 2s 轮询 dumpsys power,
# 息屏关核改由 corectl.sh 的 watch 循环按屏幕状态自行处理。
# 这里仅保留息屏 Doze 白名单应用 (仅豁免, 不干预应用)。
#
# 注: 旧的 screen_saver.txt / choose_screen_saver 配置接口已删除 (无对应功能)。

# 配置参数
USER_PATH=/sdcard/Android/yc/uperf
# 26w34.6-B: Doze 白名单合并进 whitelist.txt [doze] 分区
DOZE_WL_FILE="$USER_PATH/whitelist.txt"
LOG_FILE="$USER_PATH/screen_log.txt"
LOG_TAG="DeepPowerSaver"
ENABLE_LOGGING=1 # 设置为0禁用日志

# 等待系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 10
done

# 额外等待时间确保系统服务就绪
sleep 30

# 确保日志目录存在
mkdir -p "$USER_PATH"
chmod 755 "$USER_PATH"

# 旧版多配置文件迁移 (26w34.6-B 第四轮): 幂等, 存在旧文件时自动合并到 fuyun.conf / whitelist.txt
migrate_legacy "$USER_PATH"

# 初始化日志文件
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DeepPowerSaver 服务启动 (息屏省电由 corectl.sh 关核 + auxgov.sh 空闲降频承担)" >"$LOG_FILE"
chmod 644 "$LOG_FILE"

# 日志函数 (函数名不用 log, 避免遮蔽系统 log 命令导致无限递归)
log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"

    # 输出到logcat (使用完整路径, 防止再被同名函数遮蔽)
    [ "$ENABLE_LOGGING" = "1" ] && /system/bin/log -p i -t "$LOG_TAG" "$1"

    # 输出到文件
    echo "$msg" >>"$LOG_FILE"

    # 限制日志大小（最大1MB, 轮转保留一份 .old）
    rotate_log "$LOG_FILE"
}

# 应用Doze白名单 (开机执行一次, 仅豁免不杀应用; 系统原生 Doze 时推送不受影响)
apply_doze_whitelist() {
    [ -f "$DOZE_WL_FILE" ] || { log_msg "whitelist.txt 不存在, 跳过"; return 0; }
    log_msg "应用Doze白名单..."
    local packages
    # 一次取回已安装包列表, 避免每个白名单包跑一次 pm list packages (每次都是一次 binder 调用)
    packages=$(pm list packages 2>/dev/null)
    while read -r package; do
        # 跳过空行和注释
        package=$(echo "$package" | sed 's/#.*//' | xargs)
        [ -z "$package" ] && continue

        # 检查应用是否存在 (精确匹配, 避免 com.tencent.mm 误匹配子包)
        if printf '%s\n' "$packages" | grep -q "^package:$package$"; then
            # 应用加入电池优化白名单
            dumpsys deviceidle whitelist +"$package"
            log_msg "  已添加白名单: $package"
        else
            log_msg "  应用不存在: $package"
        fi
    done <<EOF
$(section_body "$DOZE_WL_FILE" doze)
EOF
}

log_msg "设备信息: $(getprop ro.product.model) | Android $(getprop ro.build.version.release)"
log_msg "日志文件: $LOG_FILE"
log_msg "白名单文件: $DOZE_WHITELIST"

# 初始白名单应用 (仅一次, 不杀应用)
apply_doze_whitelist

log_msg "Doze 白名单应用完毕, 服务退出"
