# 骁龙 8 Elite (SM8750) / 8 Elite Gen5 (SM8850) 调优指南

> 本配置为基于规格书的**保守初版**，未经过真机实测调参。8 Elite Gen5 (8e5) 的 `sdm8e5.json` 目前是 8 Elite 模板的占位版，**强烈需要真机数据**。

## 硬件概况

| 组成 | 8 Elite (SM8750) | 8 Elite Gen5 (SM8850) |
|---|---|---|
| CPU | 2× Oryon Prime @ 4.32GHz + 6× Oryon @ 3.53GHz | 第三代 Oryon 2+6，4.6G 级（待实测） |
| 布局 | policy0 = CPU0-5（性能核×6）/ policy6 = CPU6-7（Prime×2） | 同 2+6（待实测确认） |
| GPU | Adreno 830 | 新一代 Adreno（独立显存版） |
| 平台 | sun (SM8750) | shark? (SM8850，候选代号) |

## 与 8+/8G2 的关键差异

1. **没有小核**：6 个 Oryon 性能核承担小核+中核的活，只有 2 个 Prime 大核
2. **双核 Prime 簇**：`cluster_of_policy` 已兼容（大核判定不再要求单核）
3. **cpuset 策略**：日常 balance 的 top-app 限制在 `0-5`（不上 Prime，省电）；后台/受限压 `0-3`（性能核低段）；performance/fast 才解锁 `0-7`
4. **游戏规则**：渲染/游戏线程绑 `core6-7`（Prime）+ 动态升频；后台工作线程/音频/网络压 `core0-2`（低段性能核）限流

## 当前配置要点

### 功耗模型（`sdm8e.json`）

| 簇 | efficiency | nr | typicalPower | typicalFreq | 说明 |
|---|---|---|---|---|---|
| 6× Oryon | 260 | 6 | 1.1W | 2.0GHz | 性能核（主力，代替小核+中核） |
| 2× Oryon L | 480 | 2 | 2.4W | 2.4GHz | Prime 大核 |

## 调优方向（需真机验证）

- 日常发热 → balance 的 top-app 从 `0-5` 降到 `0-3`
- 日常卡顿 → balance top-app 改 `0-7`（更激进）或降低 Prime `efficiency`（如 450）
- 游戏 → 调整 `games_*` 块中 `dynamic_boost` 参数；Prime 簇只有 2 核，渲染线程建议只绑 `core6-7`，避免与主线程抢核

## 反馈清单（发作者）

- 机型 / 系统 / 内核版本 (`uname -a`)
- `cat /sys/devices/system/cpu/cpufreq/policy*/related_cpus` ← **平台代号与布局确认的关键**
- `cat /sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq`
- `getprop ro.board.platform` / `getprop ro.soc.model`
- 日常/游戏掉帧或发热描述 + uperf_log.txt 片段
