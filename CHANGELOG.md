# 更新日志

## fuyun 26w34.4-b (20260820)

###新增中文名：**浮云（fuyun）**。优化 sdm8+ 和 sdm8g2 在各模式的核心分配，并新增 WebUI 高级设置与 Doze 白名单管理。

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

## Baikal R2P1 (原版)
- 适配 8 Gen2
- 更可靠的 Vulkan 开启方式
- 5G-SA 策略优化
- 新网络模块、GPU 模块
- 微信QQ后台优化、息屏优化与 Doze 强制
- 省电模式能效重做

## Baikal R2
- 适配 8+ Gen1
- 优化掉帧、提升均衡模式能效
