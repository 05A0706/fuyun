/* fuyun WebUI 逻辑 (Liquid Glass 版) */
"use strict";

// API 使用相对路径: 页面与 API 同源 (http://127.0.0.1:16800)
// 管理器 (Magisk/KernelSU) 以 https 打开 webroot 时, 首次 API 探测会失败,
// 此时自动跳转到内置 http 服务, 页面与 API 同源后一切正常。
const API = "cgi-bin";
const HTTP_SERVICE = "http://127.0.0.1:16800/";

// F5: 取当前 WebUI 令牌 (优先 URL ?token= 由管理器注入, 否则用页面内置)
function apiToken() {
  try {
    const fromUrl = new URLSearchParams(location.search).get("token");
    if (fromUrl) return fromUrl;
  } catch (e) { /* ignore */ }
  return (typeof WEBUI_TOKEN !== "undefined" && WEBUI_TOKEN) ? WEBUI_TOKEN : "";
}

async function api(path, params) {
  let url = API + "/" + path;
  const all = params ? Object.assign({}, params) : {};
  const tk = apiToken();
  if (tk) all.token = tk;
  if (Object.keys(all).length) {
    const qs = Object.keys(all)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(all[k]))
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
  const all = params ? Object.assign({}, params) : {};
  const tk = apiToken();
  if (tk) all.token = tk;
  if (Object.keys(all).length) {
    const qs = Object.keys(all)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(all[k]))
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

/* ---------- 底部导航 (Glass Bottom Bar, 对应 LiquidBottomTabs) ---------- */
const navbarEl = document.getElementById("navbar");
const tabPill = document.getElementById("tabPill");

// 滑动玻璃胶囊指示器: translateX 按选中索引平移, 按压时 scale 收缩
function setPill(btn, ps) {
  const tabs = Array.from(navbarEl.querySelectorAll(".tab"));
  const i = tabs.indexOf(btn);
  if (i < 0) return;
  tabPill.style.setProperty("--tx", (i * 100) + "%");
  tabPill.style.setProperty("--ps", String(ps || 1));
}

// 高级设置: 5 个配置文件内容并非首屏必需, 切到「高级」页签时才首次拉取
let advLoaded = false;
function loadAdvFilesOnce() {
  if (advLoaded) return;
  advLoaded = true;
  loadAdvFile("fuyun", "adv-fuyun");
  loadAdvFile("whitelist", "adv-whitelist");
  loadAdvFile("perapp", "adv-perapp");
  loadAdvFile("uperf", "adv-uperf");
  loadAdvFile("automation", "adv-automation");
}

navbarEl.addEventListener("click", (ev) => {
  const btn = ev.target.closest(".tab");
  if (!btn || btn.classList.contains("active")) return;
  navbarEl.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t === btn));
  setPill(btn);
  document.querySelectorAll(".page").forEach((p) => p.classList.toggle("active", p.dataset.page === btn.dataset.tab));
  if (btn.dataset.tab === "adv") loadAdvFilesOnce();
  window.scrollTo({ top: 0, behavior: "smooth" });
});
// 按压反馈: 指示器胶囊收缩, 松开回弹
navbarEl.addEventListener("pointerdown", (ev) => {
  const btn = ev.target.closest(".tab");
  if (btn) setPill(btn.classList.contains("active") ? btn : navbarEl.querySelector(".tab.active"), .94);
});
["pointerup", "pointercancel", "pointerleave"].forEach((t) =>
  navbarEl.addEventListener(t, () => {
    const active = navbarEl.querySelector(".tab.active");
    if (active) setPill(active, 1);
  })
);
setPill(document.querySelector("#navbar .tab.active"));

/* ---------- 玻璃滑块: 值映射 / 进度填充 / 数值气泡 ---------- */
// 映射型滑块: 滑块整数刻度 → API 合法值 (避免拖出非法配置)
//   f-gov-power: n → (n+1)/10 (0.1-5.0W)
const FIELD_MAPS = {
  "f-gov-power": {
    max: 49,
    toValue: (i) => ((i + 1) / 10).toFixed(1),
    toIndex: (v) => Math.min(49, Math.max(0, Math.round(Number(v) * 10) - 1)),
  },
};

