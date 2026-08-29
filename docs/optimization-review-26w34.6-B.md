# fuyun (26w34.6-B) 优化审查报告

> 审查维度：**性能 / 可读性 / 可维护性 / 资源占用**（不含安全议题，安全见 `code-review-26w34.6-B.md`）
> 审查范围：`common/`、`script/`、`webroot/`（cgi-bin + app.js + style.css）、安装卸载流程，约 4300 行 shell + 660 行 JS。
> 约束：所有建议**不改变业务逻辑与外部接口**，**不引入原代码未使用的新技术或第三方库**（awk / sed / case / /data/local/tmp 缓存文件 / bind-mount 均为本仓现有手法）。
> 优先级：🔴 P0（影响大且直接可感知）｜🟡 P1（有实际开销）｜🟢 P2/P3（质量与健壮性）

---

## 🔴 P0

### 1. memctl 单轮对 `/proc` 全量扫描 3 次，且每个进程重复重读白名单文件

- **位置**：`script/memctl.sh` `collect_targets`(344) / `idle_kill`(282) / `zram_push_idle`(435)，以及 `is_whitelisted`(191)、`get_last_used`(267)
- **当前问题**
  - 三个函数各自独立 `ls /proc | grep -E`，对同一批进程重复扫描 3 遍。
  - 每个 pid 至少 fork：`tr`(1) + `stat`(1) + `is_whitelisted` + `is_idle`。
  - `is_whitelisted` 内部对**白名单每一行**执行 `line=$(echo "$line" | sed 's/#.*//' | xargs)` → 每行约 2 次 fork；默认白名单 14 行（7 注释 + 7 包名，注释行也照样 fork）≈ 28 次 fork，**每个进程调一次**。
  - `is_idle` → `get_last_used` = `grep | awk | tail` = 3 次 fork，**每个进程调一次**。
  - 按 400 个进程估算：单轮 ≈ (30 + 33 + 36) × 400 ≈ **4 万次 fork**，按 1.5ms/次 ≈ 60 秒 CPU，摊到 5 分钟轮询周期即**持续占用约 20% 单核**——一个省电模块自身的常驻开销。
  - `collect_targets` 一轮内最多被调用 2 次（手动回收 + 压力回收），峰值为上述估算的 1.5 倍。
- **改进建议**（分两步，均为现有手法）
  1. **白名单入内存**：`load_cfg` 时把 `mem_whitelist.txt` 读进一个变量（`WL_RULES=" pkg1 pkg2 com.tencent.* "`），匹配改用 `case "$pkg" in $WL_RULES)` 与前缀通配 `case "$pkg" in ${prefix}*)`，零 fork。同理处理 `idle_whitelist.txt`。
  2. **单次扫描复用**：一轮只做一次 `/proc` 遍历，用**一个 awk 进程**一次性输出 `pid pkg uid` 到变量（awk 已在 `patch_idle_power`/`freqs_json` 中大量使用），后续三个消费者共享这份表；`last_used.txt` 同样一次性读入变量做字符串匹配，替代逐 pid 的 `grep|awk|tail`。
- **预期收益**：单轮 fork 数从约 4 万降到数百（每 pid 仅剩 awk 内部的读文件），**降幅约 2 个数量级**；轮询周期内的常驻 CPU 占用从 ~20% 降到可忽略；省下的正是本模块主打的续航。

### 2. 息屏压频两套实现互相踩踏：service.sh 亮屏恢复会静默解除用户的频率上限

- **位置**：`common/service.sh` `restore_cpu_power`(203-211) 与 `script/freq_limit.sh` `apply_all`(370-381)
- **当前问题**
  - `freq_limit.sh` 用 `mount --bind $MASK_MAX_PFX<policy> <policy>/scaling_max_freq` 把上限冻结在掩码文件上；掩码生效后，往 `scaling_max_freq` 路径写值 = **写进掩码文件本身**。
  - `restore_cpu_power` 亮屏时无条件执行 `echo "$max_freq" > <policy>/scaling_max_freq`（`max_freq` 取自 `cpuinfo_max_freq`）→ 把硬件最大频率写进了掩码文件 → **用户设置的 FREQ_CAP 被静默抹掉**。
  - 更糟的是频率限制**不会自愈**：`apply_all` 的状态比对是 `want`(配置) vs `cur`(state 文件) + `mask_mounted`，三者都没变 → 直接 `return 0`，上限保持解除状态，直到用户再次改动配置才会重新生效。
  - 息屏方向同样冲突：service.sh 写 800000 进掩码，干扰 `FREQ_OFFSCREEN_CAP`。
  - `service.sh` 自己的注释（53-56 行）已经写明「频率限制的息屏自动限频可替代本段压频」，但两者**默认同时开启**。
