# 更新日志

## fuyun 0.2-rc1 (20260829) —— 浮云新调度，新的开始

> 本次版本从 26w34.6-B 系列整合为 **0.2-rc1**，是一次里程碑式更新：核心调度策略由"频率压制"全面转向"核心开关"，配置体系大幅简化，插件生态成型，WebUI 更安全易用。以下为整合后的完整版本介绍。

### 核心变更：告别频率压制，拥抱核心开关

- **移除全部频率压制功能**：删除 `freq_limit.sh` 及其配置（`freq_limit.txt` / `freq_range.txt` / `screen_saver.txt`），不再通过绑载冻结方式限制 CPU 频率。
- **新增核心开关（热插拔关核）**：由 `corectl.sh` 守护管理，支持常态关大核/中核、息屏额外关核、深度空闲联动关核。安全约束：**绝不关闭 cpu0，小核始终在线，大/中核可整簇关闭，系统始终保有一整簇算力**。提供 CLI（`watch / apply / clear / --off / --on / status`）与 WebUI 卡片，关核数量滑块按设备实际核数动态收敛。

### 模块化与架构优化

- **辅助调速器独立成模块**：从内存管理中抽离 idle 调速逻辑为独立守护 `auxgov.sh`，配置与白名单文件路径不变。深度空闲时联动核心开关关核（受 `IDLE_OFF` 与总开关约束），退出深度空闲自动恢复，并修复深度参数残留问题。
- **内存管理精简**：`memctl.sh` 由约 1000 行精简至 637 行，专注内存回收，职责更单一。改进进程清理方式（`am kill` 替代 `kill -9`），支持 `IDLE_KILL_MIN=0` 跳过闲置计算，提升即时响应速度。
- **看门狗与日志拆分**：`service.sh` 新增进程看门狗，自动拉起异常退出的 memctl / auxgov / corectl；corectl / auxgov 日志从 `mem_log.txt` 拆出独立文件，统一轮转。

### 配置体系大升级

- **配置文件合并（11 个 → 7 个）**：
  - `fuyun.conf` 合并原 `mem_config.txt` + `idle_gov.txt` + `corectl.txt`（分区 `[mem]` / `[idle_gov]` / `[corectl]`）
  - `whitelist.txt` 合并原 `mem_whitelist.txt` + `idle_whitelist.txt` + `doze_whitelist.txt`（分区 `[mem]` / `[idle_gov]` / `[doze]`）
  - **自动迁移旧文件**（幂等，原文件保留 `.legacy` 后缀可回退）
- **Ordinary / Expert 分级**：WebUI 默认只显示高频项（模式、预设、核心开关、内存开关、调速器总开关），低频项折叠进专家区（默认收起），降低上手门槛。
- **配置预设**：新增「配置预设」卡片，内置 均衡默认 / 日常省电 / 游戏性能 / 极速 四档，支持保存当前配置为自定义预设（存放于 `/data/adb/uperf/presets/`），一键应用即时生效。
- **统一配置校验与原子写入**：所有写配置 CGI 复用统一校验（布尔、数值、包名、枚举、范围），写前自动 `.bak`，原子写入避免配置损坏；`config_file.sh` 增加上传体积上限与 `uperf.json` 括号平衡校验。

### 插件系统全面强化

- **插件管理器**：新增 WebUI 插件管理卡片（列表 / 启用 / 停用 / 删除 / 查看日志），插件目录迁移至 root-only `/data/adb/uperf/plugins` 实现隔离与准入控制。
- **配置插件（特调化）**：插件目录放置 `uperf.<名称>.json` 即可在 WebUI 一键应用，自动备份当前配置、重启 uperf、清除辅助调速器深度状态。
- **示例插件与文档**：内置示例插件演示阶段与环境变量，插件日志轮转，README 更新三种插件说明。

### 机型特调扩充