/* ---------- 表单字段分组 ---------- */
// 四组保存字段集中定义, 供保存/基线快照共用 (保存时只提交与基线不同的字段)
const MEM_FIELDS = {
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
const GOV_FIELDS = {
  IDLE_GOV: "f-gov-enable",
  IDLE_INTERVAL: "f-gov-interval",
  IDLE_TIMEOUT: "f-gov-timeout",
  IDLE_CPU_THD: "f-gov-thd",
  IDLE_POWER_W: "f-gov-power",
};
const CORECTL_FIELDS = {
  CORECTL_ENABLE: "f-ctl-enable",
  BIG_OFF: "f-ctl-bigoff",
  MID_OFF: "f-ctl-midoff",
  OFFSCREEN_OFF: "f-ctl-offscreen",
  IDLE_OFF: "f-ctl-idle",
};

// 字段基线值 (服务端最新值)。保存时只提交与基线不同的字段,
// 避免"改 1 个字段却发 9 个请求、把整个配置文件重写 9 遍"。
const baseline = {};
function snapshotFields(fields) {
  Object.values(fields).forEach((fid) => {
    const el = document.getElementById(fid);
    if (el) baseline[fid] = el.value;
  });
}
// 字段相对基线是否未变更
function unchanged(fid) {
  const el = document.getElementById(fid);
  return !!el && baseline[fid] !== undefined && String(baseline[fid]) === String(el.value);
}

// 读字段实际值 (映射型返回映射后的 API 值)
function getFieldValue(id) {
  const el = document.getElementById(id);
  if (!el) return "";
  const map = FIELD_MAPS[id];
  return map ? map.toValue(Number(el.value)) : el.value.trim();
}

// 写字段值 (映射型做反向映射)
function setFieldValue(id, value) {
  const el = document.getElementById(id);
  if (!el) return;
  const map = FIELD_MAPS[id];
  el.value = map ? map.toIndex(String(value)) : String(value);
}

const sliderUpdaters = {};

// 按压中的滑块盒子集合: 原先每个滑块都往 window 注册 2 个监听 (9 个滑块 = 18 个常驻监听,
// 任何一次 pointerup 都会跑 9 遍 DOM 查询)。改为共享一个集合 + 一对监听。
const pressingBoxes = new Set();
function releasePressing() {
  pressingBoxes.forEach((b) => b.classList.remove("pressing"));
  pressingBoxes.clear();
}
["pointerup", "pointercancel"].forEach((t) =>
  window.addEventListener(t, releasePressing)
);

function bindSlider(id, fmt) {
  const input = document.getElementById(id);
  const box = input ? input.closest(".gs") : null;
  const out = document.getElementById("v-" + id.replace(/^f-/, ""));
  if (!input || !out || !box) return;
  // 速度拉伸 (LiquidSlider layerBlock): 拖得越快玻璃被拉得越长, 松手弹性恢复
  let lastPct = null, lastT = 0, vel = 0, raf = 0;
  const decay = () => {
    vel *= 0.86;
    if (Math.abs(vel) < 0.01) {
      box.style.setProperty("--vs", "1");
      raf = 0;
      return;
    }
    box.style.setProperty("--vs", String(1 + Math.min(0.45, Math.abs(vel))));
    raf = requestAnimationFrame(decay);
  };
  const update = () => {
    const mapped = getFieldValue(id);
    const n = Number(mapped);
    out.textContent = fmt ? fmt(n, mapped) : mapped;
    const min = Number(input.min) || 0;
    const max = Number(input.max) || 100;
    const pct = ((Number(input.value) - min) / (max - min)) * 100;
    box.style.setProperty("--p", pct + "%");   // 进度填充
    box.style.setProperty("--pp", pct + "%");  // 拇指位置
    const now = performance.now();
    if (lastPct !== null) {
      const dt = Math.max(1, now - lastT);
      vel = vel * 0.4 + ((pct - lastPct) / dt) * 0.9;
      if (!raf) raf = requestAnimationFrame(decay);
    }
    lastPct = pct;
    lastT = now;
  };
  input.addEventListener("input", update);
  // 按压状态: 白面浮现 + scale 1.25 (由共享的 releasePressing 统一复位)
  input.addEventListener("pointerdown", () => {
    pressingBoxes.add(box);
    box.classList.add("pressing");
  });
  sliderUpdaters[id] = update;
  update();
}
function refreshSliders() {
  Object.values(sliderUpdaters).forEach((fn) => fn());
}

bindSlider("f-psi");
bindSlider("f-interval", (v) => v + " 秒");
bindSlider("f-idle", (v) => (v === 0 ? "关闭" : v + " 分钟"));
bindSlider("f-maxround");
bindSlider("f-ctl-bigoff", (v) => String(v));
bindSlider("f-ctl-midoff", (v) => String(v));
bindSlider("f-gov-interval", (v) => v + " 秒");
bindSlider("f-gov-timeout", (v) => v + " 秒");
bindSlider("f-gov-thd", (v) => v + " %");
bindSlider("f-gov-power", (v) => v.toFixed(1) + " W");

/* ---------- 状态 ---------- */
function badge(el, ok, text) {
  el.textContent = text;
  el.className = "badge " + (ok ? "ok" : ok === null ? "na" : "bad");
}

async function refreshStatus() {
  try {
    const s = await tryApi("status.sh");
    // 版本信息 (footer)
    const ft = document.getElementById("ft-ver");
    if (ft && s.version) ft.textContent = "v" + s.version;
    badge(document.getElementById("st-uperf"), s.uperf_running === 1, s.uperf_running === 1 ? "运行中" : "未运行");
    badge(document.getElementById("st-memctl"), s.memctl_running === 1, s.memctl_running === 1 ? "运行中" : "未运行");
    document.getElementById("st-mem").textContent = s.mem_available_mb + " MB";
    document.getElementById("st-fg").textContent = s.foreground;
    document.getElementById("st-log").textContent = s.last_log || "-";
    // Vulkan 渲染状态 (状态页 + 管理页徽标)
    const vkEl = document.getElementById("st-vulkan");
    if (vkEl) vkEl.textContent = s.vulkan === 1 ? "Vulkan" : "OpenGL";
    const vkBadge = document.getElementById("vk-badge");
    if (vkBadge) badge(vkBadge, s.vulkan === 1, s.vulkan === 1 ? "Vulkan" : "OpenGL");

    // 模式按钮高亮
    document.querySelectorAll(".mode").forEach((b) => {
      b.classList.toggle("active", b.dataset.mode === s.powermode);
    });

    // 填充配置表单
    setFieldValue("f-mem-enable", String(s.mem_enable));
    setFieldValue("f-mode", s.mode);
    setFieldValue("f-psi", s.psi_threshold);
    setFieldValue("f-interval", s.interval);
    setFieldValue("f-idle", s.idle_kill_min);
    setFieldValue("f-switch", String(s.switch_reclaim));
    setFieldValue("f-maxround", s.max_per_round);

    // 辅助调速器: 状态徽标 + 配置表单
    const govActive = s.idle_gov_active === 1;
    badge(document.getElementById("gov-badge"), govActive, govActive ? "深度空闲中" : "辅助调速");
    setFieldValue("f-gov-enable", String(s.idle_gov_enable));
    setFieldValue("f-gov-interval", s.idle_interval);
    setFieldValue("f-gov-timeout", s.idle_timeout);
    setFieldValue("f-gov-thd", s.idle_cpu_thd);
    setFieldValue("f-gov-power", s.idle_power_w);

    // 核心开关: 徽标只反映总开关/是否已关核, 表单与在线核数由 loadCorectl 单独拉取
    const ctlEnabled = s.corectl_enable === 1;
    const ctlActive = s.corectl_active === 1;
    badge(
      document.getElementById("ctl-badge"),
      ctlActive,
      ctlActive ? "已关核" : ctlEnabled ? "启用" : "停用"
    );

    // 记录基线 (服务端最新值), 保存时据此只提交变更字段
    snapshotFields(MEM_FIELDS);
    snapshotFields(GOV_FIELDS);

    refreshSliders();
  } catch (e) {
    if (e.message !== "switching-to-http") {
      document.getElementById("st-log").textContent = "API 连接失败: " + e.message;
    }
  }
}

/* ---------- 配置预设 (四档内置 + 自定义) ---------- */
async function loadPresets() {
  try {
    const r = await tryApi("preset.sh", { action: "list" });
    const ul = document.getElementById("preset-list");
    ul.textContent = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      const left = document.createElement("span");
      left.className = "pkg";
      left.textContent = it.label || it.name;
      li.appendChild(left);
      const right = document.createElement("span");
      right.className = "li-right";
      const app = document.createElement("button");
      app.className = "btn small";
      app.textContent = "应用";
      app.addEventListener("click", async () => {
        if (!confirm("应用预设「" + (it.label || it.name) + "」？将覆盖 fuyun.conf 对应设置")) return;
        try {
          const rr = await tryApi("preset.sh", { action: "apply", name: it.name });
          showToast(rr.msg);
          if (rr.ok) { refreshStatus(); loadCorectl(); loadPresets(); }
        } catch (e) { showToast("失败: " + e.message); }
      });
      right.appendChild(app);
      if (it.type === "custom") {
        const del = document.createElement("button");
        del.className = "del";
        del.textContent = "✕";
        del.setAttribute("aria-label", "删除预设 " + it.name);
        del.addEventListener("click", async () => {
          if (!confirm("删除自定义预设「" + it.name + "」？")) return;
          try {
            const rr = await tryApi("preset.sh", { action: "delete", name: it.name });
            showToast(rr.msg);
            if (rr.ok) loadPresets();
          } catch (e) { showToast("失败: " + e.message); }
        });
        right.appendChild(del);
      }
      li.appendChild(right);
      ul.appendChild(li);
    });
  } catch (e) { /* ignore */ }
}

