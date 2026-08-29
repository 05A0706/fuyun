# fuyun (26w34.6-B) 代码审查报告

> 审查范围：module 全部 shell 脚本（入口/服务/库）、WebUI（cgi-bin + app.js + index.html）、安装/卸载流程，约 8400 行。
> 评级：🔴 高（应尽快修复）｜🟡 中（有实际影响）｜🟢 低（质量/健壮性改进）

---

## 一、安全（最高优先级）

### 1.1 🔴 WebUI API 以 root 运行且无任何认证
- **位置**：`script/webuid.sh`（httpd 以 root 监听 127.0.0.1:16800）、`webroot/cgi-bin/lib.sh`（`json_headers` 设置 `Access-Control-Allow-Origin: *`）、全部 cgi-bin 脚本
- **影响**：Android 不隔离回环接口——**设备上任意第三方 App 都能 `curl http://127.0.0.1:16800/cgi-bin/...`**，以 root 身份：覆盖 `uperf.json`（config_file.sh save）、改内存回收策略、重启/杀服务、锁 CPU 频率。`CORS: *` 又把攻击面进一步放宽。
- **修改理由/建议**：启动时生成随机 token 写入仅 root 可读文件（如 `/data/adb/uperf/.token`），CGI 统一校验 `?token=` 或 `X-Token` 头；移除 `Access-Control-Allow-Origin: *`（页面与 API 已同源，无需 CORS）。

### 1.2 🔴 插件机制 = 共享存储到 root 命令执行的直通通道
- **位置**：`script/plugin.sh`（`run_json_plugin` 将 JSON 的 `command` 字段交给 `sh -c`；插件目录 `/sdcard/Android/yc/uperf/plugins/`）
- **影响**：`/sdcard/Android/yc/` 是共享存储目录，**任何持有存储权限的 App 都能放入一个 JSON（`{"command":"..."}`）或 .sh**，在 apply/clear/boot 阶段获得 root 任意命令执行。JSON 的 `command` 字段让攻击者甚至不需要构造脚本文件。
- **修改理由/建议**：至少做其一——① 把插件目录迁到 `/data/adb/uperf/plugins`（仅 root 可写）；② 取消 `command` 字段，只允许执行 `plugins/` 目录内的 .sh；③ 首次启用插件需用户在 WebUI 显式确认（白名单机制）。

### 1.3 🔴 WebUI 存在 XSS：innerHTML 拼接 + CGI 输出未转义
- **位置**：`webroot/app.js` 的 `loadWhitelist / loadApps / loadDoze / loadGovWhitelist`（`li.innerHTML = '<span class="pkg">' + it.pkg + ...`）；对应 CGI `whitelist.sh / apps.sh / idle_whitelist.sh` 的 `list` 分支输出未调 `json_escape`（对比 `doze.sh`、`status.sh` 已做转义）
- **影响**：白名单/apps 文件在共享存储上，可被其他 App 直接写入（或经 1.1 的 API 写入）含 HTML/JS 的行；WebUI 打开时经 innerHTML 执行任意 JS，再借页面调用 root API，形成完整攻击链。
- **修改理由/建议**：前端一律 `document.createElement` + `textContent`；CGI list 分支统一过 `json_escape`（顺带修复含引号内容破坏 JSON 的问题）。

### 1.4 🟡 `config_file.sh` 对 uperf.json 的校验过弱
- **位置**：`webroot/cgi-bin/config_file.sh` save 分支（仅检查首字符 `{`、尾字符 `}`）
- **影响**：写坏 JSON（缺引号/多余逗号等）后 uperf 与 `memctl.sh` 的 `restart_uperf` 都无法启动，调度整个失效；POST body 也无大小限制（可被塞满磁盘）。
- **修改理由/建议**：用 `toybox`/busybox 的 json 工具或简单括号配对校验，失败拒绝保存（已有 .bak 兜底但仍应前置校验）；对 POST body 加上限（如 1MB）。

### 1.5 🟡 lock_val 将内核节点临时 chmod 0666
- **位置**：`script/libcommon.sh lock_val`、`common/post-fs-data.sh lock_val`
- **影响**：写窗口期内节点对全体进程可写；写完 `chmod 0444` 锁定，风险被限制，但仍属于不必要的权限放大。
- **修改理由/建议**：保持 root 执行环境本身即可，改为 `echo ... >`（root 不需要 0666）；确需 bind-mask 的走 `mask_val`。