- 接入 5 份 uperf 特调配置：新增 **骁龙 8 Gen3 (sdm8g3)**、**8 Elite (sdm8e)**、**8s Elite (sdm8e5)**，更新 `sdm8+` / `sdm8g2` 为资料版（含 games_moba 规则、dynamic_boost、正则锚定）。
- `libsysinfo.sh` 补齐 board 映射（`sun`→sdm8e、`bonito/sun2/voltron`→sdm8e5）。

### WebUI 功能与体验

- **实时运行曲线**：新增 metrics 接口与 Canvas 绘制，每 2 秒采样大/中/小核平均频率、可用内存、温度，仅页面可见时轮询，零图表库。
- **配置导入/导出与一键备份**：`backup.sh` 打包全部配置为带版本号 tar.gz（base64 返回），导入前自动备份并防路径穿越。
- **场景自动化规则引擎**：新增 `automation.sh` 守护，按 充电/电量/时段/屏幕 触发策略，与 perapp 按前台应用维度互补；管理页提供 `automation.txt` 编辑器。
- **更多改进**：新增「重启 uperf」按钮、Vulkan 状态展示、分应用性能模式可视化编辑、场景自动化快捷规则、日志行数选择与自动刷新、footer 显示版本、uperf.json 前端括号校验、后端提示中文统一。
- **安全加固**：WebUI API 访问认证（root-only 令牌注入与校验），纵深防御回环接口访问；插件脚本取消 `command` 直通，仅允许插件目录内脚本并校验路径逃逸。

### 修复与细节优化

- **修复卸载残留**：停止 automation.sh / service.sh 看门狗，perapp 保留判存在，模块路径改为 `$MODDIR` 推导。
- **修复路径硬编码**：lib.sh / action.sh 模块路径从 webroot 向上推导。
- **CGI 校验与守护对齐**：内存相关参数范围与 `memctl.sh` 一致；idle 间隔 ≥3s，CPU 阈值 ≤100。
- **修复 auxgov 深度参数残留**：进入深度空闲记录原值，退出时逐键还原，即使用户改过 `uperf.json` 也正确合并。
- **备份导入防御**：拒绝符号链接/设备/绝对路径条目，双重校验。
- **健壮性提升**：getprop SDK 空值加固、rmdir 静默、端口探测不依赖 `nc -z`、状态文件权限 600。
- **代码质量**：公共函数抽入 `libcommon.sh`，删除死代码，命名统一 `set_config.sh` → `set_mem_cfg.sh`。
- **文档与文案**：安全说明统一为"绝不关 cpu0、小核始终在线"，清理历史压频术语。


## fuyun 26w34.6-b (20260822)

### 新增 Vulkan 音量键切换
- Magisk 模块 Action 中监听音量键：音量上 = 开启 Vulkan，音量下 = 还原 OpenGL
- 状态持久化到 `/data/adb/uperf/vulkan.state`，开机由 `post-fs-data.sh` 按状态应用
- 还原 OpenGL 时同时关闭 `ro.hwui.use_vulkan` / `debug.renderengine.vulkan` / `debug.renderengine.graphite` 等 Vulkan 属性

### memctl 主动压入 zram + 清理
- 新增 `ZRAM_RECLAIM` / `ZRAM_RECLAIM_SIZE` / `ZRAM_IDLE_MIN` 配置
- 对空闲后台进程尝试 cgroup v2 anon 回收，把匿名内存换出到 zram，进程保活
- 沿用 `last_used` 判定空闲，避免频繁压制
- 杀进程后可选触发 `pm trim-caches` 清理系统缓存（`CLEAN_CACHE_AFTER_KILL` / `TRIM_CACHE_SIZE`）