- **改进建议**
  - 首选：让 `service.sh` 的 `optimize_cpu_power / restore_cpu_power` 在 `freq_limit` 掩码挂载时整段让位——函数入口加一个 `mask_mounted` 检测（`grep -q fuyun_freq_ /proc/mounts`，与 `freq_limit.sh` 同款），命中即跳过 CPU 写频部分，只留 Doze 白名单逻辑。
  - 或者（更彻底，涉及产品决策）：把息屏压频统一收敛到 `freq_limit.sh` 的 `FREQ_OFFSCREEN` 机制，`service.sh` 只保留 Doze 白名单应用。
  - 无论选哪条，`BACKUP_FILE` 都应改为「首次建立、之后不覆盖」，避免每轮息屏重建备份导致恢复的是"息屏那一刻"的值。
- **预期收益**：消除一个用户可感知的功能失效（设了上限却被静默清掉）；去掉重复的息屏逻辑后，每次亮/灭屏少写 8~16 个 sysfs 节点；两套机制不再互相覆盖，后续排查路径唯一。

### 3. service.sh 息屏态每 2 秒跑一次 `dumpsys power`

- **位置**：`common/service.sh` 266-270 行（`sleep 2`）+ `is_screen_on`(108)
- **当前问题**：息屏时以 2s 间隔轮询屏幕状态，每次 `dumpsys power | grep` = 2 次 fork，且 `dumpsys power` 是一次进入 `system_server` 的 binder 调用并输出大段文本。折算 **1800 次 dumpsys / 小时息屏时间**。这与模块的省电视角完全相反——设备越待机，本模块越忙。
- **改进建议**
  - 采用条目 2 的方案后，`service.sh` 主循环本身可以退化为长间隔（Doze 白名单只在开机应用一次，主循环无事可做）；
  - 若仍需保留轮询：把判定间隔提到 15s，并与 `freq_limit.sh` 的 15s 巡检**合并为一次检测、结果共享**（写一份 `/data/local/tmp/fuyun_screen_state`，两边读取，与现有 `/data/local/tmp/fuyun_freq_*` 掩码同目录同手法）。
- **预期收益**：息屏期间 dumpsys 调用量下降约 90%（2s→15s）到 100%（整段移除）；减少 system_server 的无谓唤醒，直接反哺待机续航。

### 4. WebUI 前端：15s 定时刷新 + 首屏 11 个并发请求 + 保存时 N 个串行请求

- **位置**：`webroot/app.js` 663 行 `setInterval(refreshStatus, 15000)`、652-662 行初始化、280-306 / 309-332 / 335-357 / 395-420 行四个保存函数
- **当前问题**
  - `refreshStatus` 每 15s 触发一次 `status.sh`，而 `status.sh` 内含 `dumpsys activity activities`（重量级 binder 调用）+ 2 次 `pgrep` + 每 policy 一次 `cat` + 20 余次 `grep|head|cut`（见条目 6）。**页面开着就一直烧，切到后台也不停**（无 `document.hidden` 判断）。
  - 首屏并发 11 个请求（status / freq_range / apps / whitelist / gov-whitelist / doze / 4 × config_file / log），每个都是一次 sh + `source lib.sh` 的完整 CGI 进程。
  - 保存配置是**串行 await**：内存配置 9 个字段 = 9 次往返，每次都完整重写一遍配置文件。绝大多数场景用户只改 1 个字段，却要付 9 次写文件的代价，且 UI 要等 9 个 RTT 才反馈。
- **改进建议**
  - `setInterval` 回调开头加 `if (document.hidden) return;`——零接口变更，一行生效。
  - 保存时**先 diff 再提交**：`refreshStatus` 已经把当前值灌进表单，保存前与"初始值"比对，跳过未变更字段。典型场景从 9 个请求降到 1 个。
    - 注意：不要改成 `Promise.all`——同一批 key 都写 `mem_config.txt`，并发会相互覆盖丢数据。串行 + diff 是正确解。
  - 首屏的 4 个 `loadAdvFile`（高级设置）改为**懒加载**：用户切到「高级设置」页签时才发起，首屏请求数 11 → 7。