### 1.6 🟢 post-fs-data 阶段 remount /vendor、/system、/product 为 rw 并改写 modem 配置
- **位置**：`common/post-fs-data.sh` 79–136 行
- **影响**：固件级改动，失败时（remount 失败）无任何提示；属固有风险，已有备份+卸载还原逻辑（见 2.4 的备份删除缺陷）。
- **建议**：失败时写日志；考虑改为仅改 persist 属性、不动文件。

---

## 二、错误与缺陷

### 2.1 🟡 `setup.sh` 两处 test 语法错误，异常输入下中断安装
- **位置**：`script/setup.sh` 192 行 `while [ $choice =  ]; do`、236 行 `[ $(getprop ro.system.build.version.sdk) -lt 29 ] && ... && abort`
- **影响**：192 行 `$choice` 未加引号，靠 `[ = ]` 的巧合语义才能工作，按键读到异常值时直接 "binary operator expected"；236 行 `getprop` 输出为空时变成 `[ -lt 29 ]`，test 语法错误导致后续 `abort` 不执行且安装日志混乱。
- **修改理由/建议**：`while [ -z "$choice" ]; do`；`sdk=$(getprop ...); case "$sdk" in ''|*[!0-9]*) abort "! Cannot read API level";; esac; [ "$sdk" -lt 29 ] && abort "..."`（并给 abort 传消息）。

### 2.2 🟡 `apps.sh` 的 sed 正则未转义包名（与 whitelist.sh/doze.sh 行为不一致）
- **位置**：`webroot/cgi-bin/apps.sh` add/del 分支 `sed -i "/^$PKG /d"`（`PKG` 含 `.`，是正则元字符）
- **影响**：`com.foo` 会匹配 `comXfoox ...` 等 行；同前缀包名可能误删他人条目。whitelist.sh / doze.sh / idle_whitelist.sh 均已做 `sed_escape`，唯独 apps.sh 漏了。
- **修改理由/建议**：复用 `sed_escape` 后再拼 sed 模式；`memctl.sh` 中 `touch_last_used / get_last_used` 的 `sed -i "/^$1 /d"`、`grep "^$1 "`、`pgrep -f "^$pkg"` 同理（包名点号未转义，建议加同一个转义工具函数）。

### 2.3 ~~`freq_limit.sh` 默认配置模板文本损坏~~（复查后撤销：实际文本完整，初判有误）
- **位置**：`script/freq_limit.sh` 136–147 行 `init_defaults` 生成的 `freq_range.txt`
- **结论**：逐行 grep 复核后确认模板注释完整，无需修改。保留此条作为复查记录，避免后续误改。

### 2.4 🟡 卸载还原流程可能永久丢失 modem 原始备份
- **位置**：`uninstall.sh` on_remove（先 cp 还原、后 `rm -rf "$BACKUP_DIR"`）
- **影响**：若还原时 remount 失败导致 `cp -af` 失败，备份随后仍被删除 → 出厂 `network_mode.xml` 永久丢失。
- **修改理由/建议**：逐个文件还原后校验（`cmp -s`），全部成功才删除备份；失败的保留并输出提示。

### 2.5 🟡 无 timeout 环境下插件可阻塞频率控制主循环
- **位置**：`script/plugin.sh`（`command -v timeout` 不存在时直接 `sh -c`/`sh` 无超时）；`script/freq_limit.sh` apply_all 同步调用 `run_plugins "apply"`
- **影响**：一个死循环插件会让 freq_limit watch 循环停摆、也拖住 CGI 的 set 请求。
- **修改理由/建议**：Android 自带 toybox timeout，可改为绝对路径 `/system/bin/timeout` 兜底；或将 `run_plugins` 移到后台子 shell 执行。