### 新增 CPU 频率范围（小/中/大核 min/max 可调）
- WebUI 新增「CPU 频率范围」独立界面：分别设置小核 / 中核 / 大核的频率下限与上限，0=动态，min=max=锁频
- 内置 8+ Gen1 / 8 Gen2 支持频点表，下拉框只显示当前 SoC 合法频点，非法值自动拒绝并记录日志
- 扩展 `freq_limit.sh` 为统一频率控制服务：全局上限与分簇 min/max 共用一套 bind-mount 掩码，避免互相覆盖
- 自动识别 policy 属于小核/中核/大核，按簇应用 `scaling_min_freq` / `scaling_max_freq`
- 配置：`/sdcard/Android/yc/uperf/freq_range.txt`

### 新增第三方插件接口
- 插件目录：`/sdcard/Android/yc/uperf/plugins/`，放置 `.sh` 插件即可
- 调用阶段：`apply`（频率控制应用后）、`clear`（清除后）、`boot`（开机服务就绪后）
- 环境变量：`FUYUN_STAGE` / `FUYUN_SOC` / `FUYUN_MODULE_DIR` / `FUYUN_USER_PATH` / `FUYUN_PLUGIN_DIR`
- 插件输出记录到 `plugin.log`，插件失败不影响模块主功能

### 插件支持 JSON 导入
- `plugins/` 目录除了 `.sh`，现在支持 `.json` 描述插件
- JSON 支持 `name` / `enabled` / `stages` / `command` / `file` 字段
- 直接把 JSON 文件放进 `plugins/` 即自动导入生效

## fuyun 26w34.5-b (20260821)

### 新增频率限制（CPU 最高频率上限）
- WebUI 新增「频率限制」卡片：一键切换 动态 / 多档上限（0.8G–2.4G），范围可选 仅大核 / 全部核心，实时显示大核硬件上限
- **保留动态频率**：上限以下 uperf 仍按场景/负载动态调频，仅在达到上限时封顶
- 实现：先真实写入 `scaling_max_freq`，再 bind-mount 掩码文件冻结节点（独立掩码源，不污染开机脚本共用的 mount_mask），uperf 的持续写入无法突破上限；解除即 umount 还原，恢复完整动态范围
- **按运行时实测频点自适应**：动态读取各簇 `cpuinfo_max_freq`/`cpuinfo_min_freq`——上限高于硬件上限的簇自动跳过（不限制）；上限低于最低频的簇 **clamp 到最低频**（效果=锁最低频，保证 0.8G 档在任何簇上都生效，不会被内核拒绝后静默跳过）；8+ Gen1 实测大核 min 787.2MHz / 中核 633.6MHz / 小核 300MHz，0.8G–2.4G 全部档位有效
- 掩码文件 per-policy 独立（各簇 clamp 值不同，共享文件会导致互相覆盖）
- 独立守护 `freq_limit.sh`（开机自启，巡检掩码在位，配置修改即时生效）；WebUI 保存立即应用并报告结果
- 配置 `freq_limit.txt`：`FREQ_CAP`（kHz，0=动态）/ `FREQ_SCOPE`（big=仅大核 all=全部），卸载时自动解除掩码还原频率

### 新增息屏自动限频（默认开启）
- 息屏时自动套用息屏上限（默认 1.2GHz），亮屏恢复主上限；WebUI 频率限制卡片可配开关与息屏上限
- 只压 CPU 频率、**不干预应用**：息屏应用冻结/清理交给墓碑类专用模块（本模块不集成）
- 息屏联动开启时守护以 15s 快巡检，亮屏/息屏切换最多 15s 内生效

### 息屏省电改造（移除"息屏杀应用"）
- **移除**强制深度 Doze（`force-idle` + 激进 `device_idle_constants`）与系统省电模式（`cmd power set-mode 1`）——这两项会限制/冻结后台应用，即"息屏杀应用"来源
- 息屏压频（关大核 + 800MHz + powersave）保留，**安装时可选择**（Magisk 音量上=开启/音量下=关闭，KernelSU 默认开启），事后可改 `screen_saver.txt` 或直接关掉交给息屏自动限频
- Doze 白名单（`doze_whitelist.txt`）保留为开机一次性注册：仅豁免不杀应用，系统原生 Doze 时推送不受影响

