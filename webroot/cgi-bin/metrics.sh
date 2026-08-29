#!/system/bin/sh
# metrics.sh - 实时运行指标快照 (F4)
# 输出 JSON: 大/中/小核平均频率(MHz) + 可用内存(MB) + 温度(°C) + 在线核 + 时间戳
# 自包含实现, 不引入任何新依赖; 频率分类策略与 corectl.sh 一致。
. "$(dirname "$0")/lib.sh"
require_token

# 全局最高 cpuinfo_max_freq (用于判定"单核且最高频 = 大核")
bestf=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    f=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
    case "$f" in ''|*[!0-9]*) continue ;; esac
    [ "$f" -gt "$bestf" ] && bestf=$f
done

b_sum=0 b_n=0 m_sum=0 m_n=0 l_sum=0 l_n=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    maxf=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
    case "$maxf" in ''|*[!0-9]*) continue ;; esac
    rel=$(cat "$p/related_cpus" 2>/dev/null)
    count=0; has0=0
    for c in $rel; do
        case "$c" in ''|*[!0-9]*) continue ;; esac
        [ "$c" = "0" ] && has0=1
        count=$((count + 1))
    done
    # 与 corectl.sh 同策略: 单核且全局最高频 = big; 含 cpu0 = little; 其余 = mid
    if [ "$count" -eq 1 ] && [ "$maxf" -ge "$bestf" ] 2>/dev/null; then
        cl=big
    elif [ "$has0" = "1" ]; then
        cl=little
    else
        cl=mid
    fi
    for c in $rel; do
        case "$c" in ''|*[!0-9]*) continue ;; esac
        on=$(cat /sys/devices/system/cpu/cpu$c/online 2>/dev/null)
        [ "$on" = "1" ] || continue
        f=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null)
        case "$f" in ''|*[!0-9]*) continue ;; esac
        case "$cl" in
            big)    b_sum=$((b_sum + f)); b_n=$((b_n + 1)) ;;
            mid)    m_sum=$((m_sum + f)); m_n=$((m_n + 1)) ;;
            little) l_sum=$((l_sum + f)); l_n=$((l_n + 1)) ;;
        esac
    done
done

b_avg=0; [ "$b_n" -gt 0 ] && b_avg=$(( b_sum / b_n / 1000 ))
m_avg=0; [ "$m_n" -gt 0 ] && m_avg=$(( m_sum / m_n / 1000 ))
l_avg=0; [ "$l_n" -gt 0 ] && l_avg=$(( l_sum / l_n / 1000 ))

mem_avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
[ -n "$mem_avail" ] || mem_avail=0

thermal=-1
for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat "$z/temp" 2>/dev/null)
    case "$t" in ''|*[!0-9]*) continue ;; esac
    thermal=$(( t / 1000 ))
    [ "$thermal" -gt 0 ] && break
done

online=$(cat /sys/devices/system/cpu/online 2>/dev/null)

json_headers
printf '{"ok":true,"big_freq":%s,"mid_freq":%s,"little_freq":%s,"mem_avail_mb":%s,"thermal":%s,"online":"%s","ts":%s}\n' \
    "$b_avg" "$m_avg" "$l_avg" "$mem_avail" "$thermal" "$online" "$(date +%s)"