document.querySelectorAll("[data-preset]").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const name = btn.dataset.preset;
    if (!confirm("应用预设「" + btn.textContent + "」？将覆盖 fuyun.conf 对应设置")) return;
    try {
      const r = await tryApi("preset.sh", { action: "apply", name });
      showToast(r.msg);
      if (r.ok) { refreshStatus(); loadCorectl(); }
    } catch (e) { showToast("失败: " + e.message); }
  });
});

document.getElementById("btnPresetSave").addEventListener("click", async () => {
  const name = document.getElementById("preset-name").value.trim();
  if (!name) { showToast("请输入预设名"); return; }
  if (!/^[A-Za-z0-9_-]+$/.test(name)) { showToast("预设名仅允许字母数字 _ -"); return; }
  try {
    const r = await tryApi("preset.sh", { action: "save", name });
    showToast(r.msg);
    if (r.ok) { document.getElementById("preset-name").value = ""; loadPresets(); }
  } catch (e) { showToast("失败: " + e.message); }
});

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
  const fields = MEM_FIELDS;
  let okAll = true;
  for (const [key, fid] of Object.entries(fields)) {
    if (unchanged(fid)) continue; // 与服务端值一致, 无需提交
    const v = getFieldValue(fid);
    if (!v) continue;
    try {
      const r = await tryApi("set_mem_cfg.sh", { key, value: v });
      if (!r.ok) { okAll = false; showToast(key + ": " + r.msg); break; }
    } catch (e) { okAll = false; showToast("失败: " + e.message); break; }
  }
  if (okAll) {
    snapshotFields(fields); // 提交成功后刷新基线
    const el = document.getElementById("cfg-saved");
    el.classList.remove("hidden");
    setTimeout(() => el.classList.add("hidden"), 2000);
    refreshStatus();
  }
});