- **预期收益**：典型保存操作延迟降低约 80%；页面后台驻留时后端请求降到 0；首屏 CGI 进程数减半，模块安装目录下的 WebView 打开更快。

### 5. `powercfg_once.sh` 五个初始化函数整组执行两遍，随后又重复 source 五个库

- **位置**：`script/powercfg_once.sh` 233-249 行（重复调用）、252-257 行（重复 source）
- **当前问题**
  - `disable_kernel_boost / disable_hotplug / unify_sched / unify_devfreq / unify_lpm` 在 233-237 行执行一次，又在 245-249 行原样执行第二次。全文件共 77 处 `lock_val/mutate/mask_val/lock` 调用，每次调用含 `chown` + `chmod` + 写值 + `chmod` = 4 次操作（3 次 fork），且大量参数是 glob（一次展开几十个节点）。**开机时这 77 处被跑了两遍**，开机耗时与日志体积直接翻倍。
  - 252-257 行把文件头（20-24 行）已经 source 过的 `pathinfo.sh / libcommon.sh / libpowercfg.sh / libcgroup.sh` 又 source 一遍。除了纯粹的重复开销，这还是一个维护陷阱：任何人在库里新增可变状态，都会在这里被静默重置。
- **改进建议**
  - 若第二组是有意为之的"二次确认"（某些厂商服务会抢写节点），请在代码里写明原因注释，并把它改成只重跑真正需要加固的子集；否则直接删除 245-249 行。
  - 删除 252-257 行的重复 source；`libsysinfo.sh`（第 257 行）确实只在后面用到，把它上移到文件头的 source 区统一即可。
- **预期收益**：开机阶段减少约 77 次节点写 + 200+ 次 fork，开机耗时与 `initsvc.log` 体积显著下降；消除库状态被意外重置的隐患。

---

## 🟡 P1

### 6. `status.sh` 每次请求执行 20+ 次 `grep|head|cut` 并跑一次重量级 dumpsys

- **位置**：`webroot/cgi-bin/status.sh` 23-29、50-54、64-67、75-80、41-43 行
- **当前问题**：15 个配置键每个都是 `grep ... | head -n 1 | cut -d= -f2` = 3 次 fork（另有 4 次 `grep -q`），加上 per-policy 循环与 `dumpsys activity activities`。单次请求 ≈ 60+ fork + 1 次 binder 调用；被前端每 15s 调用一次（条目 4）。
- **改进建议**
  - 用**单个 awk 进程**一次读入三个配置文件并输出全部键值（awk 已是本仓既有依赖），把 ~45 次 fork 压到 1 次。
  - 前台应用 `dumpsys` 结果做短 TTL 缓存：写入 `/data/local/tmp/fuyun_fg_cache`（与现有 `/data/local/tmp/fuyun_freq_*` 同目录），5~8 秒内的重复请求直接读缓存。`memctl.sh` 的 `FG_CACHE`（8s TTL）已经是同一套思路，复用即可。
- **预期收益**：单次 `status.sh` 的 fork 数下降约 80%；15s 轮询的实际开销降到几乎为零。

### 7. `apply_doze_whitelist` 对每个白名单包名跑一次全量 `pm list packages`

- **位置**：`common/service.sh` 115-128 行
- **当前问题**：循环体内执行 `pm list packages | grep -q "^package:$package$"`。默认白名单 7 个包 → **7 次全量 `pm list packages`**，每次都是一次 binder 调用并返回数百行文本，全部发生在开机阶段。
- **改进建议**：把 `pm list packages` 提到循环外执行一次，结果存进变量（形如 `\npackage:com.xxx\n...`），循环内用 `case` 做子串匹配即可。
- **预期收益**：O(n×m) → O(n+m)，开机阶段减少 6 次重量级 binder 调用，明显缩短 service 启动耗时。

### 8. `post-fs-data.sh` 每次开机无条件重写 modem 配置并 `sync`

- **位置**：`common/post-fs-data.sh` 98-115 行、140 行
- **当前问题**：无论 `network_mode.xml` 里 `<NrMode>` 是否已经是 1，都执行一次「备份检查 → 复制到 TMPDIR → 两次 `sed -i` → 复制回去 → chmod」，最多涉及 3 个分区的文件，随后无条件 `sync`（强制刷写，放大闪存写入）。这是**每次开机都会发生的固件分区写操作**，既拖慢开机又增加闪存磨损。
- **改进建议**：写回前先判幂等——`grep -q '<NrMode>1</NrMode>' "$config" && continue`，已是目标值就整段跳过。备份逻辑（`[ -f "$bf" ] || cp`）本身已经是幂等的，不受影响。
- **预期收益**：升级后的每次开机省掉最多 3 次 vendor/product/system 分区写 + 4 次 sed + 一次 `sync`；降低写放大，缩短 post-fs-data 阶段耗时。

