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

###############################
# Basic tool functions
###############################

# $1:value $2:filepaths
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

# $1:value $2:filepaths
mask_val() {
    touch /data/local/tmp/mount_mask
    for p in $2; do
        if [ -f "$p" ]; then
            umount "$p"
            chmod 0666 "$p"
            echo "$1" >"$p"
            mount --bind /data/local/tmp/mount_mask "$p"
        fi
    done
}

# $1:value $2:filepaths
mutate() {
    for p in $2; do
        if [ -f "$p" ]; then
            chmod 0666 "$p"
            echo "$1" >"$p"
        fi
    done
}

# $1:file path (supports glob patterns)
lock() {
    local p
    for p in $1; do
        if [ -f "$p" ]; then
            chown root:root "$p"
            chmod 0444 "$p"
        fi
    done
}

# $1:value $2:list
has_val_in_list() {
    for item in $2; do
        if [ "$1" = "$item" ]; then
            echo "true"
            return
        fi
    done
    echo "false"
}

###############################
# Foreground / Whitelist helpers
###############################

# 当前前台应用包名 (dumpsys 一次 binder 调用; 各守护脚本共用)
get_fg_pkg() {
    dumpsys activity activities 2>/dev/null |
        grep -oE '(ResumedActivity|topResumedActivity): [A-Za-z0-9_.]+' |
        awk '{print $NF}' | head -n 1
}

# 白名单规则从 stdin 读入内存: 精确包名与前缀通配分开存放, 供 case 直接匹配
# (26w34.6-B: 配合 section_body 管道读取分区, 如 section_body "$WL" mem | wl_rules exact)
# $1: exact(精确包名) | prefix(前缀通配)
wl_rules() {
    local kind="$1" line out=""
    while read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -n "$line" ] || continue
        case "$line" in
            *\*) [ "$kind" = "prefix" ] && out="$out ${line%\*}" ;;
            *)   [ "$kind" = "exact" ]  && out="$out $line" ;;
        esac
    done
    echo "$out"
}

# 精确列表/前缀列表命中判定: $1=精确列表 $2=前缀列表 $3=包名; 命中返回 0
wl_hit() {
    local pkg="$3" prefix
    [ -n "$pkg" ] || return 1
    case " $1 " in
        *" $pkg "*) return 0 ;;
    esac
    for prefix in $2; do
        case "$pkg" in
            "$prefix"*) return 0 ;;
        esac
    done
    return 1
}

###############################
# Config File Operator
###############################

# ===== 分区配置 (fuyun.conf / whitelist.txt) =====
# 格式: [section] 行 + 键值/列表行, 分区之间空行分隔, # 开头为注释

