# 骁龙 8+ Gen1 (SM8475) 调优指南

> 本文档说明 `sdm8+.json` 的关键参数含义与调优方向。**没有实测数据时不要盲目改数值**——当前参数是作者基于 8+ 特性调校的，改前先备份 `uperf.json`。

## 硬件概况

| 组成 | 规格 |
|---|---|
| CPU | 1× X2 @ 3.2GHz + 3× A710 @ 2.75GHz + 4× A510 @ 2.02GHz |
| GPU | Adreno 730 |
| 平台 | taro (SM8475) |

## 当前配置要点（`config/sdm8+.json`）

### 功耗模型（`cpu.powerModel`）

| 簇 | efficiency | typicalPower | typicalFreq | sweetFreq | 说明 |
|---|---|---|---|---|---|
| 4× A510 | 100 | 0.30W | 1.6GHz | 1.4GHz | 小核，省电主力 |
| 3× A710 | 340 | 1.86W | 2.0GHz | 1.78GHz | 中核，效率值比 8G2 版(220)更高 → uperf 更倾向用中核 |
| 1× X2 | 420 | 1.36W | 1.68GHz | 2.6GHz | 大核，sweetFreq 高于 typicalFreq → 单大核被鼓励拉高频率 |

**设计意图**：8+ 只有 1 个大核，中核承担主要负载。模型让 uperf 在 8+ 上"中核为主、大核冲顶"，避免频繁在大核/中核间迁移。

**可调方向**：
- 觉得日常卡顿 → 提高 X2 的 `sweetFreq`（如 2.8）或降低中核 `efficiency`（如 300），让调度更早上大核
- 觉得费电 → 降低 X2 `sweetFreq`（如 2.4）、提高中核 `efficiency`（如 360）

### 模式预设（`presets`）

| 模式 | 关键参数 | 适用 |
|---|---|---|
| `powersave` | GPU powersave、limitEfficiency、margin 0.05、fastLimitCapacity 2.0 | 待机/轻办公 |
| `balance` | GPU simple_ondemand、margin 0.25、fastLimit 2.0W | 日常综合（默认） |
| `performance` | GPU msm-adreno-tz、bus/rail_on、fastLimit 12W、margin 0.36 | 游戏 |
| `fast` | GPU performance、limit 999（无限制）、margin 0.65 | 极限性能 |

### cpuset 初始划分（`initials.sysfs`）

```
top-app: 0-7    foreground: 0-7    background: 0-3    restricted: 0-6
```
background 只允许小核（0-3），restricted 排除大核（7）——保证后台不抢大核资源。

## 针对 8+ 的调优建议

### 1. 游戏向（性能优先）
```sh
# 切到 performance 模式
echo performance > /sdcard/Android/yc/uperf/cur_powermode.txt
# 可选: 提高大核甜点频率
# 编辑 /sdcard/Android/yc/uperf/uperf.json 中 powerModel[2].sweetFreq: 2.6 → 2.8
```

### 2. 续航向
```sh
echo powersave > /sdcard/Android/yc/uperf/cur_powermode.txt
# 内存优化配合: mem_config.txt 设 MODE=hard, PSI_THRESHOLD=10 (更积极回收)
```

### 3. 日常流畅
```sh
echo balance > /sdcard/Android/yc/uperf/cur_powermode.txt
# 8+ 单大核特性: 不建议日常用 performance (大核发热快)
```

## 验证调优效果

```sh
# 查看实时频率 (确认调度器行为)
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq

# 查看 uperf 运行日志
cat /sdcard/Android/yc/uperf/uperf_log.txt | tail -50

# 恢复出厂配置 (重新安装模块或从备份还原)
ls /sdcard/Android/yc/uperf/uperf.json.bak
```

## 常见问题

- **游戏掉帧**：确认当前模式不是 powersave；GPU 是否被 thermal 限制（`/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage`）
- **发热严重**：模块的 GPU Boost 关闭了节流，建议游戏一局后让手机休息；或临时 `echo balance > cur_powermode.txt`
- **想还原官方调度**：卸载模块即可（GPU 节点由 post-fs-data 每次开机设置，卸载后重启即还原）