## fuyun 26w34.4-b (20260820)

### 新增中文名：**浮云（fuyun）**。优化 sdm8+ 和 sdm8g2 在各模式的核心分配，并新增 WebUI 高级设置与 Doze 白名单管理。

### WebUI
- 新增「高级设置」：可直接编辑 `uperf.json`、`mem_config.txt`、`idle_gov.txt`、`perapp_powermode.txt`，保存前自动备份 `.bak`
- 新增「Doze 白名单」管理：WebUI 可视化增删息屏 Doze 白名单
- 新增 `config_file.sh` / `doze.sh` API，文件路径白名单校验，`uperf.json` 保存前做基础 JSON 形状检查

### 调度配置
- 全部模式禁用 GPU Boost（`force_bus_on` / `force_rail_on` 置 0，`GpuGovernor` 不再使用 `performance`）
- `powersave` 重新定位为轻度日用/刷视频：放宽到中核（cpuset `0-5`），恢复触控响应，保留后台小核压制
- `balance` 保持默认日常定位，修复 `idle` 异常采样值并降低切换场景激进度
- `performance` 补齐 idle/touch/trigger/gesture/junk/switch 场景参数
- 修复 `sdm8+.json` 正则问题（`games_netease` 空分支、`Background Limiter+` 未锚定）

### memctl
- 配置合法性校验：数值范围、`HARD_RECLAIM` 大小格式、`PUSH_KEEP` / `KEEP_CMDLINE` 安全字符
- 前台应用缓存，降低辅助调速器高频 `dumpsys` 调用
- 内存压力非常高时单轮回收上限自动翻倍（最高 50）

### 修复
- `service.sh` Doze 白名单匹配改为精确匹配，避免 `com.tencent.mm` 误匹配子包
- 默认分应用性能档从 `powersave` 改为 `balance`，避免所有应用被强制压到省电档

## fuyun 26w34.2-b (20260819)

命名更改：版本命名规则更改为‘YYwxx-类型’格式，正式版后缀-r，beta测试版为-b，alpha测试版为-a

### 新增辅助调速器（深度空闲压频）
- 前台应用持续低 CPU 占用时（如停留在静态页面），自动把 uperf 各档位 idle 场景的功率预算调低并重启 uperf，压制空闲频率省电
- 恢复条件即时生效：CPU 占用回升 / 切换应用 / 命中白名单 / 切到性能·极速档 / 息屏，任意一项立即还原原调度
- 安全设计：只改 uperf 的 idle 场景参数，触摸瞬间 uperf 自动切 touch 场景，交互性能不受影响；视频解码/地图渲染等持续高占用应用自动豁免
- 参数全可配：`idle_gov.txt`（开关 / 判定间隔 / 进入超时 / CPU 阈值 / 功率预算），白名单 `idle_whitelist.txt` 支持前缀通配
- WebUI 新增辅助调速器卡片（开关与参数配置、深度空闲状态徽标）与调速器白名单管理
- 配置补丁内置格式容错：支持模块自带多行格式与用户改写的单行/空块格式；深度空闲期间手动改过 `uperf.json` 不会被覆盖（日志告警）

## fuyun 0.1 (250818)

- **正式更名 fuyun**，四改自 Nemo，作者追加 05A0706
- WebUI 控制台改用"内置服务同源"方案：管理器点开 WebUI 自动跳转模块自带 http 服务，不再受混合内容拦截
- 其余功能与 Baikal R2P1 (WebUI 版) 一致，详见下方历史

## Baikal R2P1 (WebUI 版)
四改自 Nemo，作者追加 05A0706