### 2.6 🟢 其余健壮性问题
| 位置 | 问题 | 建议 |
|---|---|---|
| `webroot/cgi-bin/status.sh` 18–19 行 | `MEMAVAIL` 为空时 `$((MEMAVAIL/1024))` 算术报错（虽有 `${MEMAVAIL_MB:-0}` 兜底输出） | 先判空再算术 |
| `webroot/cgi-bin/lib.sh` `json_ok/json_err` | msg 直接拼进 JSON，含引号的 key/value 会破坏响应（多处 `invalid key: $KEY` 把用户输入回显） | 统一过 `json_escape` |
| `common/post-fs-data.sh` 37 行 | `[ "$(getprop ro.build.version.sdk)" -lt 34 ]` 空值时 test 报错 | 同 2.1 方式加固 |
| `script/powercfg_once.sh` 33 行 | `rmdir /dev/cpuset/foreground/boost` 无错误处理（目录非空/不存在时报错进日志） | `rmdir ... 2>/dev/null` |
| `uninstall.sh` 67 行 | `cp -af $USER_PATH/perapp_powermode.txt` 未判存在、未引号 | `[ -f ... ] &&` + 引号 |
| `script/webuid.sh` `port_in_use` | 依赖 `toybox nc -z`，部分 ROM 的 nc 不支持 -z，会误判端口空闲重复启动 | 改用探测 httpd 自检结果判断 |

---

## 三、性能

### 3.1 🔴 `service.sh` 息屏压频/亮屏恢复延迟最长 60 秒
- **位置**：`common/service.sh` 主循环 `SLEEP_INTERVAL=60`
- **影响**：亮屏后最长 1 分钟内 CPU 仍被锁在 800MHz + powersave——**解锁滑动、打开应用的黄金时段恰好在被压制状态**，这是用户可直接感知的卡顿。
- **修改理由/建议**：息屏→压频方向可保持长间隔；亮屏方向轮询加密（如息屏态每 2s 检测一次亮屏，代价极小），或干脆复用 `freq_limit.sh` 的 `FREQ_OFFSCREEN` 机制（它已是 15s 检测 + 掩码方案），把 service.sh 这段删掉——见 3.3。

### 3.2 🟡 memctl 每轮对 /proc 全量扫描 3 次 + 白名单逐进程重读
- **位置**：`script/memctl.sh` `collect_targets` / `idle_kill` / `zram_push_idle`（三个函数对每个 pid 各自 `cat cmdline` + `stat` + 白名单文件遍历）
- **影响**：每轮几百个进程 × 每 pid 多次 fork（`tr`/`stat`/`awk`），加上 `is_whitelisted` 每次重读白名单文件，CPU/电量开销可观（INTERVAL=300 时尚可，但与 zram/idle 混合后单轮 fork 数达数千）。
- **修改理由/建议**：一轮扫描中把 `pid cmdline pkg uid` 收集一次进变量复用；白名单在 `load_cfg` 时读入内存（一个字符串变量 + case 匹配），消除 O(进程×白名单行) 的文件重读。

### 3.3 🟡 息屏压频逻辑三处重复实现且互相覆盖
- **位置**：`common/service.sh`（governor=po­wersave + 800MHz + 关大核）、`script/freq_limit.sh`（FREQ_OFFSCREEN 掩码限频）、`common/post-fs-data.sh` 的 GPU 部分
- **影响**：两者默认都开启。service.sh 亮屏恢复时 `echo cpuinfo_max_freq > scaling_max_freq` 会与 freq_limit 的 bind-mask 打架（掩码虽挡住内核，但 clear 状态、恢复 governor 时仍可能覆盖用户/uperf 设置的调度器——`BACKUP_FILE` 在息屏瞬间重建，恢复的是"息屏那一刻"而非用户原始值）。
- **修改理由/建议**：选定一个机制（建议保留 freq_limit.sh 的掩码方案），service.sh 的 optimize/restore_cpu_power 整段删除或默认关闭；governor 备份只在首次进入时建立，不做每轮覆盖。

### 3.4 🟢 其它低效点
| 位置 | 问题 | 建议 |
|---|---|---|
| `webroot/cgi-bin/status.sh` | 每次请求跑 `dumpsys activity`（前台应用）+ 多次 grep；app.js 每 15s 自动刷新 | dumpsys 结果短 TTL 缓存（参考 memctl 的 FG_CACHE），或 15s 刷新仅刷新轻量字段 |
| `script/freq_limit.sh` watch 循环 | 每 15s 调 `screen_on`（一次 dumpsys power）+ 重复 `load_cfg`（apply_all 内已读过） | 去掉循环里的重复 load_cfg；dumpsys 可 60s 一次或复用 |
| `script/powercfg_once.sh` 233–249 行 | disable_kernel_boost 等 5 个函数在 restart_userspace_boost 前后被调用两次 | 若非有意"二次确认"，删掉第二组调用 |
| `webroot/app.js` 保存配置 | N 个字段串行 await，一次保存发 N 个请求 | 改为批量接口或并行 Promise.all |
| `script/powercfg_once.sh` 中部 | 253–257 行重复 source pathinfo/libcommon/libpowercfg/libcgroup | 删除（文件头已 source，重复 source 会重置 libcommon 的全局变量） |

