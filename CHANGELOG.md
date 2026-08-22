# 更新日志

## fuyun 26w34.7-b (202608222) 修复补丁

### 修复: action.sh 音量键失效
- 按键解析不再依赖 getevent 输出字段位置（原写法在带/不带时间戳的输出格式下都取不到 KEY_VOLUMEUP/DOWN，导致永远显示"未检测到按键"）
- 只认 DOWN 按下事件，过滤抬手 UP；无 resetprop 时自动退回 setprop，getevent 缺失时优雅跳过
- 安装流程补齐 action.sh 的可执行权限（zip 内权限为 0666，Magisk 直接执行 action.sh 会 Permission denied）

### 修复: WebUI 无法使用
- **zip 权限修复**：所有脚本/二进制重新打包为 0755（原包内全是 0666，httpd 执行 CGI 需要 +x，缺失时全部 API 返回 403）
- **customize.sh 兼容 Magisk**：Magisk v23+ 存在 customize.sh 时优先于 update-binary 执行，原脚本对 Magisk 直接 exit 0 导致 setup.sh 未运行（配置未复制、权限未设置）；现在 KSU/Magisk 统一走 setup.sh
- **webuid.sh 加固**：端口检测改为读 /proc/net/tcp（不依赖 nc）；HTTP 自检兼容 wget/curl 缺失的设备；启动时自愈 CGI 执行权限；支持 httpd 前台/daemon 两种模式并可按命令行特征停止；启动失败自动回退不带 -f 重试
- **日志 API JSON 修复**：log.sh 在管道子 shell 中维护逗号标志导致多行日志输出非法 JSON，改为临时文件 + 重定向

## fuyun 26w34.7-b (202608222)

### 新增平台支持: 骁龙 8 Gen3 / 8 Elite / 8 Elite Gen5 (8e5)
- 新增配置 `sdm8g3.json`（8 Gen3/SM8650，1+5+2：X4 3.3G + A720×5 + A520×2，Adreno 750）
- 新增配置 `sdm8e.json`（8 Elite/SM8750，2+6：2×Oryon 4.32G + 6×Oryon 3.53G，Adreno 830）
- 新增配置 `sdm8e5.json`（8 Elite Gen5/8e5/SM8850，第三代 Oryon 2+6，4.6G 级，参数为占位初版）
- 新平台参数基于规格书起保守初版，未实测调参，欢迎真机反馈迭代（反馈内容见 docs/tuning-8e.md）

### 平台识别增强
- 代号映射：`pineapple`→8 Gen3、`sun`→8 Elite、`shark`→8 Elite Gen5（候选）
- **布局探测兜底**：代号认不出时按 CPU 簇布局自动识别（单核大核 3 簇 → 8G3 系；双核 Prime 簇 2 簇 → 8E 系），按最高频区分 8 Gen3/8s、8 Elite/8 Elite Gen5
- 安装流程 `setup.sh` 在代号识别失败时自动走布局探测，仍失败才 abort

### 簇识别修复（8 Elite 双核 Prime 簇兼容）
- `cluster_of_policy` 大核判定从「单核且最高频」改为「包含全局最高频核心的簇」，8 Elite 的 2 核 Prime 簇（CPU6-7）正确识别为大核
- WebUI 频率范围 CGI 同步修复

### 修复: CPU 频率范围 (小/中/大核 min/max) 失效问题
- 频点校验改为**设备实测优先**（读 scaling_available_frequencies，内置表仅兜底）：不再因内置频点表与设备实际频点不一致导致全部设置静默失效
- **非法频点自动吸附**：min 向上取最近支持频点、max 向下取最近支持频点，超出硬件范围忽略并记日志；写入被内核拒绝时逐簇显式记日志
- bind-mount 失败时显式记录并尝试只读锁定兜底；逐 policy 生效状态写入 freq_range.state
- WebUI「CPU 频率范围」：下拉框显示设备实测频点；设置任意 min/max 自动启用总开关；按 小核/中核/大核 显示实际频率与冻结生效状态（✓/✗）

### 新增: 主流游戏特调 (按引擎分组)
- sdm8g2.json / sdm8+.json 新增/扩充游戏规则块：
  - **Unity 系**: 王者荣耀 / 英雄联盟手游 / 金铲铲之战 / 穿越火线手游 / 使命召唤手游 / 暗区突围 / QQ飞车手游 / 火影忍者手游 / 元梦之星
  - **米哈游定制 Unity**: 原神 / 崩坏：星穹铁道 / 绝区零 / 崩坏3
  - **网易 Unity**: 蛋仔派对 / 第五人格 / 光遇 / 逆水寒手游 / 永劫无间手游 / 阴阳师 / 梦幻西游手游
  - **UE4/UE5**: 和平精英 / 幻塔 / 三角洲行动
- 特调策略：渲染/游戏线程高优 + 动态升频（dynamic_boost），后台工作线程/音频/网络压小核限流 —— **帧率更稳的同时省电**
- 按引擎适配线程名：Unity（UnityMain / RenderThread / Job.Worker）、UE（GameThread / RenderThread / RHIThread / WorkerThread）
- perapp_powermode.txt 预置 30+ 款游戏 = performance 档（前台自动解锁大核与高功率预算）

### 其他
- 新增频率表兜底 `freq_table_8g3/8e/8e5.txt`（设备实测优先，仅兜底）
- 游戏特调规则随新平台布局自动适配：8 Gen3 小核为 core0-1；8 Elite 无小核，后台限流改压低段性能核

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
