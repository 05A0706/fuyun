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

# MR author: railjty
USER_PATH=/sdcard/Android/yc/uperf

wait_until_login() {
    # in case of /data encryption is disabled
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 1
    done

    # we doesn't have the permission to rw "/sdcard" before the user unlocks the screen
    local test_file="/sdcard/Android/.PERMISSION_TEST"
    true >"$test_file"
    while [ ! -f "$test_file" ]; do
        true >"$test_file"
        sleep 1
    done
    rm "$test_file"
}

on_remove() {
    wait_until_login

    # 模块目录 (由管理器传入; KernelSU/Magisk 卸载时均有定义, 兜底到默认路径)
    MODDIR="${MODDIR:-/data/adb/modules/uperf}"

    # stop memctl & auxgov & webui services (按 PID 精确停止, 不误杀其他 httpd)
    pkill -f "script/memctl.sh" 2>/dev/null
    pkill -f "script/auxgov.sh" 2>/dev/null
    pkill -f "script/webuid.sh" 2>/dev/null
    # stop 场景自动化守护 (F2) 与 service.sh 看门狗 —— 防止卸载后残留进程
    # 继续轮询 dumpsys / 每 30s 尝试拉起已删除的脚本 (残留耗电 + 日志刷屏)
    pkill -f "script/automation.sh" 2>/dev/null
    pkill -f "$MODDIR/service.sh" 2>/dev/null
    if [ -f /data/local/tmp/webuid.pid ]; then
        kill "$(cat /data/local/tmp/webuid.pid)" 2>/dev/null
        rm -f /data/local/tmp/webuid.pid
    fi

    # stop corectl service & 恢复全部核心在线 (卸载前必须还原热插拔状态)
    pkill -f "script/corectl.sh" 2>/dev/null
    if [ -f "$MODDIR/script/corectl.sh" ]; then
        sh "$MODDIR/script/corectl.sh" clear 2>/dev/null
    elif [ -f /data/adb/modules/uperf/script/corectl.sh ]; then
        sh /data/adb/modules/uperf/script/corectl.sh clear 2>/dev/null
    fi

    # 还原被修改的 modem 网络配置 (5G/SA 优化曾改写过这些文件)
    # 全部还原成功才删除备份; 任一还原失败则保留备份, 避免原始配置永久丢失
    BACKUP_DIR=/data/adb/uperf_backup
    if [ -d "$BACKUP_DIR" ]; then
        RESTORE_OK=1
        if [ -f "$BACKUP_DIR/network_mode_vendor.xml" ]; then
            mount -o rw,remount /vendor 2>/dev/null
            cp -af "$BACKUP_DIR/network_mode_vendor.xml" /vendor/etc/modem/network_mode.xml 2>/dev/null || RESTORE_OK=0
        fi
        if [ -f "$BACKUP_DIR/network_mode_product.xml" ]; then
            mount -o rw,remount /product 2>/dev/null
            cp -af "$BACKUP_DIR/network_mode_product.xml" /product/etc/modem/network_mode.xml 2>/dev/null || RESTORE_OK=0
        fi
        if [ -f "$BACKUP_DIR/network_mode_system.xml" ]; then
            mount -o rw,remount /system 2>/dev/null
            cp -af "$BACKUP_DIR/network_mode_system.xml" /system/etc/modem/network_mode.xml 2>/dev/null || RESTORE_OK=0
        fi
        if [ "$RESTORE_OK" = "1" ]; then
            rm -rf "$BACKUP_DIR"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] modem 配置还原失败, 备份保留于 $BACKUP_DIR" >>/data/local/tmp/uperf_uninstall.log 2>/dev/null
        fi
    fi

    # keep user perapp config (判存在 + 引号, 避免文件缺失时报错)
    if [ -f "$USER_PATH/perapp_powermode.txt" ]; then
        cp -af "$USER_PATH/perapp_powermode.txt" /sdcard/ 2>/dev/null
    fi
    rm -rf "$USER_PATH"
    mkdir -p "$USER_PATH"
    if [ -f /sdcard/perapp_powermode.txt ]; then
        mv /sdcard/perapp_powermode.txt "$USER_PATH/" 2>/dev/null
    fi

    rm -f /data/powercfg*
}

# do not block boot
(on_remove &)
