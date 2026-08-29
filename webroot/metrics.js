/* F4: 实时运行曲线 (原生 Canvas, 无图表库)
 * 每 2 秒采样 metrics.sh, 在环形缓冲中保留最近 MAX 个点, 绘制大/中/小核平均频率曲线。
 * 仅在状态页可见时轮询, 页面进入后台即停止, 避免无谓 CGI 调用。
 */
(function () {
  "use strict";
  var canvas = document.getElementById("metrics-canvas");
  if (!canvas) return;
  var ctx = canvas.getContext("2d");
  var MAX = 60;
  var buf = [];
  var timer = null;

  function resize() {
    var dpr = window.devicePixelRatio || 1;
    var w = canvas.clientWidth, h = canvas.clientHeight;
    if (!w || !h) return;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function draw() {
    var w = canvas.clientWidth, h = canvas.clientHeight;
    if (!w || !h) return;
    ctx.clearRect(0, 0, w, h);
    if (buf.length < 2) {
      ctx.fillStyle = "#8a93b8";
      ctx.font = "12px sans-serif";
      ctx.fillText("采集中…", 10, h / 2);
      return;
    }
    var maxF = 1;
    buf.forEach(function (p) {
      if (p.big > maxF) maxF = p.big;
      if (p.mid > maxF) maxF = p.mid;
      if (p.little > maxF) maxF = p.little;
    });
    var padL = 30, padB = 14, padT = 8, padR = 8;
    var plotW = w - padL - padR, plotH = h - padT - padB;
    ctx.strokeStyle = "rgba(255,255,255,0.08)";
    ctx.fillStyle = "#8a93b8";
    ctx.font = "10px sans-serif";
    ctx.lineWidth = 1;
    for (var i = 0; i <= 4; i++) {
      var y = padT + (plotH * i) / 4;
      ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(w - padR, y); ctx.stroke();
      ctx.fillText(String(Math.round(maxF * (1 - i / 4))), 4, y + 3);
    }
    function line(key, color) {
      ctx.strokeStyle = color; ctx.lineWidth = 1.6; ctx.beginPath();
      buf.forEach(function (p, idx) {
        var x = padL + plotW * (idx / (MAX - 1));
        var y = padT + plotH * (1 - p[key] / maxF);
        if (idx === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
    }
    line("big", "#ff6b6b");
    line("mid", "#ffd166");
    line("little", "#4dd4ac");
    ctx.font = "10px sans-serif";
    ctx.fillStyle = "#ff6b6b"; ctx.fillText("大核", padL + 2, padT + 10);
    ctx.fillStyle = "#ffd166"; ctx.fillText("中核", padL + 34, padT + 10);
    ctx.fillStyle = "#4dd4ac"; ctx.fillText("小核", padL + 66, padT + 10);
    var last = buf[buf.length - 1];
    ctx.fillStyle = "#8a93b8";
    ctx.fillText("内存 " + last.mem + " MB", padL + 2, h - 3);
  }

  function tick() {
    if (typeof tryApi !== "function") return;
    tryApi("metrics.sh").then(function (r) {
      if (r && r.ok) {
        buf.push({ big: r.big_freq, mid: r.mid_freq, little: r.little_freq, mem: r.mem_avail_mb });
        while (buf.length > MAX) buf.shift();
        draw();
      }
    }).catch(function () { /* 忽略瞬时失败 */ });
  }

  function start() {
    if (timer) return;
    resize();
    tick();
    timer = setInterval(tick, 2000);
  }
  function stop() {
    if (timer) { clearInterval(timer); timer = null; }
  }
  function homeActive() {
    var p = document.querySelector(".page.active");
    return p && p.dataset.page === "home";
  }

  window.addEventListener("resize", resize);
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) stop();
    else if (homeActive()) start();
  });
  var nav = document.getElementById("navbar");
  if (nav) nav.addEventListener("click", function (ev) {
    var btn = ev.target.closest(".tab");
    if (btn && btn.dataset.tab === "home") start();
    else stop();
  });
  if (homeActive()) start();
})();