/* ---------- 辅助调速器 ---------- */
document.getElementById("btnSaveGov").addEventListener("click", async () => {
  const fields = GOV_FIELDS;
  let okAll = true;
  for (const [key, fid] of Object.entries(fields)) {
    if (unchanged(fid)) continue; // 与服务端值一致, 无需提交
    const v = getFieldValue(fid);
    if (!v) continue;
    try {
      const r = await tryApi("set_idle_cfg.sh", { key, value: v });
      if (!r.ok) { okAll = false; showToast(key + ": " + r.msg); break; }
    } catch (e) { okAll = false; showToast("失败: " + e.message); break; }
  }
  if (okAll) {
    snapshotFields(fields); // 提交成功后刷新基线
    const el = document.getElementById("gov-saved");
    el.classList.remove("hidden");
    setTimeout(() => el.classList.add("hidden"), 2000);
    refreshStatus();
  }
});

/* ---------- 核心开关 ---------- */
async function loadCorectl() {
  try {
    const r = await tryApi("corectl.sh", { action: "get" });
    setFieldValue("f-ctl-enable", String(r.enable || 0));
    setFieldValue("f-ctl-offscreen", String(r.offscreen || 0));
    setFieldValue("f-ctl-idle", String(r.idle_off === 0 ? 0 : 1));
    // 关核数滑块上限 = 该簇总数 (小核簇永不参与, 故大/中核可整簇关闭)
    const bigMax = Math.max(0, r.big_total || 0);
    const midMax = Math.max(0, r.mid_total || 0);
    const bigEl = document.getElementById("f-ctl-bigoff");
    const midEl = document.getElementById("f-ctl-midoff");
    if (bigEl) {
      bigEl.max = String(bigMax);
      bigEl.value = String(Math.min(Number(r.big_off || 0), bigMax));
    }
    if (midEl) {
      midEl.max = String(midMax);
      midEl.value = String(Math.min(Number(r.mid_off || 0), midMax));
    }
    const active = r.active === 1;
    badge(
      document.getElementById("ctl-badge"),
      active,
      active ? "已关核" : r.enable === 1 ? "启用" : "停用"
    );
    document.getElementById("ctl-status").textContent =
      "当前在线：大核 " + (r.online_big || 0) + "/" + (r.big_total || 0) +
      "，中核 " + (r.online_mid || 0) + "/" + (r.mid_total || 0) +
      "，小核 " + (r.online_little || 0) + "/" + (r.little_total || 0);

    refreshSliders();
    snapshotFields(CORECTL_FIELDS); // 记录基线, 保存时只提交变更字段
  } catch (e) { /* ignore */ }
}

