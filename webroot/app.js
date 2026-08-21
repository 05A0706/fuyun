/* fuyun WebUI 逻辑 */
"use strict";

// API 使用相对路径: 页面与 API 同源 (http://127.0.0.1:16800)
// 管理器 (Magisk/KernelSU) 以 https 打开 webroot 时, 首次 API 探测会失败,
// 此时自动跳转到内置 http 服务, 页面与 API 同源后一切正常。
const API = "cgi-bin";
const HTTP_SERVICE = "http://127.0.0.1:16800/";

async function api(path, params) {
  let url = API + "/" + path;
  if (params) {
    const qs = Object.keys(params)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(params[k]))
      .join("&");
    url += "?" + qs;
  }
  const res = await fetch(url, { cache: "no-store" });
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
      location.replace(HTTP_SERVICE);
      throw new Error("switching-to-http");
    }
    throw e;
  }
}

// POST 版 API: 用于高级设置保存原始文件内容
async function apiPost(path, params, body) {
  let url = API + "/" + path;
  if (params) {
    const qs = Object.keys(params)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(params[k]))
      .join("&");
    url += "?" + qs;
  }
  const res = await fetch(url, {
    method: "POST",
    body,
    cache: "no-store",
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

async function tryApiPost(path, params, body) {
  try {
    return await apiPost(path, params, body);
  } catch (e) {
    if (location.protocol === "https:") {
      location.replace(HTTP_SERVICE);
      throw new Error("switching-to-http");
    }
    throw e;
  }
}

/* ---------- 状态 ---------- */
function badge(el, ok, text) {
  el.textContent = text;
  el.className = "badge " + (ok ? "ok" : ok === null ? "na" : "bad");
}

async function refreshStatus() {
  try {
    const s = await tryApi("status.sh");
    badge(document.getElementById("st-uperf"), s.uperf_running === 1, s.uperf_running === 1 ? "运行中" : "未运行");
    badge(document.getElementById("st-memctl"), s.memctl_running === 1, s.memctl_running === 1 ? "运行中" : "未运行");
    document.getElementById("st-mem").textContent = s.mem_available_mb + " MB";
    document.getElementById("st-fg").textContent = s.foreground;
    document.getElementById("st-log").textContent = s.last_log || "-";

    // 模式按钮高亮
    document.querySelectorAll(".mode").forEach((b) => {
      b.classList.toggle("active", b.dataset.mode === s.powermode);
    });

    // 填充配置表单
    document.getElementById("f-mem-enable").value = String(s.mem_enable);
    document.getElementById("f-mode").value = s.mode;
    document.getElementById("f-psi").value = s.psi_threshold;
    document.getElementById("f-interval").value = s.interval;
    document.getElementById("f-idle").value = s.idle_kill_min;
    document.getElementById("f-switch").value = String(s.switch_reclaim);
    document.getElementById("f-maxround").value = s.max_per_round;

    // 辅助调速器: 状态徽标 + 配置表单
    const govActive = s.idle_gov_active === 1;
    badge(document.getElementById("gov-badge"), govActive, govActive ? "深度空闲中" : "空闲压频");
    document.getElementById("f-gov-enable").value = String(s.idle_gov_enable);
    document.getElementById("f-gov-interval").value = s.idle_interval;
    document.getElementById("f-gov-timeout").value = s.idle_timeout;
    document.getElementById("f-gov-thd").value = s.idle_cpu_thd;
    document.getElementById("f-gov-power").value = s.idle_power_w;

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
    }
  }
}

/* ---------- 模式切换 ---------- */
document.getElementById("modebtns").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".mode");
  if (!btn) return;
  try {
    const r = await tryApi("mode.sh", { mode: btn.dataset.mode });
    if (r.ok) {
      document.querySelectorAll(".mode").forEach((b) => b.classList.toggle("active", b === btn));
      showToast("已切换到 " + btn.dataset.mode);
    } else showToast(r.msg);
  } catch (e) { showToast("失败: " + e.message); }
});

/* ---------- 保存配置 ---------- */
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
  let okAll = true;
  for (const [key, fid] of Object.entries(fields)) {
    const v = document.getElementById(fid).value.trim();
    if (!v) continue;
    try {
      const r = await tryApi("set_config.sh", { key, value: v });
      if (!r.ok) { okAll = false; showToast(key + ": " + r.msg); break; }
    } catch (e) { okAll = false; showToast("失败: " + e.message); break; }
  }
  if (okAll) {
    const el = document.getElementById("cfg-saved");
    el.classList.remove("hidden");
    setTimeout(() => el.classList.add("hidden"), 2000);
    refreshStatus();
  }
});

