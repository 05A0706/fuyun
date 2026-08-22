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

MODDIR=${0%/*}

if [ -f "$MODDIR/flag/need_recuser" ]; then
    rm -f $MODDIR/flag/need_recuser
    true >$MODDIR/disable
else
    true >$MODDIR/flag/need_recuser
fi

# Vulkan / OpenGL 按持久化状态应用 (默认 Vulkan; action.sh 可切换)
mkdir -p /data/adb/uperf 2>/dev/null
VULKAN_STATE=/data/adb/uperf/vulkan.state
VULKAN_ON=1
if [ -f "$VULKAN_STATE" ]; then
    s=$(cat "$VULKAN_STATE" 2>/dev/null)
    [ "$s" = "0" ] && VULKAN_ON=0
fi
if [ "$VULKAN_ON" = "1" ]; then
    # Enable Vulkan (Credit @tryigitx, SDK<34 需要额外指定渲染后端)
    if [ "$(getprop ro.build.version.sdk)" -lt 34 ]; then
        resetprop debug.hwui.renderer skiavk
    fi
    resetprop ro.hwui.use_vulkan true
    resetprop debug.renderengine.backend skiavkthreaded
    resetprop debug.renderengine.vulkan true
    resetprop debug.renderengine.graphite true
    resetprop debug.egl.hw 1
else
    resetprop ro.hwui.use_vulkan false
    resetprop debug.hwui.renderer opengl
    resetprop debug.renderengine.backend threaded
    resetprop debug.renderengine.vulkan false
    resetprop debug.renderengine.graphite false
    resetprop debug.egl.hw 0
fi

# Vip Features -If you do not have a VIP driver, it may also cause instability during bootup.
lock_val() {
	for p in $2; do
		if [ -f "$p" ]; then
			chown root:root "$p"
			chmod 0666 "$p"
			echo "$1" >"$p"
			chmod 0444 "$p"
		fi
	done
}

#GPU Boost部分 (响应式: 只解锁最高档, 不锁最低档/不关节流, 待机时 GPU 自然降频省电)
init_node_qcom() {
	lock_val "0" /sys/class/kgsl/kgsl-3d0/max_pwrlevel
}
init_node_qcom

# 设置调试模式（可选）
# set -x

# 创建临时工作目录
TMPDIR=$(mktemp -d)

# 挂载可写分区
mount -o rw,remount /vendor 2>/dev/null
mount -o rw,remount /system 2>/dev/null
mount -o rw,remount /product 2>/dev/null

# 设置核心5G SA属性
setprop persist.vendor.radio.enable5g 1
setprop persist.vendor.radio.enable5g_sa 1
setprop persist.vendor.radio.nr_mode 1
setprop ro.vendor.radio.nr_mode 1

# 多平台兼容性设置
setprop persist.vendor.radio.enableadvancedmode true
# 修改网络配置文件（如果存在）—— 改前备份原始文件到 /data/adb/uperf_backup, 卸载时自动还原
BACKUP_DIR=/data/adb/uperf_backup
mkdir -p "$BACKUP_DIR" 2>/dev/null
NET_CONFIGS="/vendor/etc/modem/network_mode.xml
/product/etc/modem/network_mode.xml
/system/etc/modem/network_mode.xml"

for config in $NET_CONFIGS; do
    if [ -f "$config" ]; then
        # 确定备份文件名 (按来源路径区分)
        case "$config" in
            */vendor/*)  bf="$BACKUP_DIR/network_mode_vendor.xml" ;;
            */product/*) bf="$BACKUP_DIR/network_mode_product.xml" ;;
            *)           bf="$BACKUP_DIR/network_mode_system.xml" ;;
        esac
        # 仅首次修改前备份 (幂等, 不覆盖已有备份)
        [ -f "$bf" ] || cp -f "$config" "$bf"
        # 写回修改后的配置
        cp "$config" "$TMPDIR/network_mode.xml"
        sed -i 's/<NrMode>0<\/NrMode>/<NrMode>1<\/NrMode>/g' "$TMPDIR/network_mode.xml"
        sed -i 's/<NrMode>2<\/NrMode>/<NrMode>1<\/NrMode>/g' "$TMPDIR/network_mode.xml"
        cp "$TMPDIR/network_mode.xml" "$config"
        chmod 644 "$config"
    fi
done

# 强制SA优先模式
for slot in 0 1; do
    current_mode=$(getprop persist.vendor.radio.sim${slot}.network_mode)
    [ -z "$current_mode" ] && current_mode=$(getprop ro.telephony.default_network)
    
    case "$current_mode" in
        *sa*) ;;  # 已经是SA模式
        *nr*) ;; # 已经是NR模式
        *)
            # 设置为SA优先模式 (NR/LTE/GSM)
            new_mode=""
            if grep -qE 'ro.vendor.radio.nr_mode=1|nr_mode=1' /vendor/build.prop; then
                new_mode=63  # NR/LTE/GSM
            else
                new_mode=22  # LTE/WCDMA/GSM (兼容回退)
            fi
            setprop persist.vendor.radio.sim${slot}.network_mode $new_mode
            ;;
    esac
done

# 清理工作
rm -rf "$TMPDIR"
sync

# 息屏待机

# 设置系统属性
setprop debug.powersaver.enable 1
setprop debug.doze.aggressive 1

# 创建配置和日志目录
mkdir -p /sdcard/Android/yc/uperf
chmod 755 /sdcard/Android/yc/uperf

# 初始化白名单文件 (仅首次生成, 不覆盖用户修改过的白名单)
DOZE_WHITELIST="/sdcard/Android/yc/uperf/doze_whitelist.txt"

if [ ! -f "$DOZE_WHITELIST" ]; then
    # 默认推送应用白名单
    cat > "$DOZE_WHITELIST" <<EOF
com.tencent.mm # 微信
com.tencent.mobileqq # QQ
com.tencent.tim # Tim
com.coolapk.market # 酷安
com.android.mms # 短信
com.android.email # 邮件
com.google.android.apps.messaging # 谷歌fcm推送
com.android.cellbroadcastreceiver # 紧急广播
EOF
fi

# 设置权限
chmod 644 "$DOZE_WHITELIST"

# 创建初始日志文件
LOG_FILE="/sdcard/Android/yc/uperf/screen_log.txt"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 模块初始化完成" > $LOG_FILE
chmod 644 $LOG_FILE