### 9. `freq_limit.sh` watch 循环在 `apply_all` 之后又重复 `load_cfg`

- **位置**：`script/freq_limit.sh` 411-419 行
- **当前问题**：`apply_all` 内部第 294-295 行已经调用了 `load_cfg` 和 `load_range_cfg`，`watch_loop` 里 413 行又调一次 `load_cfg`。每 15s 多一次配置文件读取与解析。
- **改进建议**：`apply_all` 的配置值已经是全局变量，循环里直接读取即可，删除 413 行。（若担心外部改了文件，那也应该让 `apply_all` 自己保证新鲜度，而不是在调用方补一次。）
- **预期收益**：消除 15s 周期上的一次冗余文件读；同时消除"两处 load 时机不一致"带来的理解成本。

### 10. `crash_recuser` 每次开机无条件跑 60 秒 logcat 并写入模块目录

- **位置**：`common/service.sh` 21-30 行
- **当前问题**：`(crash_recuser &)` 无条件启动，函数内无条件 `logcat -f "$BASEDIR/logcat.log" &` 持续 60 秒。也就是说**每次正常开机都会持续抓取全量日志 60 秒**并写一份文件到 `/data/adb/modules/uperf/`，而 logcat 缓冲区的持续读取本身就是一笔不小的开销，文件大小也无上限。
- **改进建议**
  - 保守做法（不改逻辑）：只有在判定"上次开机异常"时才真正抓 logcat——`post-fs-data.sh` 发现 `need_recuser` 残留（即上次没跑完 service）时写一个标记文件，`crash_recuser` 见到标记才启动 logcat，其余情况只做 flag 维护（删除 `need_recuser`）后返回。
  - 无论是否改判定，都建议给 logcat 加体积约束或抓完后立即截断，避免模块目录被日志撑大。
- **预期收益**：正常开机路径省掉 60 秒的日志抓取与磁盘写入；模块目录不再无上限增长。（此项涉及开机诊断策略，建议作为独立决策确认后再动。）

---

## 🟢 P2 — 可维护性

### 11. `sed_escape` 存在 4 份完全相同的拷贝

- **位置**：`webroot/cgi-bin/{whitelist,apps,doze,idle_whitelist}.sh` 各一份（12-15 行附近）
- **建议**：上移到 `lib.sh`，四处删除本地定义。
- **收益**：修正转义规则时只需改一处；四份拷贝已经出现漂移（`doze.sh` 用 `printf '%s'`，另三份用 `echo`），统一后消除不一致。

### 12. 键值写入配置有 3~4 种不同实现

- **位置**：`lib.sh set_cfg`(133)、`set_idle_cfg.sh` 28-40、`cgi-bin/freq_limit.sh` 92-104（三份逐行 while-replace），`freq_range.sh range_set`(75)（第四种，用 `sed -i`）
- **建议**：在 `lib.sh` 提炼统一的 `set_kv_file <file> <key> <value>`，四处改调用。
- **收益**：`sed -i` 版本与 while-replace 版本行为并不等价（对注释行、重复键、特殊字符的处理不同），统一后可消除这类隐性差异；新增配置项时不必再复制粘贴。

### 13. 屏幕状态判定存在 3 份重复实现

- **位置**：`common/service.sh:108 is_screen_on`、`script/memctl.sh:487 is_screen_on`、`script/freq_limit.sh:59 screen_on`（三者实现逐字相同）
- **建议**：统一放进 `script/libcommon.sh`，三处改为 source 后调用。
- **收益**：配合条目 3 的"一次检测、结果共享"改造时不会漏改某一处；判定规则演进只需改一处。

### 14. `wait_until_login` 存在 2 份完全相同实现

- **位置**：`script/libcommon.sh:101`、`uninstall.sh:21`
- **建议**：`uninstall.sh` 直接 source `libcommon.sh`，删除本地副本。
- **收益**：消除两份实现漂移的风险（目前一致，但没有任何机制保证）。

### 15. 日志存在三套并行实现，且 freq_limit 的日志写进了内存服务的日志文件