/* ---------- 辅助调速器 ---------- */
document.getElementById("btnSaveGov").addEventListener("click", async () => {
  const fields = {
    IDLE_GOV: "f-gov-enable",
    IDLE_INTERVAL: "f-gov-interval",
    IDLE_TIMEOUT: "f-gov-timeout",
    IDLE_CPU_THD: "f-gov-thd",
    IDLE_POWER_W: "f-gov-power",
  };
  let okAll = true;
  for (const [key, fid] of Object.entries(fields)) {
    const v = document.getElementById(fid).value.trim();
    if (!v) continue;
    try {
      const r = await tryApi("set_idle_cfg.sh", { key, value: v });
      if (!r.ok) { okAll = false; showToast(key + ": " + r.msg); break; }
    } catch (e) { okAll = false; showToast("失败: " + e.message); break; }
  }
  if (okAll) {
    const el = document.getElementById("gov-saved");
    el.classList.remove("hidden");
    setTimeout(() => el.classList.add("hidden"), 2000);
    refreshStatus();
  }
});

/* ---------- 频率限制 ---------- */
document.getElementById("btnSaveFreq").addEventListener("click", async () => {
  const fields = {
    FREQ_CAP: "f-freq-cap",
    FREQ_SCOPE: "f-freq-scope",
    FREQ_OFFSCREEN: "f-freq-offscreen",
    FREQ_OFFSCREEN_CAP: "f-freq-offcap",
  };
  let okAll = true;
  for (const [key, fid] of Object.entries(fields)) {
    const v = document.getElementById(fid).value.trim();
    if (!v) continue;
    try {
      const r = await tryApi("freq_limit.sh", { action: "set", key, value: v });
      if (!r.ok) { okAll = false; showToast(key + ": " + r.msg); break; }
    } catch (e) { okAll = false; showToast("失败: " + e.message); break; }
  }
  if (okAll) {
    const el = document.getElementById("freq-saved");
    el.classList.remove("hidden");
    setTimeout(() => el.classList.add("hidden"), 2000);
    refreshStatus();
  }
});

async function loadGovWhitelist() {
  try {
    const r = await tryApi("idle_whitelist.sh", { action: "list" });
    const ul = document.getElementById("gwl-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      li.innerHTML =
        '<span class="pkg">' + it.pkg + "</span>" +
        '<button class="del" data-pkg="' + it.pkg + '">✕</button>';
      ul.appendChild(li);
    });
  } catch (e) { /* ignore */ }
}

document.getElementById("btnGwlAdd").addEventListener("click", async () => {
  const pkg = document.getElementById("gwl-pkg").value.trim();
  if (!pkg) return;
  try {
    const r = await tryApi("idle_whitelist.sh", { action: "add", pkg });
    showToast(r.msg);
    if (r.ok) { document.getElementById("gwl-pkg").value = ""; loadGovWhitelist(); }
  } catch (e) { showToast("失败: " + e.message); }
});

document.getElementById("gwl-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  try {
    await tryApi("idle_whitelist.sh", { action: "del", pkg: btn.dataset.pkg });
    loadGovWhitelist();
  } catch (e) { /* ignore */ }
});

/* ---------- 分应用策略 ---------- */
async function loadApps() {
  try {
    const r = await tryApi("apps.sh", { action: "list" });
    const ul = document.getElementById("app-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      li.innerHTML =
        '<span class="pkg">' + it.pkg + "</span>" +
        '<span><span class="mode-tag">' + it.mode + "</span>" +
        '<button class="del" data-pkg="' + it.pkg + '">✕</button></span>';
      ul.appendChild(li);
    });
  } catch (e) { /* ignore */ }
}

document.getElementById("btnAppAdd").addEventListener("click", async () => {
  const pkg = document.getElementById("app-pkg").value.trim();
  const mode = document.getElementById("app-mode").value;
  if (!pkg) return;
  try {
    const r = await tryApi("apps.sh", { action: "add", pkg, mode });
    showToast(r.msg);
    if (r.ok) { document.getElementById("app-pkg").value = ""; loadApps(); }
  } catch (e) { showToast("失败: " + e.message); }
});

document.getElementById("app-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  try {
    await tryApi("apps.sh", { action: "del", pkg: btn.dataset.pkg });
    loadApps();
  } catch (e) { /* ignore */ }
});

/* ---------- 白名单 ---------- */
async function loadWhitelist() {
  try {
    const r = await tryApi("whitelist.sh", { action: "list" });
    const ul = document.getElementById("wl-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      li.innerHTML =
        '<span class="pkg">' + it.pkg + "</span>" +
        '<button class="del" data-pkg="' + it.pkg + '">✕</button>';
      ul.appendChild(li);
    });
  } catch (e) { /* ignore */ }
}

document.getElementById("btnWlAdd").addEventListener("click", async () => {
  const pkg = document.getElementById("wl-pkg").value.trim();
  if (!pkg) return;
  try {
    const r = await tryApi("whitelist.sh", { action: "add", pkg });
    showToast(r.msg);
    if (r.ok) { document.getElementById("wl-pkg").value = ""; loadWhitelist(); }
  } catch (e) { showToast("失败: " + e.message); }
});

document.getElementById("wl-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  try {
    await tryApi("whitelist.sh", { action: "del", pkg: btn.dataset.pkg });
    loadWhitelist();
  } catch (e) { /* ignore */ }
});

