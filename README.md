# 浮云调度(fuyun)

基于 [yc9559/uperf](https://github.com/yc9559/uperf) 的 Magisk / KernelSU 性能调度模块，适配 **骁龙 8+ Gen1 (sd8+gen1/SM8475)**、**骁龙 8 Gen2 (sd8gen2/SM8550)**、**骁龙 8 Gen3 (SM8650)**、**骁龙 8 Elite (SM8750)** 与 **骁龙 8s Elite (SM8735)**。

> 当前版本：**0.2-rc1 (20260829)** —— 浮云新调度，新的开始

**特性**
- uperf 调度引擎接管 CPU/GPU 调度（powersave / balance / performance / fast 四档）
- **辅助调速器**（独立守护 `auxgov.sh`）：前台应用持续低占用时（如停留在静态页面）自动降低 idle 场景频率，恢复交互立即还原（可开关，性能档自动让位）；进入深度空闲可联动关核心
- **核心开关**（热插拔，用户配置驱动）：按配置关闭大核/中核降低功耗，**替代旧的"冻结式压频"**（不再 bind-mount 冻结 `scaling_max_freq`）；可选息屏额外关核、辅助调速器深度空闲联动关核；安全约束：绝不关 cpu0、小核始终在线（大/中核可整簇关闭，系统始终保有一整簇算力）
- **第三方插件接口**：`/data/adb/uperf/plugins/`（root-only，仅 root 可写）下放置 `.sh` 脚本插件或 `.json` 描述插件即可导入（WebUI「管理 → 插件」可可视化启用/停用/删除），模块在 apply / clear / boot 阶段自动调用，便于后续扩展而不改引擎；`uperf.*.json` 命名的文件为**特调配置插件**，可在 WebUI 一键应用切换（自动备份并重启 uperf）
- **Vulkan 开关**：Magisk 模块 Action 里按音量上开启 Vulkan、音量下还原 OpenGL，状态持久化，开机按上次选择生效
- Vulkan 渲染启用 + GPU Boost（高通 KGSL 节点接管）
- 5G/SA 优先策略（修改前自动备份，卸载自动还原）
- 息屏省电（`corectl` 关核心 + `auxgov` 空闲降频，**不杀应用**——息屏应用冻结交给墓碑类专用模块，白名单外置可编辑）
- 内存优化服务 `memctl`：PSI 内存压力驱动的后台回收 + 推送应用进程清理 + **主动把空闲后台进程压入 zram** + 长时间未用进程杀掉后清理缓存

---

## 安装

| 环境 | 方式 |
|---|---|
| **Magisk** | Magisk 应用 → 模块 → 从本地安装（安装时按音量键确认，音量上继续） |
| **KernelSU** | KernelSU → 模块 → 从本地安装（原生 `customize.sh` 流程，无按键交互） |

要求：arm64 设备，骁龙 8+ Gen1 / 8 Gen2 / 8 Gen3 / 8 Elite / 8s Elite，Android 10+ (SDK 29+)。

> ⚠️ 安装前建议备份重要数据。模块包含激进调度策略，有极小概率导致异常，出问题可进 Magisk/KernelSU 禁用模块恢复。

## 卸载

模块管理里直接卸载即可，卸载脚本会：
1. 停止 memctl 服务
2. **还原被修改的 modem 网络配置**（`network_mode.xml`，从 `/data/adb/uperf_backup` 恢复）
3. 保留你的 `perapp_powermode.txt` 到原路径

---

## 配置（均在 `/sdcard/Android/yc/uperf/` 下，修改即时/重启生效）

> 26w34.6-B 起配置已**合并简化**：键值配置三合一为 `fuyun.conf`（分区 `[mem]`/`[idle_gov]`/`[corectl]`），白名单三合一为 `whitelist.txt`（分区 `[mem]`/`[idle_gov]`/`[doze]`）。升级安装时旧文件会自动迁移（原文件保留 `.legacy` 后缀）。**WebUI 可完成全部配置，无需手改文件。**

| 文件 | 作用 |
|---|---|
| `fuyun.conf` | **主配置**（三合一）：`[mem]` 内存优化（`MODE`/`PSI_THRESHOLD`/`INTERVAL`/`PUSH_KEEP`/`ZRAM_RECLAIM` 等）、`[idle_gov]` 辅助调速器（开关/判定间隔/进入超时/CPU 阈值/功率预算）、`[corectl]` 核心开关（`CORECTL_ENABLE`/`BIG_OFF`/`MID_OFF`/`OFFSCREEN_OFF`/`IDLE_OFF`/`KEEP_LITTLE`） |
| `whitelist.txt` | **白名单**（三合一）：`[mem]` 回收白名单、`[idle_gov]` 调速器白名单（均支持 `com.xxx.*` 前缀通配）、`[doze]` 息屏 Doze 推送白名单 |
| `uperf.json` | uperf 调度配置（安装时按 SoC 自动选择，勿轻易改） |
| `cur_powermode.txt` | 当前性能模式：`powersave` / `balance` / `performance` / `fast` |
| `perapp_powermode.txt` | 分应用性能模式（V-Tools 兼容） |
| `mem_apps.txt` | 分应用回收策略：`包名 模式`（soft/hard/kill/off） |
| `automation.txt` | 场景自动化规则（充电/电量/时段/屏幕触发） |

### 快速上手（也可全部走 WebUI，无需手改）

```sh
# 一键预设: 均衡默认 / 日常省电 / 游戏性能 / 极速
# (WebUI 内存页「配置预设」卡片)

# 修改某个键 (示例: 更激进的空闲降频, 写入 [idle_gov] 分区)
echo "IDLE_POWER_W=0.5" >> /sdcard/Android/yc/uperf/fuyun.conf   # 注意: 需替换分区内原行

# 查看核心开关配置
cat /sdcard/Android/yc/uperf/fuyun.conf | sed -n '/\[corectl\]/,/^\[/p'

# 兜底: 一键把全部核心恢复 online
sh /data/adb/modules/uperf/script/corectl.sh clear

# 安全约束: 绝不关 cpu0; 小核簇始终在线 (因此大/中核可整簇关闭, 系统始终保有一整簇算力)
# 关核数上限由设备实际核数决定 (如大核 1 颗则最多关 1 颗)
```

```sh
# 分应用回收 / 白名单示例 (白名单在 whitelist.txt 对应分区内追加)
echo "com.example.game kill" >> /sdcard/Android/yc/uperf/mem_apps.txt
echo "com.baidu.*" >> /sdcard/Android/yc/uperf/whitelist.txt   # 追加到 [mem] 分区末尾
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
- 查看运行状态（uperf/memctl 进程、可用内存、前台应用、渲染后端、模块版本）
- 一键切换性能模式（省电/均衡/性能/极速）
- 可视化配置内存优化全部参数（模式、PSI 阈值、间隔、空闲淘汰、切换回收等）
- 配置辅助调速器（开关、判定间隔、进入超时、CPU 阈值、功率预算）与调速器白名单
- **核心开关**：设置总开关、常态关大核/中核数量（滑块上限按设备实际核数自动收敛），可选息屏额外关核与深度空闲联动关核，实时显示各簇在线核数
- 管理分应用回收策略（`mem_apps.txt`）与回收白名单（`whitelist.txt [mem]`）
- **分应用性能模式**：可视化指定应用固定性能档（`perapp_powermode.txt`，V-Tools 兼容）
- 管理息屏 Doze 白名单（`whitelist.txt [doze]`）
- **配置预设**：一键应用 均衡默认 / 日常省电 / 游戏性能 / 极速，或把当前配置保存为自定义预设
- **插件管理**：可视化启用/停用/删除 `/data/adb/uperf/plugins` 插件，查看 plugin.log；`uperf.*.json` 特调配置一键应用（自动备份 + 重启 uperf）
- **渲染后端切换**：Vulkan / OpenGL 一键切换（状态持久化，开机保持）
- **场景自动化快捷规则**：一键添加充电切性能 / 低电省电 / 夜间省电 / 息屏关大核等常用规则
- **高级设置**：直接编辑 `fuyun.conf` / `whitelist.txt` / `perapp_powermode.txt` / `uperf.json` / `automation.txt`，保存前自动备份 `.bak`（uperf.json 保存前做括号校验）
- 立即回收一轮（即时响应）/ 重启 memctl / **重启 uperf** / 重载配置
- 查看日志（mem/screen/uperf/corectl/auxgov/watchdog/automation，可选行数与自动刷新）

**安全**：HTTP 服务仅监听 `127.0.0.1:16800`（本机回环），root 运行，外部无法访问。

---

## 目录结构

```
├── customize.sh           # KernelSU 原生安装脚本
├── install.sh             # Magisk 安装脚本
├── uninstall.sh           # 卸载脚本 (含 modem 配置还原)
├── module.prop            # 模块信息
├── common/                # post-fs-data.sh / service.sh / system.prop
├── script/                # memctl.sh 内存服务 + auxgov.sh 辅助调速器 + corectl.sh 核心开关 + automation.sh 场景自动化 + uperf 脚本
├── plugin_examples/       # 内置示例插件 (安装时放入插件目录, 默认停用)
├── config/                # 平台配置与默认策略文件 (含 5 款 SoC 特调)
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