---

## 四、代码质量

### 4.1 🟡 重复实现四处散落
- `sed_escape`：whitelist.sh / doze.sh / idle_whitelist.sh 三份相同定义 → 上移到 `lib.sh`。
- `wait_until_login`：`script/libcommon.sh` 与 `uninstall.sh` 两份 → uninstall 直接 source libcommon。
- `is_screen_on / screen_on`：service.sh、memctl.sh、freq_limit.sh、status.sh 四份相同实现 → 放入 libcommon.sh。
- `policies_info`/大核最大频率扫描：status.sh 与 freq_limit.sh 各一份。
- 键值写配置（set_cfg / set_idle_cfg.sh 28–40 行 / freq_limit.sh 92–104 行）三处手写同一 while-replace 循环 → 提炼为 lib.sh 的 `set_kv_file`。

### 4.2 🟢 命名与可读性
- `freq_limit.sh` 把日志写进 `mem_log.txt`（`LOG="$USER_PATH/mem_log.txt"`）——频率控制日志混进"内存服务"日志，排查困难；建议 `fuyun.log` 统一或按模块分文件。
- `common/service.sh` 单文件 266 行混合日志、白名单、CPU 控制、主循环，且与模块其它部分风格割裂（新代码集中在 script/，这段是老的独立实现）——建议拆出 `script/screen_saver.sh` 并纳入统一日志。
- `script/setup.sh` 131–181 行硬编码大段更新日志文案，随版本膨胀；已存在 `CHANGELOG.md`，安装时改为 `cat CHANGELOG.md` 或只打一行版本号。
- `action.sh` 与 `setup.sh` 各自复制了一份 getevent 按键读取逻辑 → 提取公共函数。
- `libcommon.sh log()` 会追加到 `$LOG_FILE` 且无轮转，与 memctl/freq_limit 自带 rotate 的 log 三种实现并存。

### 4.3 🟢 shell 语法规范
- 多处未加引号的变量展开（`rm -rf $USER_PATH`、`cp -af $MODULE_PATH/config`、`echo ... > $LOG_FILE` 等，模块路径固定时无害，但按惯例应统一加引号）。
- `script/setup.sh` 221 行仍在用反引号 + 大写单字母风格变量（`SOC=`、`ROMV=`），与同文件 `$(...)` 风格不一致。
- `script/powercfg_main.sh` 的 `case "$1"` 里 `action` 变量赋值后从未使用（21 行）。

---

## 五、修复优先级（从高到低）

1. **[安全] WebUI root API 加 token 认证，移除 `CORS: *`**（1.1）——当前任意 App 可 root 级操控设备。
2. **[安全] 插件目录迁出共享存储 / 移除 JSON `command` 字段**（1.2）——共享存储写入即 root 执行。
3. **[安全] 修复 XSS 链：app.js 去掉 innerHTML 拼接 + 3 个 CGI list 输出补 json_escape**（1.3）。
4. **[体验/性能] 息屏压频恢复延迟 60s 问题：亮屏方向高频轮询，并消除与 freq_limit 的双重实现**（3.1 + 3.3）——直接影响日常流畅度。
5. **[缺陷] setup.sh 两处 test 语法加固**（2.1）——异常环境下安装中断。
6. **[缺陷] 卸载还原 modem 配置校验后再删备份**（2.4）——避免不可逆数据丢失。
7. **[缺陷/安全] config_file.sh 的 JSON 前置校验 + POST 大小限制**（1.4）。
8. **[缺陷] apps.sh 补 sed_escape，memctl 包名转义统一**（2.2）。
9. **[缺陷] 修复损坏的 freq_range.txt 默认模板文案**（2.3）。
10. **[缺陷] 插件强制 timeout 兜底，避免阻塞 freq_limit 主循环**（2.5）。
11. **[性能] memctl 单轮合并 /proc 扫描 + 白名单读入内存**（3.2）。
12. **[质量] 公共函数上移 lib.sh / libcommon.sh（sed_escape、wait_until_login、is_screen_on、set_kv_file）**（4.1）。
13. **[质量] freq_limit 日志独立文件、service.sh 拆分、setup.sh 更新日志外移**（4.2）。
14. **[健壮性] 2.6 表中各小项（status.sh 空值、json_ok 转义、webuid 端口探测等）**。