/* ---------- Doze 白名单 ---------- */
async function loadDoze() {
  try {
    const r = await tryApi("doze.sh", { action: "list" });
    const ul = document.getElementById("doze-list");
    ul.innerHTML = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      li.innerHTML =
        '<span class="pkg">' + it.pkg + "</span>" +
        '<button class="del" data-pkg="' + it.pkg + '">✕</button>';
      ul.appendChild(li);
    });
  } catch (e) { /* ignore */ }
}

document.getElementById("btnDozeAdd").addEventListener("click", async () => {
  const pkg = document.getElementById("doze-pkg").value.trim();
  if (!pkg) return;
  try {
    const r = await tryApi("doze.sh", { action: "add", pkg });
    showToast(r.msg);
    if (r.ok) { document.getElementById("doze-pkg").value = ""; loadDoze(); }
  } catch (e) { showToast("失败: " + e.message); }
});

document.getElementById("doze-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  try {
    await tryApi("doze.sh", { action: "del", pkg: btn.dataset.pkg });
    loadDoze();
  } catch (e) { /* ignore */ }
});

/* ---------- 高级设置: 配置文件读写 ---------- */
async function loadAdvFile(file, elId) {
  try {
    const r = await tryApi("config_file.sh", { action: "get", file });
    document.getElementById(elId).value = (r.lines || []).join("\n");
  } catch (e) { /* ignore */ }
}

async function saveAdvFile(file, elId) {
  const el = document.getElementById(elId);
  try {
    const r = await tryApiPost("config_file.sh", { action: "save", file }, el.value);
    showToast(r.msg);
  } catch (e) {
    showToast("保存失败: " + e.message);
  }
}

document.getElementById("btnSaveAdvMem").addEventListener("click", () => saveAdvFile("mem", "adv-mem"));
document.getElementById("btnSaveAdvIdle").addEventListener("click", () => saveAdvFile("idle", "adv-idle"));
document.getElementById("btnSaveAdvPerapp").addEventListener("click", () => saveAdvFile("perapp", "adv-perapp"));
document.getElementById("btnSaveAdvUperf").addEventListener("click", () => saveAdvFile("uperf", "adv-uperf"));

/* ---------- 操作 ---------- */
document.getElementById("btnReclaim").addEventListener("click", async () => {
  try {
    const r = await tryApi("action.sh", { do: "reclaim" });
    showToast(r.msg);
  } catch (e) { showToast("失败: " + e.message); }
});
document.getElementById("btnRestart").addEventListener("click", async () => {
  if (!confirm("确定重启 memctl 服务？")) return;
  try {
    const r = await tryApi("action.sh", { do: "restart_memctl" });
    showToast(r.msg);
  } catch (e) { showToast("失败: " + e.message); }
});
document.getElementById("btnReload").addEventListener("click", async () => {
  try {
    const r = await tryApi("action.sh", { do: "reload" });
    showToast(r.msg);
  } catch (e) { showToast("失败: " + e.message); }
});

/* ---------- 日志 ---------- */
document.getElementById("btnLog").addEventListener("click", loadLog);
async function loadLog() {
  try {
    const file = document.getElementById("log-file").value;
    const r = await tryApi("log.sh", { lines: 50, file });
    document.getElementById("log-view").textContent = (r.lines || []).join("\n");
  } catch (e) {
    if (e.message !== "switching-to-http") {
      document.getElementById("log-view").textContent = "日志加载失败: " + e.message;
    }
  }
}

/* ---------- Toast ---------- */
function showToast(msg) {
  let t = document.getElementById("toast");
  if (!t) {
    t = document.createElement("div");
    t.id = "toast";
    t.style.cssText =
      "position:fixed;left:50%;bottom:30px;transform:translateX(-50%);" +
      "background:#232838;color:#fff;padding:10px 18px;border-radius:8px;" +
      "font-size:13px;z-index:99;border:1px solid #2a2f3d;max-width:80%;";
    document.body.appendChild(t);
  }
  t.textContent = msg;
  clearTimeout(t._tm);
  t._tm = setTimeout(() => (t.style.display = "none"), 2500);
  t.style.display = "block";
}

/* ---------- 初始化 ---------- */
document.getElementById("btnRefresh").addEventListener("click", () => {
  refreshStatus(); loadApps(); loadWhitelist(); loadGovWhitelist(); loadDoze();
  loadAdvFile("mem", "adv-mem"); loadAdvFile("idle", "adv-idle");
  loadAdvFile("perapp", "adv-perapp"); loadAdvFile("uperf", "adv-uperf");
});
refreshStatus();
loadApps();
loadWhitelist();
loadGovWhitelist();
loadDoze();
loadAdvFile("mem", "adv-mem");
loadAdvFile("idle", "adv-idle");
loadAdvFile("perapp", "adv-perapp");
loadAdvFile("uperf", "adv-uperf");
loadLog();
setInterval(refreshStatus, 15000); // 15 秒自动刷新状态
