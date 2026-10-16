<script>
  // Throughput of the current phase: rolling 30 s rate, with the whole-phase average dashed.
  import { live, rates, isLive } from "../lib/state.svelte.js";
  import { css, fmtN, fmtSI, fmtDur } from "../lib/util.js";

  let { themeTick } = $props();
  let box, canvas, tip;
  let hoverX = $state(null);
  let width = $state(0), height = $state(0);

  const series = () => {
    if (!rates.length) return [];
    const [, phase, level] = rates[rates.length - 1];
    let i = rates.length - 1;
    while (i > 0 && rates[i - 1][1] === phase && rates[i - 1][2] === level) i--;
    return rates.slice(i);
  };
  let title = $state("Throughput"), sub = $state("");

  function niceMax(v) { const p = 10 ** Math.floor(Math.log10(v)); for (const m of [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) if (m * p >= v) return m * p; return 10 * p; }

  $effect(() => {
    // redraw on new samples, resize, hover or theme change
    live.ratesVersion; themeTick; hoverX; width; height;
    const overall = live.S?.progress?.rate_overall;
    draw(overall);
  });

  function draw(overall) {
    const W = width, H = height, dpr = window.devicePixelRatio || 1;
    if (!W || !canvas) return;
    if (canvas.width !== W * dpr || canvas.height !== H * dpr) { canvas.width = W * dpr; canvas.height = H * dpr; }
    const g = canvas.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    const pts = series(), verify = pts.length && pts[0][1] === "verify", unit = verify ? "exprs/s" : "expr/s";
    title = pts.length ? `Throughput · ${verify ? "verify" : "enumerate"}` : "Throughput";
    sub = pts.length ? `cost ${pts[0][2]}` : "";
    g.font = `11px ${css("--font")}`;
    if (pts.length < 2) {
      g.fillStyle = css("--muted"); g.textAlign = "center"; g.textBaseline = "middle";
      g.fillText(isLive() ? "Collecting samples" : "Throughput appears here while a run is active", W / 2, H / 2);
      tip.style.display = "none";
      return;
    }
    const L = 52, R = 12, T = 12, B = 26, t0 = pts[0][0], t1 = pts[pts.length - 1][0];
    let ymax = 0;
    for (const p of pts) ymax = Math.max(ymax, p[3]);
    if (overall) ymax = Math.max(ymax, overall);
    ymax = ymax > 0 ? niceMax(ymax * 1.1) : 1;
    const x = (t) => L + (W - L - R) * (t1 > t0 ? (t - t0) / (t1 - t0) : 1), y = (v) => T + (H - T - B) * (1 - v / ymax);
    g.strokeStyle = css("--line"); g.fillStyle = css("--muted"); g.lineWidth = 1; g.textAlign = "right"; g.textBaseline = "middle";
    for (let i = 0; i <= 4; i++) { const v = (ymax * i) / 4, yy = Math.round(y(v)) + 0.5; g.beginPath(); g.moveTo(L, yy); g.lineTo(W - R, yy); g.stroke(); g.fillText(fmtSI(v), L - 10, yy); }
    g.textBaseline = "top"; g.textAlign = "left"; g.fillText(fmtDur(t1 - t0) + " ago", L, H - B + 8); g.textAlign = "right"; g.fillText("now", W - R, H - B + 8);
    const a1 = css("--accent");
    const grad = g.createLinearGradient(0, T, 0, H - B); grad.addColorStop(0, a1 + "26"); grad.addColorStop(1, a1 + "00");
    const path = () => { g.beginPath(); pts.forEach((p, i) => { const px = x(p[0]), py = y(p[3]); if (!i) g.moveTo(px, py); else { const q = pts[i - 1], mx = (x(q[0]) + px) / 2; g.bezierCurveTo(mx, y(q[3]), mx, py, px, py); } }); };
    path(); g.lineTo(x(t1), y(0)); g.lineTo(x(t0), y(0)); g.closePath(); g.fillStyle = grad; g.fill();
    path(); g.strokeStyle = a1; g.lineWidth = 1.75; g.lineJoin = "round"; g.stroke();
    if (overall) { g.setLineDash([5, 5]); g.strokeStyle = css("--muted"); g.lineWidth = 1.5; g.beginPath(); g.moveTo(L, y(overall)); g.lineTo(W - R, y(overall)); g.stroke(); g.setLineDash([]); }
    const last = pts[pts.length - 1]; g.fillStyle = a1; g.beginPath(); g.arc(x(last[0]), y(last[3]), 4, 0, 7); g.fill();
    if (hoverX != null && hoverX >= L - 10) {
      let lo = 0, hi = pts.length - 1;
      while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (x(pts[mid][0]) < hoverX) lo = mid; else hi = mid; }
      const best = Math.abs(x(pts[lo][0]) - hoverX) < Math.abs(x(pts[hi][0]) - hoverX) ? pts[lo] : pts[hi];
      const bx = x(best[0]), by = y(best[3]);
      g.strokeStyle = css("--line-2"); g.lineWidth = 1; g.beginPath(); g.moveTo(Math.round(bx) + 0.5, T); g.lineTo(Math.round(bx) + 0.5, H - B); g.stroke();
      g.fillStyle = a1; g.strokeStyle = css("--surface"); g.lineWidth = 3; g.beginPath(); g.arc(bx, by, 5, 0, 7); g.fill(); g.stroke();
      tip.innerHTML = `<b>${fmtN(Math.round(best[3]))}</b> ${unit}<br><span class="muted">${t1 - best[0] < 1 ? "now" : fmtDur(t1 - best[0]) + " ago"}</span>`;
      tip.style.display = "block";
      tip.style.left = Math.min(Math.max(0, bx - tip.offsetWidth / 2), W - tip.offsetWidth) + "px";
      tip.style.top = Math.max(0, by - 54) + "px";
    } else tip.style.display = "none";
  }
</script>

<div class="card">
  <div class="card-h">
    <h2>{title}</h2><span class="sub">{sub}</span><span class="spacer"></span>
    <div class="legend"><span><i style="background:var(--accent)"></i>30 s average</span><span><i class="dash"></i>whole phase</span></div>
  </div>
  <div class="chart" bind:this={box} bind:clientWidth={width} bind:clientHeight={height}
    onpointermove={(e) => (hoverX = e.clientX - box.getBoundingClientRect().left)} onpointerleave={() => (hoverX = null)} role="img" aria-label="Throughput chart">
    <canvas bind:this={canvas}></canvas>
    <div class="tip" bind:this={tip}></div>
  </div>
</div>
