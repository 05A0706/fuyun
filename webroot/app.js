/* fuyun WebUI 逻辑 - 修复版 */
"use strict";

// API 使用相对路径: 页面与 API 同源 (http://127.0.0.1:16800)
// 管理器 (Magisk/KernelSU) 以 https 打开 webroot 时, 首次 API 探测会失败,
// 此时自动跳转到内置 http 服务, 页面与 API 同源后一切正常。
const API = "cgi-bin";
const API_ABS = "http://127.0.0.1:16800/cgi-bin";
const HTTP_SERVICE = "http://127.0.0.1:16800/";

// ---------- 工具函数 ----------
// HTML 转义，防止 XSS 攻击
function escapeHtml(str) {
  if (!str) return '';
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// Toast 管理
let toastTimer = null;
let toastElement = null;

function showToast(msg, duration = 2500) {
  if (!toastElement) {
    toastElement = document.createElement("div");
    toastElement.id = "toast";
    toastElement.style.cssText =
      "position:fixed;left:50%;bottom:30px;transform:translateX(-50%);" +
      "background:#232838;color:#fff;padding:10px 18px;border-radius:8px;" +
      "font-size:13px;z-index:99;border:1px solid #2a2f3d;max-width:80%;" +
      "transition: opacity 0.3s ease;";
    document.body.appendChild(toastElement);
  }
  
  // 清除之前的定时器
  if (toastTimer) {
    clearTimeout(toastTimer);
    toastTimer = null;
  }
  
  toastElement.textContent = msg;
  toastElement.style.display = "block";
  toastElement.style.opacity = "1";
  
  toastTimer = setTimeout(() => {
    toastElement.style.opacity = "0";
    setTimeout(() => {
      if (toastElement) toastElement.style.display = "none";
    }, 300);
  }, duration);
}

// ---------- API 基础函数 ----------
function apiBase() {
  // https 环境(管理器 WebView): 用绝对地址直连本机 http 服务, lib.sh 已带 CORS 头;
  // http 环境(跳转后/浏览器直开): 用相对路径保持同源
  return location.protocol === "https:" ? API_ABS : API;
}

async function api(path, params) {
  let url = apiBase() + "/" + path;
  if (params) {
    const qs = Object.keys(params)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(params[k]))
      .join("&");
    url += "?" + qs;
  }
  const res = await fetch(url, { 
    cache: "no-store",
    headers: {
      'Accept': 'application/json'
    }
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

// 带环境切换的 API 调用: https 环境探测失败 → 跳转内置 http 服务
async function tryApi(path, params) {
  try {
    return await api(path, params);
  } catch (e) {
    if (location.protocol === "https:") {
      // 管理器 WebView 环境: 混合内容被拦截, 切换到模块自带 http 服务
      showSwitchHint();
      location.replace(HTTP_SERVICE);
      throw new Error("switching-to-http");
    }
    // 非 https 环境，显示错误但不跳转
    console.error('API Error:', e);
    throw e;
  }
}

// POST 版 API: 用于高级设置保存原始文件内容
async function apiPost(path, params, body) {
  let url = apiBase() + "/" + path;
  if (params) {
    const qs = Object.keys(params)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(params[k]))
      .join("&");
    url += "?" + qs;
  }
  const res = await fetch(url, {
    method: "POST",
    body: body,
    cache: "no-store",
    headers: {
      'Content-Type': 'text/plain;charset=UTF-8',
      'Accept': 'application/json'
    }
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

async function tryApiPost(path, params, body) {
  try {
    return await apiPost(path, params, body);
  } catch (e) {
    if (location.protocol === "https:") {
      showSwitchHint();
      location.replace(HTTP_SERVICE);
      throw new Error("switching-to-http");
    }
    console.error('API POST Error:', e);
    throw e;
  }
}

// ---------- UI 辅助函数 ----------
function badge(el, ok, text) {
  el.textContent = text;
  let status = 'na';
  if (ok === true || ok === 1) status = 'ok';
  else if (ok === false || ok === 0) status = 'bad';
  else if (ok === null || ok === undefined) status = 'na';
  el.className = "badge " + status;
}

// 防抖函数，用于控制刷新频率
function debounce(func, wait) {
  let timeout;
  return function executedFunction(...args) {
    const later = () => {
      clearTimeout(timeout);
      func(...args);
    };
    clearTimeout(timeout);
    timeout = setTimeout(later, wait);
  };
}

// ---------- 状态刷新 ----------
let isRefreshing = false;

async function refreshStatus() {
  // 防止并发刷新
  if (isRefreshing) return;
  isRefreshing = true;
  
  try {
    const s = await tryApi("status.sh");
    
    // 更新状态徽标
    badge(document.getElementById("st-uperf"), s.uperf_running === 1, s.uperf_running === 1 ? "运行中" : "未运行");
    badge(document.getElementById("st-memctl"), s.memctl_running === 1, s.memctl_running === 1 ? "运行中" : "未运行");
    document.getElementById("st-mem").textContent = s.mem_available_mb + " MB";
    document.getElementById("st-fg").textContent = s.foreground || "-";
    document.getElementById("st-log").textContent = s.last_log || "-";

    // 模式按钮高亮
    document.querySelectorAll(".mode").forEach((b) => {
      b.classList.toggle("active", b.dataset.mode === s.powermode);
    });

    // 填充配置表单
    document.getElementById("f-mem-enable").value = String(s.mem_enable ?? 0);
    document.getElementById("f-mode").value = s.mode || "balance";
    document.getElementById("f-psi").value = s.psi_threshold ?? 30;
    document.getElementById("f-interval").value = s.interval ?? 60;
    document.getElementById("f-idle").value = s.idle_kill_min ?? 5;
    document.getElementById("f-switch").value = String(s.switch_reclaim ?? 0);
    document.getElementById("f-maxround").value = s.max_per_round ?? 5;

    // 辅助调速器: 状态徽标 + 配置表单
    const govActive = s.idle_gov_active === 1;
    badge(document.getElementById("gov-badge"), govActive, govActive ? "深度空闲中" : "空闲压频");
    document.getElementById("f-gov-enable").value = String(s.idle_gov_enable ?? 1);
    document.getElementById("f-gov-interval").value = s.idle_interval ?? 5;
    document.getElementById("f-gov-timeout").value = s.idle_timeout ?? 30;
    document.getElementById("f-gov-thd").value = s.idle_cpu_thd ?? 30;
    document.getElementById("f-gov-power").value = s.idle_power_w ?? 5;

    // 频率限制: 状态徽标 + 配置表单 + 大核硬件上限提示
    const freqCap = s.freq_cap || 0;
    const freqOn = s.freq_active === 1;
    const freqTxt = freqOn
      ? "已限制 " + (freqCap / 1000000).toFixed(2).replace(/\.?0+$/, "") + "GHz"
      : "动态";
    badge(document.getElementById("freq-badge"), freqOn, freqTxt);
    document.getElementById("f-freq-scope").value = s.freq_scope === "all" ? "all" : "big";
    document.getElementById("f-freq-cap").value = String(freqCap);
    document.getElementById("f-freq-offscreen").value = String(s.freq_offscreen === 1 ? 1 : 0);
    document.getElementById("f-freq-offcap").value = String(s.freq_offcap || 1200000);
    const bigMax = s.freq_big_max_khz || 0;
    document.getElementById("freq-max-hint").textContent =
      bigMax > 0 ? "大核硬件上限 " + (bigMax / 1000000).toFixed(2) + " GHz" : "大核硬件上限 -";
      
  } catch (e) {
    if (e.message !== "switching-to-http") {
      document.getElementById("st-log").textContent = "API 连接失败: " + e.message;
      console.error('Refresh status error:', e);
    }
  } finally {
    isRefreshing = false;
  }
}

// 使用防抖包装刷新函数
const debouncedRefresh = debounce(refreshStatus, 300);

// ---------- 模式切换 ----------
document.getElementById("modebtns").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".mode");
  if (!btn) return;
  
  // 禁用按钮防止重复点击
  btn.style.opacity = '0.6';
  btn.style.pointerEvents = 'none';
  
  try {
    const r = await tryApi("mode.sh", { mode: btn.dataset.mode });
    if (r.ok) {
      document.querySelectorAll(".mode").forEach((b) => b.classList.toggle("active", b === btn));
      showToast("已切换到 " + btn.dataset.mode);
      await debouncedRefresh();
    } else {
      showToast(r.msg || "切换失败");
    }
  } catch (e) {
    showToast("失败: " + e.message);
  } finally {
    btn.style.opacity = '1';
    btn.style.pointerEvents = 'auto';
  }
});

// ---------- 保存配置 ----------
document.getElementById("btnSaveCfg").addEventListener("click", async () => {
  const fields = {
    MEM_ENABLE: "f-mem-enable",
    MODE: "f-mode",
    PSI_THRESHOLD: "f-psi",
    INTERVAL: "f-interval",
    IDLE_KILL_MIN: "f-idle",
    SWITCH_RECLAIM: "f-switch",
    MAX_PER_ROUND: "f-maxround",
    PUSH_KEEP: "f-pushkeep",
    KEEP_CMDLINE: "f-keepcmd",
  };
  
  const btn = document.getElementById("btnSaveCfg");
  btn.disabled = true;
  btn.textContent = "保存中...";
  
  let okAll = true;
  let errorMsg = '';
  
  for (const [key, fid] of Object.entries(fields)) {
    const el = document.getElementById(fid);
    if (!el) continue;
    
    const v = el.value.trim();
    // 允许空值，表示清空配置
    try {
      const r = await tryApi("set_config.sh", { key, value: v || '' });
      if (!r.ok) {
        okAll = false;
        errorMsg = key + ": " + (r.msg || '保存失败');
        break;
      }
    } catch (e) {
      okAll = false;
      errorMsg = "失败: " + e.message;
      break;
    }
  }
  
  if (okAll) {
    const el = document.getElementById("cfg-saved");
    el.classList.remove("hidden");
    showToast("配置已保存");
    setTimeout(() => el.classList.add("hidden"), 2000);
    await debouncedRefresh();
  } else {
    showToast(errorMsg, 3000);
  }
  
  btn.disabled = false;
  btn.textContent = "保存配置";
});

// ---------- 辅助调速器 ----------
document.getElementById("btnSaveGov").addEventListener("click", async () => {
  const fields = {
    IDLE_GOV: "f-gov-enable",
    IDLE_INTERVAL: "f-gov-interval",
    IDLE_TIMEOUT: "f-gov-timeout",
    IDLE_CPU_THD: "f-gov-thd",
    IDLE_POWER_W: "f-gov-power",
  };
  
  const btn = document.getElementById("btnSaveGov");
  btn.disabled = true;
  btn.textContent = "保存中...";
  
  let okAll = true;
  let errorMsg = '';
  
  for (const [key, fid] of Object.entries(fields)) {
    const el = document.getElementById(fid);
    if (!el) continue;
    
    const v = el.value.trim();
    try {
      const r = await tryApi("set_idle_cfg.sh", { key, value: v || '' });
      if (!r.ok) {
        okAll = false;
        errorMsg = key + ": " + (r.msg || '保存失败');
        break;
      }
    } catch (e) {
      okAll = false;
      errorMsg = "失败: " + e.message;
      break;
    }
  }
  
  if (okAll) {
    const el = document.getElementById("gov-saved");
    el.classList.remove("hidden");
    showToast("调速器配置已保存");
    setTimeout(() => el.classList.add("hidden"), 2000);
    await debouncedRefresh();
  } else {
    showToast(errorMsg, 3000);
  }
  
  btn.disabled = false;
  btn.textContent = "保存调速器配置";
});

// ---------- 频率限制 ----------
document.getElementById("btnSaveFreq").addEventListener("click", async () => {
  const fields = {
    FREQ_CAP: "f-freq-cap",
    FREQ_SCOPE: "f-freq-scope",
    FREQ_OFFSCREEN: "f-freq-offscreen",
    FREQ_OFFSCREEN_CAP: "f-freq-offcap",
  };
  
  const btn = document.getElementById("btnSaveFreq");
  btn.disabled = true;
  btn.textContent = "保存中...";
  
  let okAll = true;
  let errorMsg = '';
  
  for (const [key, fid] of Object.entries(fields)) {
    const el = document.getElementById(fid);
    if (!el) continue;
    
    const v = el.value.trim();
    try {
      const r = await tryApi("freq_limit.sh", { action: "set", key, value: v || '' });
      if (!r.ok) {
        okAll = false;
        errorMsg = key + ": " + (r.msg || '保存失败');
        break;
      }
    } catch (e) {
      okAll = false;
      errorMsg = "失败: " + e.message;
      break;
    }
  }
  
  if (okAll) {
    const el = document.getElementById("freq-saved");
    el.classList.remove("hidden");
    showToast("频率限制已保存");
    setTimeout(() => el.classList.add("hidden"), 2000);
    await debouncedRefresh();
  } else {
    showToast(errorMsg, 3000);
  }
  
  btn.disabled = false;
  btn.textContent = "保存频率限制";
});

// ---------- CPU 频率范围 ----------
function fillFreqSelect(el, freqs, current) {
  if (!el) return;
  
  el.innerHTML = '<option value="0">动态</option>';
  (freqs || []).forEach((f) => {
    const opt = document.createElement("option");
    opt.value = String(f);
    opt.textContent = (f / 1000000).toFixed(3).replace(/\.?0+$/, "") + " GHz";
    if (String(f) === String(current)) opt.selected = true;
    el.appendChild(opt);
  });
}

async function loadFreqRange() {
  try {
    const r = await tryApi("freq_range.sh", { action: "get" });
    document.getElementById("freq-range-soc").textContent = "SoC " + (r.soc || "-");
    document.getElementById("f-rng-enable").value = String(r.enable || 0);
    fillFreqSelect(document.getElementById("f-rng-lmin"), r.freqs_little, r.little_min);
    fillFreqSelect(document.getElementById("f-rng-lmax"), r.freqs_little, r.little_max);
    fillFreqSelect(document.getElementById("f-rng-mmin"), r.freqs_mid, r.mid_min);
    fillFreqSelect(document.getElementById("f-rng-mmax"), r.freqs_mid, r.mid_max);
    fillFreqSelect(document.getElementById("f-rng-bmin"), r.freqs_big, r.big_min);
    fillFreqSelect(document.getElementById("f-rng-bmax"), r.freqs_big, r.big_max);
    const active = r.enable === 1;
    badge(document.getElementById("freq-range-badge"), active, active ? "已启用" : "动态");
    const pols = r.policies || [];
    const clName = { little: "小核", mid: "中核", big: "大核" };
    document.getElementById("freq-range-policies").textContent = pols.length
      ? "实际频率：" + pols.map((p) =>
          (clName[p.cluster] || p.cluster) + " " +
          (p.min_khz / 1000000).toFixed(2) + "-" + (p.max_khz / 1000000).toFixed(2) + "GHz" +
          (p.masked === 1 ? " ✓" : " ✗")).join("；")
      : "实际频率：-";
  } catch (e) {
    if (e.message !== "switching-to-http") {
      console.error('Load freq range error:', e);
      showToast("加载频率范围失败: " + e.message, 3000);
    }
  }
}

document.getElementById("btnSaveFreqRange").addEventListener("click", async () => {
  const fields = {
    FREQ_RANGE_ENABLE: "f-rng-enable",
    LITTLE_MIN: "f-rng-lmin",
    LITTLE_MAX: "f-rng-lmax",
    MID_MIN: "f-rng-mmin",
    MID_MAX: "f-rng-mmax",
    BIG_MIN: "f-rng-bmin",
    BIG_MAX: "f-rng-bmax",
  };
  
  const btn = document.getElementById("btnSaveFreqRange");
  btn.disabled = true;
  btn.textContent = "保存中...";
  
  let okAll = true;
  let errorMsg = '';
  
  for (const [key, fid] of Object.entries(fields)) {
    const el = document.getElementById(fid);
    if (!el) continue;
    
    const v = el.value.trim();
    try {
      const r = await tryApi("freq_range.sh", { action: "set", key, value: v || '' });
      if (!r.ok) {
        okAll = false;
        errorMsg = key + ": " + (r.msg || '保存失败');
        break;
      }
    } catch (e) {
      okAll = false;
      errorMsg = "失败: " + e.message;
      break;
    }
  }
  
  if (okAll) {
    const el = document.getElementById("freq-range-saved");
    el.classList.remove("hidden");
    showToast("频率范围已保存");
    setTimeout(() => el.classList.add("hidden"), 2000);
    await loadFreqRange();
  } else {
    showToast(errorMsg, 3000);
  }
  
  btn.disabled = false;
  btn.textContent = "保存频率范围";
});

document.getElementById("btnClearFreqRange").addEventListener("click", async () => {
  if (!confirm("确定清除所有频率范围设置吗？")) return;
  
  const btn = document.getElementById("btnClearFreqRange");
  btn.disabled = true;
  
  try {
    const r = await tryApi("freq_range.sh", { action: "clear" });
    showToast(r.msg || "已清除");
    await loadFreqRange();
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

// ---------- 调速器白名单 ----------
async function loadGovWhitelist() {
  try {
    const r = await tryApi("idle_whitelist.sh", { action: "list" });
    const ul = document.getElementById("gwl-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      const pkgSpan = document.createElement("span");
      pkgSpan.className = "pkg";
      pkgSpan.textContent = it.pkg || '';
      
      const delBtn = document.createElement("button");
      delBtn.className = "del";
      delBtn.dataset.pkg = it.pkg || '';
      delBtn.textContent = "✕";
      delBtn.setAttribute('aria-label', '删除 ' + it.pkg);
      
      li.appendChild(pkgSpan);
      li.appendChild(delBtn);
      ul.appendChild(li);
    });
  } catch (e) {
    if (e.message !== "switching-to-http") {
      console.error('Load gov whitelist error:', e);
    }
  }
}

document.getElementById("btnGwlAdd").addEventListener("click", async () => {
  const input = document.getElementById("gwl-pkg");
  const pkg = input.value.trim();
  if (!pkg) {
    showToast("请输入包名", 2000);
    return;
  }
  
  const btn = document.getElementById("btnGwlAdd");
  btn.disabled = true;
  
  try {
    const r = await tryApi("idle_whitelist.sh", { action: "add", pkg });
    showToast(r.msg || "添加成功");
    if (r.ok) {
      input.value = "";
      await loadGovWhitelist();
    }
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

document.getElementById("gwl-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  
  if (!confirm("确定删除 " + btn.dataset.pkg + " 吗？")) return;
  
  try {
    await tryApi("idle_whitelist.sh", { action: "del", pkg: btn.dataset.pkg });
    await loadGovWhitelist();
    showToast("已删除", 1500);
  } catch (e) {
    showToast("删除失败: " + e.message, 3000);
  }
});

// ---------- 分应用策略 ----------
async function loadApps() {
  try {
    const r = await tryApi("apps.sh", { action: "list" });
    const ul = document.getElementById("app-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      
      const pkgSpan = document.createElement("span");
      pkgSpan.className = "pkg";
      pkgSpan.textContent = it.pkg || '';
      
      const rightSpan = document.createElement("span");
      const modeTag = document.createElement("span");
      modeTag.className = "mode-tag";
      modeTag.textContent = it.mode || 'balance';
      
      const delBtn = document.createElement("button");
      delBtn.className = "del";
      delBtn.dataset.pkg = it.pkg || '';
      delBtn.textContent = "✕";
      delBtn.setAttribute('aria-label', '删除 ' + it.pkg);
      
      rightSpan.appendChild(modeTag);
      rightSpan.appendChild(delBtn);
      li.appendChild(pkgSpan);
      li.appendChild(rightSpan);
      ul.appendChild(li);
    });
  } catch (e) {
    if (e.message !== "switching-to-http") {
      console.error('Load apps error:', e);
    }
  }
}

document.getElementById("btnAppAdd").addEventListener("click", async () => {
  const pkgInput = document.getElementById("app-pkg");
  const modeSelect = document.getElementById("app-mode");
  const pkg = pkgInput.value.trim();
  const mode = modeSelect.value;
  
  if (!pkg) {
    showToast("请输入包名", 2000);
    return;
  }
  
  const btn = document.getElementById("btnAppAdd");
  btn.disabled = true;
  
  try {
    const r = await tryApi("apps.sh", { action: "add", pkg, mode });
    showToast(r.msg || "添加成功");
    if (r.ok) {
      pkgInput.value = "";
      await loadApps();
    }
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

document.getElementById("app-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  
  if (!confirm("确定删除 " + btn.dataset.pkg + " 吗？")) return;
  
  try {
    await tryApi("apps.sh", { action: "del", pkg: btn.dataset.pkg });
    await loadApps();
    showToast("已删除", 1500);
  } catch (e) {
    showToast("删除失败: " + e.message, 3000);
  }
});

// ---------- 白名单 ----------
async function loadWhitelist() {
  try {
    const r = await tryApi("whitelist.sh", { action: "list" });
    const ul = document.getElementById("wl-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      
      const pkgSpan = document.createElement("span");
      pkgSpan.className = "pkg";
      pkgSpan.textContent = it.pkg || '';
      
      const delBtn = document.createElement("button");
      delBtn.className = "del";
      delBtn.dataset.pkg = it.pkg || '';
      delBtn.textContent = "✕";
      delBtn.setAttribute('aria-label', '删除 ' + it.pkg);
      
      li.appendChild(pkgSpan);
      li.appendChild(delBtn);
      ul.appendChild(li);
    });
  } catch (e) {
    if (e.message !== "switching-to-http") {
      console.error('Load whitelist error:', e);
    }
  }
}

document.getElementById("btnWlAdd").addEventListener("click", async () => {
  const input = document.getElementById("wl-pkg");
  const pkg = input.value.trim();
  if (!pkg) {
    showToast("请输入包名", 2000);
    return;
  }
  
  const btn = document.getElementById("btnWlAdd");
  btn.disabled = true;
  
  try {
    const r = await tryApi("whitelist.sh", { action: "add", pkg });
    showToast(r.msg || "添加成功");
    if (r.ok) {
      input.value = "";
      await loadWhitelist();
    }
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

document.getElementById("wl-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  
  if (!confirm("确定删除 " + btn.dataset.pkg + " 吗？")) return;
  
  try {
    await tryApi("whitelist.sh", { action: "del", pkg: btn.dataset.pkg });
    await loadWhitelist();
    showToast("已删除", 1500);
  } catch (e) {
    showToast("删除失败: " + e.message, 3000);
  }
});

// ---------- Doze 白名单 ----------
async function loadDoze() {
  try {
    const r = await tryApi("doze.sh", { action: "list" });
    const ul = document.getElementById("doze-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      
      const pkgSpan = document.createElement("span");
      pkgSpan.className = "pkg";
      pkgSpan.textContent = it.pkg || '';
      
      const delBtn = document.createElement("button");
      delBtn.className = "del";
      delBtn.dataset.pkg = it.pkg || '';
      delBtn.textContent = "✕";
      delBtn.setAttribute('aria-label', '删除 ' + it.pkg);
      
      li.appendChild(pkgSpan);
      li.appendChild(delBtn);
      ul.appendChild(li);
    });
  } catch (e) {
    if (e.message !== "switching-to-http") {
      console.error('Load doze whitelist error:', e);
    }
  }
}

document.getElementById("btnDozeAdd").addEventListener("click", async () => {
  const input = document.getElementById("doze-pkg");
  const pkg = input.value.trim();
  if (!pkg) {
    showToast("请输入包名", 2000);
    return;
  }
  
  const btn = document.getElementById("btnDozeAdd");
  btn.disabled = true;
  
  try {
    const r = await tryApi("doze.sh", { action: "add", pkg });
    showToast(r.msg || "添加成功");
    if (r.ok) {
      input.value = "";
      await loadDoze();
    }
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

document.getElementById("doze-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  
  if (!confirm("确定删除 " + btn.dataset.pkg + " 吗？")) return;
  
  try {
    await tryApi("doze.sh", { action: "del", pkg: btn.dataset.pkg });
    await loadDoze();
    showToast("已删除", 1500);
  } catch (e) {
    showToast("删除失败: " + e.message, 3000);
  }
});

// ---------- 高级设置: 配置文件读写 ----------
async function loadAdvFile(file, elId) {
  try {
    const r = await tryApi("config_file.sh", { action: "get", file });
    const el = document.getElementById(elId);
    if (el) {
      el.value = (r.lines || []).join("\n");
    }
  } catch (e) {
    if (e.message !== "switching-to-http") {
      console.error('Load advanced file error:', e);
    }
  }
}

async function saveAdvFile(file, elId) {
  const el = document.getElementById(elId);
  if (!el) return;
  
  const btn = document.querySelector(`[data-save="${file}"]`) || 
              document.getElementById("btnSaveAdv" + file.charAt(0).toUpperCase() + file.slice(1));
  if (btn) {
    btn.disabled = true;
    btn.textContent = "保存中...";
  }
  
  try {
    const r = await tryApiPost("config_file.sh", { action: "save", file }, el.value);
    showToast(r.msg || "保存成功");
  } catch (e) {
    showToast("保存失败: " + e.message, 3000);
    console.error('Save advanced file error:', e);
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = "保存 " + file;
    }
  }
}

// 绑定高级设置保存按钮
document.getElementById("btnSaveAdvMem").addEventListener("click", () => saveAdvFile("mem", "adv-mem"));
document.getElementById("btnSaveAdvIdle").addEventListener("click", () => saveAdvFile("idle", "adv-idle"));
document.getElementById("btnSaveAdvPerapp").addEventListener("click", () => saveAdvFile("perapp", "adv-perapp"));
document.getElementById("btnSaveAdvUperf").addEventListener("click", () => saveAdvFile("uperf", "adv-uperf"));

// ---------- 操作 ----------
document.getElementById("btnReclaim").addEventListener("click", async () => {
  const btn = document.getElementById("btnReclaim");
  btn.disabled = true;
  
  try {
    const r = await tryApi("action.sh", { do: "reclaim" });
    showToast(r.msg || "回收完成");
    await debouncedRefresh();
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

document.getElementById("btnRestart").addEventListener("click", async () => {
  if (!confirm("确定重启 memctl 服务吗？")) return;
  
  const btn = document.getElementById("btnRestart");
  btn.disabled = true;
  
  try {
    const r = await tryApi("action.sh", { do: "restart_memctl" });
    showToast(r.msg || "重启成功");
    await debouncedRefresh();
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

document.getElementById("btnReload").addEventListener("click", async () => {
  const btn = document.getElementById("btnReload");
  btn.disabled = true;
  
  try {
    const r = await tryApi("action.sh", { do: "reload" });
    showToast(r.msg || "重载成功");
    await debouncedRefresh();
  } catch (e) {
    showToast("失败: " + e.message, 3000);
  } finally {
    btn.disabled = false;
  }
});

// ---------- 日志 ----------
document.getElementById("btnLog").addEventListener("click", loadLog);

async function loadLog() {
  const viewEl = document.getElementById("log-view");
  const btn = document.getElementById("btnLog");
  
  if (btn) {
    btn.disabled = true;
    btn.textContent = "加载中...";
  }
  
  try {
    const file = document.getElementById("log-file").value || "memctl";
    const r = await tryApi("log.sh", { lines: 50, file });
    viewEl.textContent = (r.lines || []).join("\n");
  } catch (e) {
    if (e.message !== "switching-to-http") {
      viewEl.textContent = "日志加载失败: " + e.message;
      console.error('Load log error:', e);
    }
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = "刷新日志";
    }
  }
}

// ---------- 跳转提示 (管理器 https 页面无法访问 http 服务时) ----------
function showSwitchHint() {
  const div = document.createElement("div");
  div.style.cssText =
    "position:fixed;inset:0;background:#0f1117;color:#e6e8ee;display:flex;" +
    "flex-direction:column;align-items:center;justify-content:center;gap:12px;" +
    "font:14px/1.6 sans-serif;text-align:center;padding:20px;z-index:9999;";
  div.innerHTML =
    "<div>正在连接本机 WebUI 服务…</div>" +
    "<div style='color:#8b93a7;font-size:12px'>若持续停留在此提示，说明 WebUI 服务未启动或跳转被拦截<br>" +
    "请在终端执行：<code style='color:#9fd0a5'>su -c &quot;sh /data/adb/modules/uperf/script/webuid.sh status&quot;</code></div>" +
    "<a href='" + HTTP_SERVICE + "' style='color:#4f8cff'>手动打开 http://127.0.0.1:16800/</a>";
  document.body.innerHTML = "";
  document.body.appendChild(div);
}

// ---------- 刷新所有数据 ----------
async function refreshAllData() {
  const btn = document.getElementById("btnRefresh");
  if (btn) {
    btn.disabled = true;
    btn.textContent = "刷新中...";
  }
  
  try {
    await Promise.all([
      refreshStatus(),
      loadFreqRange(),
      loadApps(),
      loadWhitelist(),
      loadGovWhitelist(),
      loadDoze(),
      loadAdvFile("mem", "adv-mem"),
      loadAdvFile("idle", "adv-idle"),
      loadAdvFile("perapp", "adv-perapp"),
      loadAdvFile("uperf", "adv-uperf"),
      loadLog()
    ]);
    showToast("已刷新", 1500);
  } catch (e) {
    console.error('Refresh all error:', e);
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = "刷新";
    }
  }
}

document.getElementById("btnRefresh").addEventListener("click", refreshAllData);

// ---------- 初始化 ----------
// 使用 Promise.all 并行初始化，但不要阻塞 UI
(async function init() {
  try {
    await Promise.all([
      refreshStatus(),
      loadFreqRange(),
      loadApps(),
      loadWhitelist(),
      loadGovWhitelist(),
      loadDoze(),
      loadAdvFile("mem", "adv-mem"),
      loadAdvFile("idle", "adv-idle"),
      loadAdvFile("perapp", "adv-perapp"),
      loadAdvFile("uperf", "adv-uperf"),
      loadLog()
    ]);
    console.log('WebUI initialized successfully');
  } catch (e) {
    console.error('Initialization error:', e);
  }
})();

// 使用防抖的自动刷新，避免频繁请求
let refreshInterval = null;

function startAutoRefresh() {
  if (refreshInterval) {
    clearInterval(refreshInterval);
  }
  refreshInterval = setInterval(() => {
    // 只在页面可见时刷新
    if (!document.hidden) {
      refreshStatus().catch(e => console.error('Auto refresh error:', e));
    }
  }, 15000);
}

function stopAutoRefresh() {
  if (refreshInterval) {
    clearInterval(refreshInterval);
    refreshInterval = null;
  }
}

// 页面可见性变化时控制刷新
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    stopAutoRefresh();
  } else {
    startAutoRefresh();
    // 回到页面时立即刷新一次
    refreshStatus().catch(e => console.error('Visibility refresh error:', e));
  }
});

// 启动自动刷新
startAutoRefresh();

// 页面卸载时清理
window.addEventListener('beforeunload', () => {
  stopAutoRefresh();
  if (toastTimer) {
    clearTimeout(toastTimer);
    toastTimer = null;
  }
});

console.log('fuyun WebUI loaded successfully');