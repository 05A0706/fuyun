# fuyun（浮云）

基于 [yc9559/uperf](https://github.com/yc9559/uperf) 的 Magisk / KernelSU 性能调度模块，针对**骁龙 8+ Gen1 (sd8+gen1/SM8475)** 与 **骁龙 8 Gen2 (sd8gen2/SM8550)** 适配。

> 当前版本：**26w34.4-b (20260820)**

**特性**
- uperf 调度引擎接管 CPU/GPU 调度（powersave / balance / performance / fast 四档）
- **辅助调速器**：前台应用持续低占用时（如停留在静态页面）自动压制空闲频率，恢复交互立即还原（可开关，性能档自动让位）
- Vulkan 渲染启用 + GPU Boost（高通 KGSL 节点接管）
- 5G/SA 优先策略（修改前自动备份，卸载自动还原）
- 息屏深度省电（关大核 + 深度 Doze，白名单外置可编辑）
- 内存优化服务 `memctl`：PSI 内存压力驱动的后台回收 + 推送应用进程清理

---

## 安装

| 环境 | 方式 |
|---|---|
| **Magisk** | Magisk 应用 → 模块 → 从本地安装（安装时按音量键确认，音量上继续） |
| **KernelSU** | KernelSU → 模块 → 从本地安装（原生 `customize.sh` 流程，无按键交互） |

要求：arm64 设备，骁龙 8+ Gen1 / 8 Gen2，Android 10+ (SDK 29+)。

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
| `mem_config.txt` | 内存优化总配置：`MODE`(soft/hard/kill)、`PSI_THRESHOLD`、`PUSH_KEEP` 等 |
| `mem_apps.txt` | 分应用回收策略：`包名 模式`（soft/hard/kill/off） |
| `mem_whitelist.txt` | 内存回收白名单（支持 `com.tencent.*` 前缀通配） |
| `idle_gov.txt` | 辅助调速器配置（开关 / 判定间隔 / 进入超时 / CPU 阈值 / 功率预算） |
| `idle_whitelist.txt` | 调速器白名单（前台应用命中则永不压制频率，支持前缀通配） |
| `doze_whitelist.txt` | 息屏 Doze 推送白名单（微信/QQ 等） |

### 辅助调速器快速上手

```sh
# 查看辅助调速器状态 (mem_log.txt 内有进/出深度空闲事件)
cat /sdcard/Android/yc/uperf/mem_log.txt | grep 辅助调速

# 让某应用永不压制频率 (视频/导航等需要稳定性能的应用)
echo "com.example.app" >> /sdcard/Android/yc/uperf/idle_whitelist.txt

# 更激进的空闲压频 (功率预算从 0.8W 降到 0.5W, 实测不卡再调)
echo "IDLE_POWER_W=0.5" >> /sdcard/Android/yc/uperf/idle_gov.txt
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