# 输出指定分区内容 (不含分区头; 含注释与空行)
# $1=文件 $2=分区名
section_body() {
    [ -f "$1" ] || return 0
    awk -v sec="$2" '
        $0 == "[" sec "]" { insec = 1; next }
        insec && $0 ~ /^\[/ { insec = 0 }
        insec { print }
    ' "$1" 2>/dev/null
}

# 在指定分区写入 key=value (保留注释与其余键, 原子替换)
# 分区不存在则自动创建; 已有同键则原位替换
# $1=文件 $2=分区 $3=key $4=value
set_section_kv() {
    local f="$1" s="$2" k="$3" v="$4" tmp
    tmp="$f.tmp"
    awk -v s="$s" -v k="$k" -v v="$v" '
    function flush_block(   i) {
        for (i = 1; i <= bn; i++) print buf[i]
        bn = 0
    }
    {
        if ($0 ~ /^\[/) {
            flush_block()
            # 离开目标分区时, 把新增键补在分区末尾 (先 flush 内容再补插)
            if (insec && !found) { print k "=" v; found = 1 }
            insec = ($0 == "[" s "]")
            print
            next
        }
        if (insec && !found && index($0, k "=") == 1) {
            print k "=" v
            found = 1
            next
        }
        buf[++bn] = $0
    }
    END {
        if (insec && !found) { flush_block(); print k "=" v }
        else if (!insec && !found) { print "[" s "]"; print k "=" v }
        else flush_block()
    }
    ' "$f" >"$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$f"
}

# 读取指定分区某键的值 (首次出现)
# $1=文件 $2=分区 $3=key; 输出值
get_section_kv() {
    [ -f "$1" ] || return 0
    section_body "$1" "$2" 2>/dev/null | grep "^$3=" | head -n 1 | cut -d= -f2
}

# ===== 旧配置迁移 (26w34.6-B 第四轮: 多文件 → fuyun.conf / whitelist.txt) =====
# 幂等: 目标文件已存在则跳过; 迁移后旧文件改名 .legacy 保留 (可回退)
# $1=用户配置目录 (USER_PATH)
migrate_legacy() {
    local d="$1"
    [ -n "$d" ] || return 0
    [ -d "$d" ] || return 0
    # 1) 键值配置 → fuyun.conf
    if [ ! -f "$d/fuyun.conf" ] && { [ -f "$d/mem_config.txt" ] || [ -f "$d/idle_gov.txt" ] || [ -f "$d/corectl.txt" ]; }; then
        : >"$d/fuyun.conf"
        if [ -f "$d/mem_config.txt" ]; then
            echo "[mem]" >>"$d/fuyun.conf"
            cat "$d/mem_config.txt" >>"$d/fuyun.conf"
            echo >>"$d/fuyun.conf"
            mv -f "$d/mem_config.txt" "$d/mem_config.txt.legacy" 2>/dev/null
        fi
        if [ -f "$d/idle_gov.txt" ]; then
            echo "[idle_gov]" >>"$d/fuyun.conf"
            cat "$d/idle_gov.txt" >>"$d/fuyun.conf"
            echo >>"$d/fuyun.conf"
            mv -f "$d/idle_gov.txt" "$d/idle_gov.txt.legacy" 2>/dev/null
        fi
        if [ -f "$d/corectl.txt" ]; then
            echo "[corectl]" >>"$d/fuyun.conf"
            cat "$d/corectl.txt" >>"$d/fuyun.conf"
            echo >>"$d/fuyun.conf"
            mv -f "$d/corectl.txt" "$d/corectl.txt.legacy" 2>/dev/null
        fi
    fi
    # 2) 白名单 → whitelist.txt
    if [ ! -f "$d/whitelist.txt" ] && { [ -f "$d/mem_whitelist.txt" ] || [ -f "$d/idle_whitelist.txt" ] || [ -f "$d/doze_whitelist.txt" ]; }; then
        : >"$d/whitelist.txt"
        if [ -f "$d/mem_whitelist.txt" ]; then
            echo "[mem]" >>"$d/whitelist.txt"
            cat "$d/mem_whitelist.txt" >>"$d/whitelist.txt"
            echo >>"$d/whitelist.txt"
            mv -f "$d/mem_whitelist.txt" "$d/mem_whitelist.txt.legacy" 2>/dev/null
        fi
        if [ -f "$d/idle_whitelist.txt" ]; then
            echo "[idle_gov]" >>"$d/whitelist.txt"
            cat "$d/idle_whitelist.txt" >>"$d/whitelist.txt"
            echo >>"$d/whitelist.txt"
            mv -f "$d/idle_whitelist.txt" "$d/idle_whitelist.txt.legacy" 2>/dev/null
        fi
        if [ -f "$d/doze_whitelist.txt" ]; then
            echo "[doze]" >>"$d/whitelist.txt"
            cat "$d/doze_whitelist.txt" >>"$d/whitelist.txt"
            echo >>"$d/whitelist.txt"
            mv -f "$d/doze_whitelist.txt" "$d/doze_whitelist.txt.legacy" 2>/dev/null
        fi
    fi
}

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

###############################
# Log
###############################

# $1:content
log() {
    echo "$1" >>"$LOG_FILE"
}

clear_log() {
    true >"$LOG_FILE"
}

# 统一日志轮转 (F8): 超过 max 字节则保留一份 .old 并重建空文件, 防止日志悄悄撑爆存储
rotate_log() {
    local f="${1:-$LOG_FILE}" max="${2:-1048576}" sz
    [ -f "$f" ] || return 0
    sz=$(stat -c %s "$f" 2>/dev/null)
    [ "${sz:-0}" -gt "$max" ] 2>/dev/null || return 0
    mv -f "$f" "$f.old" 2>/dev/null
    : >"$f"
}
