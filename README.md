# 浮云调度(fuyun)

基于 [yc9559/uperf](https://github.com/yc9559/uperf) 的 Magisk / KernelSU 性能调度模块，支持**骁龙 8+ Gen1 (SM8475)、8 Gen2 (SM8550)、8 Gen3 (SM8650)、8 Elite (SM8750)、8 Elite Gen5 (SM8850)**。

> 当前版本：**26w34.7-b (202608222)**

**特性**
- uperf 调度引擎接管 CPU/GPU 调度（powersave / balance / performance / fast 四档）
- **辅助调速器**：前台应用持续低占用时（如停留在静态页面）自动压制空闲频率，恢复交互立即还原（可开关，性能档自动让位）
- **频率限制**：CPU 最高频率硬上限（仅大核 / 全部核心），上限以下保留 uperf 动态调频，WebUI 一键切换（续航/压发热向）；**息屏自动限频**默认开启（息屏自动套用息屏上限，亮屏恢复，不干预应用）
- **CPU 频率范围**：小核 / 中核 / 大核可分别设置频率下限与上限，支持任意 SoC 支持频点，min=max 即锁频；WebUI「CPU 频率范围」独立界面操作（频点以设备实测为准，非法值自动吸附到最近支持频点，按 policy 显示冻结生效状态）
- **主流游戏特调**：按引擎分组预置 30+ 款主流游戏规则（Unity 系 / 米哈游定制 Unity / UE4 / UE5），渲染线程高优+动态升频、后台线程压小核限流，帧率稳的同时省电；游戏前台自动切 performance 档（perapp_powermode.txt 预置）
- **第三方插件接口**：`/sdcard/Android/yc/uperf/plugins/` 下放置 `.sh` 或 `.json` 插件即可导入，模块在 apply / clear / boot 阶段自动调用，便于后续扩展而不改引擎
- **Vulkan 开关**：Magisk 模块 Action 里按音量上开启 Vulkan、音量下还原 OpenGL，状态持久化，开机按上次选择生效
- Vulkan 渲染启用 + GPU Boost（高通 KGSL 节点接管）
- 5G/SA 优先策略（修改前自动备份，卸载自动还原）
- 息屏压频省电（安装时可选择；只压频率/关大核，**不杀应用**——息屏应用冻结交给墓碑类专用模块，白名单外置可编辑）
- 内存优化服务 `memctl`：PSI 内存压力驱动的后台回收 + 推送应用进程清理 + **主动把空闲后台进程压入 zram** + 长时间未用进程杀掉后清理缓存

---

## 安装

| 环境 | 方式 |
|---|---|
| **Magisk** | Magisk 应用 → 模块 → 从本地安装（安装时按音量键确认，音量上继续） |
| **KernelSU** | KernelSU → 模块 → 从本地安装（原生 `customize.sh` 流程，无按键交互） |

要求：arm64 设备，骁龙 8+ Gen1 / 8 Gen2 / 8 Gen3 / 8 Elite / 8 Elite Gen5，Android 10+ (SDK 29+)。

> 平台识别：优先按 ro.board.platform 匹配（8 Gen3=pineapple、8 Elite=sun、8 Elite Gen5 候选 shark）；识别不出时按 CPU 簇布局自动探测（单大核 3 簇 → 8G3 系，双核 Prime 簇 2 簇 → 8E 系）。8 Elite / 8 Elite Gen5 为新适配平台，参数为保守初版，欢迎真机反馈迭代（详见 docs/tuning-8e.md）。

> ⚠️ 安装前建议备份重要数据。模块包含激进调度策略，有极小概率导致异常，出问题可进 Magisk/KernelSU 禁用模块恢复。

## 卸载

模块管理里直接卸载即可，卸载脚本会：
1. 停止 memctl 服务
2. **还原被修改的 modem 网络配置**（`network_mode.xml`，从 `/data/adb/uperf_backup` 恢复）
3. 保留你的 `perapp_powermode.txt` 到原路径

---

## 配置（均在 `/sdcard/Android/yc/uperf/` 下，修改即时/重启生效）

| 文件 | 作用 |
|---|---|
| `uperf.json` | uperf 调度配置（安装时按 SoC 自动选择，勿轻易改） |
| `cur_powermode.txt` | 当前性能模式：`powersave` / `balance` / `performance` / `fast` |
| `perapp_powermode.txt` | 分应用性能模式（V-Tools 兼容） |
| `mem_config.txt` | 内存优化总配置：`MODE`(soft/hard/kill)、`PSI_THRESHOLD`、`PUSH_KEEP`、`ZRAM_RECLAIM` 等 |
| `mem_apps.txt` | 分应用回收策略：`包名 模式`（soft/hard/kill/off） |
| `mem_whitelist.txt` | 内存回收白名单（支持 `com.tencent.*` 前缀通配） |
| `idle_gov.txt` | 辅助调速器配置（开关 / 判定间隔 / 进入超时 / CPU 阈值 / 功率预算） |
| `idle_whitelist.txt` | 调速器白名单（前台应用命中则永不压制频率，支持前缀通配） |
| `freq_limit.txt` | 频率限制配置（`FREQ_CAP` 上限 kHz / `FREQ_SCOPE` big=仅大核 all=全部 / 息屏自动限频开关与息屏上限） |
| `freq_range.txt` | CPU 频率范围配置（小/中/大核 `MIN` / `MAX`，0=动态，非 0=SoC 支持频点） |
| `screen_saver.txt` | 息屏压频开关 `SCREEN_SAVER`（1=息屏关大核+800MHz 压频，0=关闭；安装时选择，可手动改） |
| `doze_whitelist.txt` | 息屏 Doze 推送白名单（微信/QQ 等，仅豁免不杀应用） |

### 辅助调速器快速上手

```sh
# 查看辅助调速器状态 (mem_log.txt 内有进/出深度空闲事件)
cat /sdcard/Android/yc/uperf/mem_log.txt | grep 辅助调速

# 让某应用永不压制频率 (视频/导航等需要稳定性能的应用)
echo "com.example.app" >> /sdcard/Android/yc/uperf/idle_whitelist.txt

# 更激进的空闲压频 (功率预算从 0.8W 降到 0.5W, 实测不卡再调)
echo "IDLE_POWER_W=0.5" >> /sdcard/Android/yc/uperf/idle_gov.txt
```

### 频率限制快速上手

```sh
# 查看当前频率上限状态 (0=动态不限制)
cat /sdcard/Android/yc/uperf/freq_limit.txt

# 命令行直接限制大核最高 1.8GHz (WebUI「频率限制」卡片可一键切换)
echo "FREQ_CAP=1800000" >> /sdcard/Android/yc/uperf/freq_limit.txt

# 恢复动态频率
echo "FREQ_CAP=0" >> /sdcard/Android/yc/uperf/freq_limit.txt
# 上限以下 uperf 仍动态调频; 限制立即生效 (守护每 60s 巡检, WebUI 保存立即应用)

# 息屏自动限频 (默认开启): 息屏时自动套用 1.2GHz, 亮屏恢复主上限
# 只压频率不干预应用; 息屏应用冻结/清理请搭配墓碑类模块
echo "FREQ_OFFSCREEN_CAP=1200000" >> /sdcard/Android/yc/uperf/freq_limit.txt
```

### 内存优化快速上手

```sh
# 查看回收日志 (含每次释放的内存)
cat /sdcard/Android/yc/uperf/mem_log.txt

# 例: 让某游戏后台被直接杀 (保留任务栈)
echo "com.example.game kill" >> /sdcard/Android/yc/uperf/mem_apps.txt

# 例: 保护某应用永不回收
echo "com.example.app off" >> /sdcard/Android/yc/uperf/mem_apps.txt

# 例: 白名单加前缀规则, 保护全家桶
echo "com.baidu.*" >> /sdcard/Android/yc/uperf/mem_whitelist.txt
```

---

## 日志

| 日志 | 路径 |
|---|---|
| 内存回收 | `/sdcard/Android/yc/uperf/mem_log.txt` |
| 息屏省电 | `/sdcard/Android/yc/uperf/screen_log.txt` |
| uperf | `/sdcard/Android/yc/uperf/uperf_log.txt` |
| 启动初始化 | `/sdcard/Android/yc/uperf/initsvc.log` |

## WebUI 控制台

Magisk / KernelSU 的**模块详情页 → WebUI** 即可打开控制台（或浏览器访问 `http://127.0.0.1:16800`，需 root 环境）。

**能做什么**：
- 查看运行状态（uperf/memctl 进程、可用内存、前台应用）
- 一键切换性能模式（省电/均衡/性能/极速）
- 可视化配置内存优化全部参数（模式、PSI 阈值、间隔、空闲淘汰、切换回收等）
- 配置辅助调速器（开关、判定间隔、进入超时、CPU 阈值、功率预算）与调速器白名单
- **频率限制**：一键切换 CPU 最高频率上限（动态 / 多档上限，仅大核或全部核心），实时显示大核硬件上限
- **CPU 频率范围**：分别设置小核 / 中核 / 大核的频率下限与上限，下拉框只显示当前 SoC 支持频点
- 管理分应用回收策略（`mem_apps.txt`）与白名单（`mem_whitelist.txt`）
- 管理息屏 Doze 白名单（`doze_whitelist.txt`）
- **高级设置**：直接编辑 `uperf.json` / `mem_config.txt` / `idle_gov.txt` / `perapp_powermode.txt`，保存前自动备份 `.bak`
- 立即回收一轮 / 重启 memctl / 重载配置
- 查看日志（mem/screen/uperf）

**安全**：HTTP 服务仅监听 `127.0.0.1:16800`（本机回环），root 运行，外部无法访问。

---

## 目录结构

```
├── customize.sh           # KernelSU 原生安装脚本
├── install.sh             # Magisk 安装脚本
├── uninstall.sh           # 卸载脚本 (含 modem 配置还原)
├── module.prop            # 模块信息
├── common/                # post-fs-data.sh / service.sh / system.prop
├── script/                # memctl.sh 内存服务 + uperf 启动/配置脚本
├── config/                # 平台配置与默认策略文件
├── bin/                   # uperf 二进制 + busybox
└── docs/                  # 调优指南
```

## 风险提示

- **GPU Boost** 关闭了 GPU 节流，长时间满负载游戏可能过热，请注意温度
- **5G/SA 强制** 在无 SA 覆盖的运营商网络可能无法驻网（卸载模块会自动还原，也可手动还原 `/data/adb/uperf_backup` 中备份）
- 模块为个人爱好作品，无任何保修，使用即视为接受风险

## 致谢

- [yc9559/uperf](https://github.com/yc9559/uperf) — 原版调度引擎
- 李诗雅、最爱小雅、掌柜岁眸、NekoNemo — 调度底子
- 反馈 QQ 群：1098223606
