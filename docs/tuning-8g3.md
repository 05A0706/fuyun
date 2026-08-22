# 骁龙 8 Gen3 (SM8650) 调优指南

> 本配置为基于规格书的**保守初版**，未经过真机实测调参。改前先备份 `uperf.json`。

## 硬件概况

| 组成 | 规格 |
|---|---|
| CPU | 1× Cortex-X4 @ 3.3GHz + 5× Cortex-A720 @ 3.15GHz + 2× Cortex-A520 @ 2.27GHz |
| 布局 | policy0 = CPU0-1 (A520) / policy2 = CPU2-6 (A720×5) / policy7 = CPU7 (X4) |
| GPU | Adreno 750 |
| 平台 | pineapple (SM8650) |

## 当前配置要点（`config/sdm8g3.json`）

### 功耗模型（`cpu.powerModel`）

| 簇 | efficiency | nr | typicalPower | typicalFreq | 说明 |
|---|---|---|---|---|---|
| 2× A520 | 110 | 2 | 0.5W | 1.4GHz | 小核（8G3 只有 2 个小核，比 8G2 少 1 个） |
| 5× A720 | 240 | 5 | 0.9W | 2.0GHz | 中核，日常主力 |
| 1× X4 | 430 | 1 | 2.4W | 2.2GHz | 大核 |

**与 8G2 的差异**：小核从 3 核减到 2 核，中核从 4 核增到 5 核，因此后台/受限 cpuset 从 `0-2` 调整为 `0-1`，游戏规则中「压小核」的 affinity 同步改为 `core0-1`。

## 调优方向（需真机验证）

- 日常卡顿 → 提高 X4 `sweetFreq`（如 2.0）或降低中核 `efficiency`（如 220）
- 费电 → 降低 X4 `sweetFreq`（如 1.6）、提高中核 `efficiency`（如 260）
- 游戏帧率不稳 → performance 档已解锁全部核心，可调 `games_*` 规则块里渲染线程的 `dynamic_boost` 时长/幅度

## 验证方法

```sh
# 实时频率
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
# uperf 日志
tail -50 /sdcard/Android/yc/uperf/uperf_log.txt
# 频率限制状态
grep 频率限制 /sdcard/Android/yc/uperf/mem_log.txt
```

## 反馈清单（发作者）

- 机型 / 系统 / 内核版本 (`uname -a`)
- `cat /sys/devices/system/cpu/cpufreq/policy*/related_cpus`
- `cat /sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq`
- 日常/游戏掉帧或发热的主观描述 + uperf_log.txt 片段