- **位置**：`memctl.sh log`(75) + `rotate_log`(79)（带轮转）；`service.sh log_msg`(90)（内联轮转，逻辑不同）；`libcommon.sh log`(122)（无轮转）。`freq_limit.sh:32` 把 `LOG` 指向 `$USER_PATH/mem_log.txt`。
- **建议**：把 `rotate_log` 上移到 `libcommon.sh` 作为统一实现；`freq_limit.sh` 的日志改用独立文件（如 `freq_log.txt`），并同步更新 `webroot/cgi-bin/log.sh` 的 file 白名单与 README 的日志表格。
- **收益**：排查频率问题时不必在内存回收日志里翻找；三处日志行为（是否轮转、轮转阈值）一致，避免某一个悄悄撑爆存储。
- **注**：此项会新增一个日志文件路径，属于内部实现，不改外部 API 契约；若严格要求零新增文件，可退而求其次只做"统一轮转实现"，保留 `mem_log.txt`。

### 16. `common/service.sh` 单文件 271 行混合三类职责

- **位置**：`common/service.sh` 全文
- **当前问题**：一个文件里同时做了「开机崩溃日志抓取 → 启动编排（initsvc/memctl/freq_limit/plugins/webuid）→ 息屏压频主循环」。息屏部分（66-271 行）还是全模块唯一使用 `$LOG_FILE` 而非 `$LOG`、唯一用 tab 缩进、唯一用大写单字母风格的一段，风格与 `script/` 下的新代码割裂。
- **建议**：把 66-271 行拆到 `script/screen_saver.sh`（并在 `service.sh` 里后台调用），`service.sh` 只保留启动编排。
- **收益**：配合条目 2 收敛息屏双实现时改动面清晰；启动流程一眼可读。

### 17. `setup.sh` 硬编码大段更新日志，与 `CHANGELOG.md` 重复

- **位置**：`script/setup.sh` 151-181 行（约 30 行更新日志文案）
- **建议**：改为 `cat "$MODULE_PATH/CHANGELOG.md"`（文件已在包内），或在 `install_uperf` 前按需打印最近若干条。
- **收益**：发版只需维护 `CHANGELOG.md` 一处；安装包脚本体积下降，安装输出不再随版本无限膨胀。

### 18. 音量键读取逻辑在 `action.sh` 与 `setup.sh` 各有一份

- **位置**：`action.sh` 46-62 行、`setup.sh` 103-119 行（约 17 行，逻辑相同：后台 getevent + 10s 限时等待 + awk 过滤 DOWN）
- **建议**：提取为公共函数（如 `script/libkey.sh`），两处 source。
- **收益**：按键解析规则的修正（例如某些机型 getevent 输出格式差异）只需改一处。

### 19. 内置 2MB busybox，且每次开机建全量符号链接

- **位置**：`bin/busybox/busybox`（2.05 MB，模块内最大文件）；`script/initsvc.sh:24` `$BIN_PATH/busybox/busybox --install -s $BIN_PATH/busybox`
- **当前问题**：`--install -s` 会为**全部**（约 400 个）applet 建立符号链接，每次开机都在模块目录创建数百个 inode。而实际使用面很窄：`webuid.sh` 仅在 toybox httpd 不可用时回退 busybox httpd，`pathinfo.sh` 把 busybox 目录前置到 PATH 作为兜底。
- **建议**：改为只链接实际用到的少数 applet（如 `busybox --install -s -f` 无法裁剪，则改为按需 `ln -sf busybox $BIN_PATH/busybox/<applet>` 几个），或在确认 toybox 覆盖足够后移除该二进制。
- **收益**：模块体积最多减少约 2MB（安装更快、刷机包更小）；每次开机少创建数百个符号链接。
- **注**：涉及兼容性取舍，建议先在目标机型上确认 toybox httpd 的 `-c` 支持情况再决定，属于**待评估**项而非立即执行项。

### 20. 多处变量展开未加引号，且 `uninstall.sh` 存在用户配置丢失路径

- **位置**
  - 未引号：`uninstall.sh` 79-82（`cp -af $USER_PATH/... /sdcard/`、`rm -rf $USER_PATH`、`mv /sdcard/... $USER_PATH/`）、`setup.sh` 73-81（`cp $MODULE_PATH/config/...`、`rm -rf $MODULE_PATH/config`）、`service.sh` 86/97/100（`> $LOG_FILE`、`>> $LOG_FILE`、`stat -c %s $LOG_FILE`）、`setup.sh` 83（`set_perm_recursive $BIN_PATH`）
  - 数据风险：`uninstall.sh` 79 行 `cp` 未判源文件是否存在、也未检查是否成功；若失败，81 行的 `rm -rf $USER_PATH` 已执行，82 行 `mv` 再失败 → 用户的 `perapp_powermode.txt` 永久丢失。