document.getElementById("btnSaveCorectl").addEventListener("click", async () => {
  const fields = CORECTL_FIELDS;
  let okAll = true;
  for (const [key, fid] of Object.entries(fields)) {
    if (unchanged(fid)) continue; // 与服务端值一致, 无需提交
    const v = getFieldValue(fid);
    if (!v) continue;
    try {
      const r = await tryApi("corectl.sh", { action: "set", key, value: v });
      if (!r.ok) { okAll = false; showToast(key + ": " + r.msg); break; }
    } catch (e) { okAll = false; showToast("失败: " + e.message); break; }
  }
  if (okAll) {
    snapshotFields(fields); // 提交成功后刷新基线
    const el = document.getElementById("corectl-saved");
    el.classList.remove("hidden");
    setTimeout(() => el.classList.add("hidden"), 2000);
    loadCorectl();
  }
});

document.getElementById("btnClearCorectl").addEventListener("click", async () => {
  try {
    const r = await tryApi("corectl.sh", { action: "clear" });
    showToast(r.msg);
    loadCorectl();
  } catch (e) { showToast("失败: " + e.message); }
});

/* ---------- 包名列表 (安全渲染: 全部 createElement/textContent, 杜绝 XSS) ---------- */
function renderPkgList(ul, items, withMode) {
  ul.textContent = "";
  (items || []).forEach((it) => {
    const li = document.createElement("li");
    const pkg = document.createElement("span");
    pkg.className = "pkg";
    pkg.textContent = it.pkg;
    li.appendChild(pkg);

    const right = document.createElement("span");
    right.className = "li-right";
    if (withMode) {
      const tag = document.createElement("span");
      tag.className = "mode-tag";
      tag.textContent = it.mode || "global";
      right.appendChild(tag);
    }
    const del = document.createElement("button");
    del.className = "del";
    del.dataset.pkg = it.pkg;
    del.setAttribute("aria-label", "删除 " + it.pkg);
    del.textContent = "✕";
    right.appendChild(del);

    li.appendChild(right);
    ul.appendChild(li);
  });
}