### 🎛️ 新增 WebUI 控制台
- Magisk / KernelSU 模块详情页可直接打开 WebUI（本机服务 127.0.0.1:16800）
- 一键切换性能模式（省电 / 均衡 / 性能 / 极速）
- 可视化配置内存优化全部参数（模式 / PSI 阈值 / 间隔 / 空闲淘汰 / 切换回收等）
- 分应用回收策略与白名单在线增删管理
- 操作区：立即回收一轮 / 重启 memctl / 重载配置
- 日志在线查看（mem / screen / uperf）
- API 全量白名单键校验 + 值类型校验，非法输入拒绝

### 🔋 功耗大优化
- **杀进程逻辑重做**：由"每 120s 无差别清理"改为**空闲淘汰**——只清理闲置超过 `IDLE_KILL_MIN`（默认 5 分钟）的应用，杜绝"杀→冷启动→再杀"的耗电循环
- **切换触发回收**：前台应用切换时立即回收切走应用的内存（不杀进程，切回不冷启动）
- **GPU Boost 响应式**：不再锁定最低功率层级/关闭节流，待机 GPU 自然降频，游戏仍可冲最高频
- **轮询降频**：dumpsys 检测 15s→60s、freeze 检测 5s→15s、回收轮询 120s→300s
- **温控策略维持性能优先**：沿用原版禁用 mi_thermald 的设计（满血性能释放），用户可自行取舍
- **回收参数保守化**：PSI 阈值 15→30、每轮 30→10 进程、无收益自动跳过下一轮（防内存抖动）

### 🛡️ 安全与兼容
- **5G/SA 修改自动备份**：modem 配置改前备份到 `/data/adb/uperf_backup`，卸载自动还原
- **KernelSU 原生安装**：新增 `customize.sh`，KernelSU 下跳过音量键交互直接安装
- 手动回收通道 `reclaim_now`（WebUI 按钮 / 终端 echo 均可触发）
- last_used 表防膨胀（超 500 行自动裁剪）
- 卸载按 PID 精确停止服务（不误杀用户其他进程）

### 🐛 修复
- `setup.sh` 的 `abort()` 函数损坏（错误消息当命令执行）→ 重写
- `libcommon.sh` 的 `lock()` 用错变量导致 chown 静默失效 → 修复并支持通配符
- `service.sh` 的 `log()` 无限递归（函数名遮蔽系统 log 命令）→ 改名 `log_msg`
- `crash_recuser` 用 `killall logcat` 误杀用户所有 logcat → 只杀自己启动的实例
- `is_screen_on()` 单字符串判断跨版本不稳定 → 双判断加固
- 息屏省电恢复时硬编码 schedutil 覆盖用户自定义调度器 → 改为备份/还原原始 governor
- doze 白名单每次开机覆盖用户修改 → 仅首次生成
- `powercfg_once.sh` 中 `$CPU` 未定义 → 修正完整路径
- `setup.sh` 首次安装 `mv uperf.json` 报错 → 存在性判断
- 版本号统一（module.prop 与 powercfg.json）
- 清理 service.sh / post-fs-data.sh 约 90 行重复代码与中部无效 shebang
- 全量 shellcheck 清洗（27 个脚本 0 问题）

### 📦 工程化
- `build.ps1` 一键打包（正斜杠条目名 + 关键条目自检 + SHA256 输出）
- 打包格式修复：bsdtar 的 `./` 前缀、.NET 的反斜杠条目名均会导致 unzip 匹配失败 → 标准打包
- 文档补全：README（含 WebUI 章节）/ CHANGELOG / 8+ 调优指南

## Baikal R2P1 
- 适配 8 Gen2
- 更可靠的 Vulkan 开启方式
- 5G-SA 策略优化
- 新网络模块、GPU 模块
- 微信QQ后台优化、息屏优化与 Doze 强制
- 省电模式能效重做

## Baikal R2
- 适配 8+ Gen1
- 优化掉帧、提升均衡模式能效