---

## 附：值得肯定的设计
- memctl.sh 的配置校验非常完整（枚举/数值边界/字符集白名单、防注入意识明确）；`read_cpu_stat` 对 comm 含空格与 PID 复用的处理正确。
- freq_limit.sh 的 bind-mount 掩码幂等方案与 per-policy 独立掩码源设计清晰。
- 前台包名 TTL 缓存（FG_CACHE）、last_used 表防膨胀、日志轮转都有考虑。
- CGI 端大部分写入接口有键白名单 + 值校验（除了 1.1 的认证缺失，注入面基本堵住了）。

---

## 六、修复记录（2026-08-29 第二轮）

以下问题已在本次提交中修复（全部通过 `sh -n` / `node --check` 语法校验）：

| # | 文件 | 修复内容 | 对应报告条目 |
|---|---|---|---|
| 1 | `webroot/cgi-bin/lib.sh` | 移除 `Access-Control-Allow-Origin: *`；`json_ok/json_err` 统一经 `json_escape` | 1.1（部分）/ 2.6 |
| 2 | `webroot/app.js` | 所有列表渲染由 `innerHTML` 拼接改为 `createElement`+`textContent`，消除 XSS 注入点 | 1.3 |
| 3 | `whitelist.sh` / `idle_whitelist.sh` / `apps.sh` | list 输出补 `json_escape`；apps.sh add/del 补 `sed_escape` | 1.3 / 2.2 |
| 4 | `webroot/cgi-bin/status.sh` | `MEMAVAIL` 空值/非数字保护 | 2.6 |
| 5 | `script/setup.sh` | `[ $choice = ]` → `[ -z "$choice" ]`；SDK 版本读取加空值/非数字保护并给 abort 传消息 | 2.1 |
| 6 | `uninstall.sh` | modem 配置还原逐项校验成功后才删备份，失败保留备份并写日志 | 2.4 |
| 7 | `common/service.sh` | 息屏态轮询间隔改为 2s（亮屏仍 60s），修复亮屏后 CPU 恢复最长延迟 1 分钟问题 | 3.1 |

未修复（遗留，需更大改动或产品决策）：
- 1.1 WebUI root API 认证：纯前端无法彻底解决，需 token/调用方校验方案（建议后续做）；
- 1.2 插件目录迁出共享存储：涉及用户习惯，建议下版本迁移至 `/data/adb/uperf/plugins`；
- 3.2 memctl /proc 扫描合并、3.3 息屏压频双实现去重：涉及服务架构，建议单独评审。

## 七、WebUI 液态玻璃重构记录

- 参考风格：Kyant0/AndroidLiquidGlass（Glass Slider / Glass Bottom Bar）。
- 新增底部悬浮导航（状态/内存/频率/管理 四页签），页面切换带弹性过渡动画；
- 新增 Glass Slider：磨砂轨道（inset 阴影+渐变进度）、玻璃拇指（径向高光+内阴影+边缘高光），拖动时 `scale(1.28)` 弹性放大（spring 缓动）+ 光环；
- 卡片/顶栏/Toast 统一玻璃材质：`backdrop-filter: blur(22-26px) saturate(1.7-1.8)` + 半透明底色 + 高光边框 + 内阴影；背景加彩色光斑供玻璃"折射"；
- `@supports` 降级：不支持 backdrop-filter 的旧 WebView 提高底色不透明度保证可读性；
- 数字输入全部改为滑块，其中 FREQ_CAP / FREQ_OFFSCREEN_CAP / IDLE_POWER_W 为映射型滑块（整数刻度→API 合法值），杜绝拖出非法配置；
- 小屏适配（<480px：紧凑 label、单列网格、导航压缩）+ `env(safe-area-inset-bottom)` 手势区适配。