- **建议**：统一加双引号；`uninstall.sh` 改为 `[ -f "$USER_PATH/perapp_powermode.txt" ] && cp -af ...`，并在 `cp` 失败时跳过后续 `rm -rf`（或用中间目录 + 校验）。
- **收益**：路径含空格时不再出错（也消除 `rm -rf $VAR` 的误删面）；堵住卸载时丢失用户配置的路径。

---

## 🟢 P3 — 代码质量小项

| # | 位置 | 问题 | 建议 | 收益 |
|---|---|---|---|---|
| 21 | `webroot/app.js` 183-185 | `bindSlider` 为每个滑块注册 **window 级** `pointerup`/`pointercancel` 监听，9 个滑块 = 18 个常驻监听，从不移除 | 改用一个共享的 window 监听统一清理 `.pressing` | 减少 DOM 查询与监听器数量，页面更省 |
| 22 | `webroot/app.js` 663 | `setInterval(refreshStatus, 15000)` 无 `document.hidden` 判断 | 回调开头 `if (document.hidden) return;` | 页面后台时后端请求归零（并入条目 4） |
| 23 | `script/powercfg_once.sh` 102-104 | `for i in 0 1 2 3 4 5 6 7 8 9` 硬编码核心数上限 | 改为遍历 `/sys/devices/system/cpu/cpu[0-9]*` | 更多核的机型上不再漏处理；去掉魔法数字 |
| 24 | `script/powercfg_once.sh` 99、117-118 | `set_corectl_param` / `set_cpufreq_min|max` 硬编码 `0..7` 的核心编号串 | 同上，按实际 policy/核心生成 | 同上 |
| 25 | `script/libcgroup.sh` 34-40 等 | `comm="$(cat /proc/.../comm)"` 赋值后从未使用（`change_task_cgroup` 等 6 个函数） | 删除无用赋值（每个 tid 一次 fork） | 减少进程内循环中的无效 fork |
| 26 | `script/powercfg_main.sh` 21 | `action="$1"` 赋值后从未使用 | 删除 | 消除阅读时的困惑 |
| 27 | `script/setup.sh` 221-227 | 仍用反引号 + 大写单字母变量（`SOC=`、`MODVER=`、`ROMV=`），与同文件 `$(...)` 风格混用 | 统一为 `$(...)` + 小写 | 风格一致，减少误读 |
| 28 | `webroot/cgi-bin/log.sh` 24 | 内联的 JSON 转义 `sed 's/\\/\\\\/g;s/"/\\"/g'` 与 `lib.sh json_escape` 重复 | 改调 `json_escape` | 转义规则单点维护 |
| 29 | `webroot/cgi-bin/status.sh` 47 | 同上，内联转义 | 改调 `json_escape` | 同上 |
| 30 | `script/freq_range.sh` 60-61 | `local tbl="$1" sec` 之后立刻 `tbl=$(freq_table_file)` 覆盖入参，第一行赋值是死代码 | 删除该行赋值 | 消除阅读歧义 |

---

## 附：建议的落地顺序

1. **条目 1**（memctl fork 风暴）——收益最大、改动局部、零接口变更，建议最先做，并前后各测一次轮询期间的 CPU 占用对比。
2. **条目 2 + 3**（息屏双实现收敛）——同时解决正确性（上限被静默抹掉）与性能（2s dumpsys 轮询），建议合并为一次改动，改完重点验证「设置 FREQ_CAP → 息屏 → 亮屏 → 上限仍在」。
3. **条目 4 + 6**（WebUI 与 status.sh）——前后端一起改，效果最直观。
4. **条目 5、7、8、9、10**（开机路径上的重复与冗余）——一次性清理，开机耗时的改善可以被直接感知。
5. **条目 11-18**（去重与结构整理）——纯维护性收益，可分批做，每批做完跑一遍 `sh -n` 与关键路径回归。
6. **条目 19、20** ——涉及兼容性取舍与数据安全，建议单独评估后执行。

> 复查提示：条目 2 描述的上限失效是基于 bind-mount 语义的静态推演（掩码生效后对 `scaling_max_freq` 路径的写入会落到掩码文件上），建议在真机上用「设 cap → 息屏 → 亮屏 → `cat scaling_max_freq`」实测确认后再按建议改动。