async function loadGovWhitelist() {
  try {
    const r = await tryApi("idle_whitelist.sh", { action: "list" });
    renderPkgList(document.getElementById("gwl-list"), r.items, false);
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
    renderPkgList(document.getElementById("app-list"), r.items, true);
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
    renderPkgList(document.getElementById("wl-list"), r.items, false);
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
    renderPkgList(document.getElementById("doze-list"), r.items, false);
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

/* ---------- 分应用性能模式 (perapp_powermode.txt) ---------- */
async function loadPerapp() {
  try {
    const r = await tryApi("perapp.sh", { action: "list" });
    renderPkgList(document.getElementById("perapp-list"), r.items, true);
  } catch (e) { /* ignore */ }
}

document.getElementById("btnPerappAdd").addEventListener("click", async () => {
  const pkg = document.getElementById("perapp-pkg").value.trim();
  const mode = document.getElementById("perapp-mode").value;
  if (!pkg) return;
  try {
    const r = await tryApi("perapp.sh", { action: "add", pkg, mode });
    showToast(r.msg);
    if (r.ok) { document.getElementById("perapp-pkg").value = ""; loadPerapp(); }
  } catch (e) { showToast("失败: " + e.message); }
});

document.getElementById("perapp-list").addEventListener("click", async (ev) => {
  const btn = ev.target.closest(".del");
  if (!btn) return;
  try {
    await tryApi("perapp.sh", { action: "del", pkg: btn.dataset.pkg });
    loadPerapp();
  } catch (e) { /* ignore */ }
});

/* ---------- 场景自动化快捷规则 ---------- */
// 一键添加常用规则 (复用 config_file.sh 的原子保存, 去重)
async function addAutomationRule(line) {
  try {
    const r = await tryApi("config_file.sh", { action: "get", file: "automation" });
    const lines = r.lines || [];
    if (lines.some((l) => l.trim() === line.trim())) { showToast("该规则已存在"); return; }
    lines.push(line);
    await tryApiPost("config_file.sh", { action: "save", file: "automation" }, lines.join("\n") + "\n");
    showToast("已添加规则: " + line);
    loadAdvFile("automation", "adv-automation");
  } catch (e) { showToast("失败: " + e.message); }
}

document.querySelectorAll("[data-rule]").forEach((btn) => {
  btn.addEventListener("click", () => addAutomationRule(btn.dataset.rule));
});

document.getElementById("btnAutoClear").addEventListener("click", async () => {
  if (!confirm("清空 automation.txt 的全部规则？")) return;
  try {
    const header = "# fuyun 场景自动化规则 (F2)\n# 每行: <触发条件> => <动作>\n";
    await tryApiPost("config_file.sh", { action: "save", file: "automation" }, header);
    showToast("已清空规则");
    loadAdvFile("automation", "adv-automation");
  } catch (e) { showToast("失败: " + e.message); }
});

/* ---------- 高级设置: 配置文件读写 ---------- */
async function loadAdvFile(file, elId) {
  try {
    const r = await tryApi("config_file.sh", { action: "get", file });
    document.getElementById(elId).value = (r.lines || []).join("\n");
  } catch (e) { /* ignore */ }
}

// 轻量 JSON 括号平衡校验 (与 cgi-bin/config_file.sh 的 json_balanced 一致, 保存前即时反馈)
function jsonBalanced(text) {
  const body = text.replace(/\\./g, "").replace(/"(\\.[^"\\]*|[^"\\])*"/g, "");
  let n = 0;
  for (const ch of body) {
    if (ch === "{" || ch === "[") n++;
    else if (ch === "}" || ch === "]") { n--; if (n < 0) return false; }
  }
  return n === 0;
}

async function saveAdvFile(file, elId) {
  const el = document.getElementById(elId);
  const v = el.value;
  // uperf.json 保存前前端校验, 改坏立即提示
  if (file === "uperf") {
    const head = v.trimStart()[0], tail = v.trimEnd().slice(-1);
    if (head !== "{" || tail !== "}") { showToast("uperf.json 需以 { 开头并以 } 结尾"); return; }
    if (!jsonBalanced(v)) { showToast("uperf.json 括号不匹配, 请检查后再保存"); return; }
  }
  try {
    const r = await tryApiPost("config_file.sh", { action: "save", file }, v);
    showToast(r.msg);
    if (r.ok && file === "uperf") showToast("已保存, 请点击「操作 → 重启 uperf」或重启设备生效");
  } catch (e) {
    showToast("保存失败: " + e.message);
  }
}

document.getElementById("btnSaveAdvFuyun").addEventListener("click", () => saveAdvFile("fuyun", "adv-fuyun"));
document.getElementById("btnSaveAdvWhitelist").addEventListener("click", () => saveAdvFile("whitelist", "adv-whitelist"));
document.getElementById("btnSaveAdvPerapp").addEventListener("click", () => saveAdvFile("perapp", "adv-perapp"));
document.getElementById("btnSaveAdvUperf").addEventListener("click", () => saveAdvFile("uperf", "adv-uperf"));
document.getElementById("btnSaveAdvAutomation").addEventListener("click", () => saveAdvFile("automation", "adv-automation"));

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
document.getElementById("btnRestartUperf").addEventListener("click", async () => {
  if (!confirm("确定重启 uperf？")) return;
  try {
    const r = await tryApi("action.sh", { do: "restart_uperf" });
    showToast(r.msg);
    refreshStatus();
  } catch (e) { showToast("失败: " + e.message); }
});
document.getElementById("btnReload").addEventListener("click", async () => {
  try {
    const r = await tryApi("action.sh", { do: "reload" });
    showToast(r.msg);
  } catch (e) { showToast("失败: " + e.message); }
});

/* ---------- F3: 配置导出/导入 ---------- */
document.getElementById("btnBackupExport").addEventListener("click", async () => {
  try {
    const r = await tryApi("backup.sh", { action: "export" });
    if (!r.ok) { showToast(r.msg); return; }
    const bin = atob(r.data);
    const u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    const blob = new Blob([u8], { type: "application/gzip" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = r.name || "fuyun_config.tar.gz";
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    showToast("已导出 " + (r.count || 0) + " 个配置文件");
  } catch (e) { showToast("导出失败: " + e.message); }
});

document.getElementById("btnBackupImport").addEventListener("click", () => {
  document.getElementById("backup-import").click();
});

document.getElementById("backup-import").addEventListener("change", async (ev) => {
  const file = ev.target.files[0];
  if (!file) return;
  try {
    const buf = await file.arrayBuffer();
    const u8 = new Uint8Array(buf);
    let binstr = "";
    for (let i = 0; i < u8.length; i++) binstr += String.fromCharCode(u8[i]);
    const b64 = btoa(binstr);
    const r = await tryApiPost("backup.sh", { action: "import" }, b64);
    showToast(r.msg);
    if (r.ok) { refreshStatus(); loadCorectl(); }
  } catch (e) { showToast("导入失败: " + e.message); }
  ev.target.value = "";
});

/* ---------- 插件管理 ---------- */
async function loadPlugins() {
  try {
    const r = await tryApi("plugins.sh", { action: "list" });
    const ul = document.getElementById("plugin-list");
    ul.textContent = "";
    (r.items || []).forEach((it) => {
      const li = document.createElement("li");
      const left = document.createElement("span");
      left.className = "pkg mono";
      left.textContent = it.name;
      li.appendChild(left);

      const right = document.createElement("span");
      right.className = "li-right";
      // 类型徽标
      const tag = document.createElement("span");
      tag.className = "mode-tag";
      tag.textContent =
        it.type === "config" ? (it.applied === 1 ? "特调·使用中" : "特调") :
        it.type === "json" ? "JSON" : "脚本";
      right.appendChild(tag);
      // 状态徽标
      const st = document.createElement("span");
      st.className = "mode-tag";
      st.textContent = it.enabled === 1 || it.type === "config" ? (it.applied === 1 ? "已应用" : "启用") : "停用";
      right.appendChild(st);
      // 操作按钮
      if (it.type === "config") {
        const app = document.createElement("button");
        app.className = "btn small";
        app.textContent = it.applied === 1 ? "已应用" : "应用此配置";
        if (it.applied !== 1) {
          app.addEventListener("click", async () => {
            if (!confirm("应用该特调配置？当前配置将备份为 .bak，uperf 会重启")) return;
            try {
              const rr = await tryApi("plugins.sh", { action: "apply_config", name: it.name });
              showToast(rr.msg);
              if (rr.ok) { refreshStatus(); loadPlugins(); }
            } catch (e) { showToast("失败: " + e.message); }
          });
        }
        right.appendChild(app);
      } else {
        const tg = document.createElement("button");
        tg.className = "btn small";
        tg.textContent = it.enabled === 1 ? "停用" : "启用";
        tg.addEventListener("click", async () => {
          try {
            const rr = await tryApi("plugins.sh", { action: it.enabled === 1 ? "disable" : "enable", name: it.name });
            showToast(rr.msg);
            if (rr.ok) loadPlugins();
          } catch (e) { showToast("失败: " + e.message); }
        });
        right.appendChild(tg);
      }
      const del = document.createElement("button");
      del.className = "del";
      del.textContent = "✕";
      del.setAttribute("aria-label", "删除 " + it.name);
      del.addEventListener("click", async () => {
        if (!confirm("删除插件 " + it.name + "？")) return;
        try {
          const rr = await tryApi("plugins.sh", { action: "delete", name: it.name });
          showToast(rr.msg);
          if (rr.ok) loadPlugins();
        } catch (e) { showToast("失败: " + e.message); }
      });
      right.appendChild(del);

      li.appendChild(right);
      ul.appendChild(li);
    });
  } catch (e) { /* ignore */ }
}

document.getElementById("btnPluginLog").addEventListener("click", async () => {
  try {
    const r = await tryApi("plugins.sh", { action: "log", lines: 100 });
    document.getElementById("plugin-log-view").textContent = (r.lines || []).join("\n");
  } catch (e) {
    document.getElementById("plugin-log-view").textContent = "插件日志加载失败: " + e.message;
  }
});

/* ---------- 渲染后端切换 (Vulkan / OpenGL) ---------- */
function setVulkan(mode) {
  return tryApi("vulkan.sh", { action: "set", mode });
}
document.getElementById("btnVkOn").addEventListener("click", async () => {
  if (!confirm("切换为 Vulkan？完全生效需重启，开机会自动保持")) return;
  try {
    const r = await setVulkan("vulkan");
    showToast(r.msg);
    refreshStatus();
  } catch (e) { showToast("失败: " + e.message); }
});
document.getElementById("btnVkOff").addEventListener("click", async () => {
  if (!confirm("还原 OpenGL？完全生效需重启，开机会自动保持")) return;
  try {
    const r = await setVulkan("opengl");
    showToast(r.msg);
    refreshStatus();
  } catch (e) { showToast("失败: " + e.message); }
});

/* ---------- 日志 ---------- */
document.getElementById("btnLog").addEventListener("click", loadLog);
let logTimer = null;
async function loadLog() {
  try {
    const file = document.getElementById("log-file").value;
    const lines = document.getElementById("log-lines").value || 50;
    const r = await tryApi("log.sh", { lines, file });
    document.getElementById("log-view").textContent = (r.lines || []).join("\n");
  } catch (e) {
    if (e.message !== "switching-to-http") {
      document.getElementById("log-view").textContent = "日志加载失败: " + e.message;
    }
  }
}
// 自动刷新: 勾选后每 5s 重载一次当前日志
document.getElementById("log-auto").addEventListener("change", (ev) => {
  if (ev.target.checked) {
    loadLog();
    logTimer = setInterval(loadLog, 5000);
  } else if (logTimer) {
    clearInterval(logTimer);
    logTimer = null;
  }
});

/* ---------- Toast ---------- */
function showToast(msg) {
  let t = document.getElementById("toast");
  if (!t) {
    t = document.createElement("div");
    t.id = "toast";
    t.style.cssText =
      "position:fixed;left:50%;bottom:calc(84px + env(safe-area-inset-bottom, 0px));transform:translateX(-50%);" +
      "background:rgba(16,22,44,.78);color:#eef1ff;padding:10px 18px;border-radius:14px;" +
      "font-size:13px;z-index:200;border:1px solid rgba(255,255,255,.2);" +
      "box-shadow:0 10px 30px rgba(2,6,23,.6), 0 0 18px rgba(58,128,255,.15), inset 0 1px 0 rgba(255,255,255,.3);" +
      "max-width:80%;backdrop-filter:blur(18px) saturate(1.6);-webkit-backdrop-filter:blur(18px) saturate(1.6);";
    document.body.appendChild(t);
  }
  t.textContent = msg;
  clearTimeout(t._tm);
  t._tm = setTimeout(() => (t.style.display = "none"), 2500);
  t.style.display = "block";
}

/* ---------- 初始化 ---------- */
document.getElementById("btnRefresh").addEventListener("click", () => {
  refreshStatus(); loadCorectl(); loadApps(); loadWhitelist(); loadGovWhitelist(); loadDoze();
  loadPerapp(); loadPlugins(); loadPresets();
  loadAdvFile("fuyun", "adv-fuyun"); loadAdvFile("whitelist", "adv-whitelist");
  loadAdvFile("perapp", "adv-perapp"); loadAdvFile("uperf", "adv-uperf");
  loadAdvFile("automation", "adv-automation");
});
refreshStatus();
loadCorectl();
loadApps();
loadWhitelist();
loadGovWhitelist();
loadDoze();
loadPerapp();
loadPlugins();
loadPresets();
loadLog();
// 高级设置的配置文件改为切到「高级」页签时按需加载 (见 loadAdvFilesOnce)
setInterval(() => {
  // 页面在后台时不打后端: WebView 未必会节流定时器, 显式跳过可省掉无谓的 CGI 调用
  if (!document.hidden) refreshStatus();
}, 15000);
