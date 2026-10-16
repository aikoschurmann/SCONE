<script>
  import Icon from "./Icon.svelte";
  import { live, isLive } from "../lib/state.svelte.js";
  import { fmtN, fmtSI, fmtDur, fmtUs, hl, tipRows } from "../lib/util.js";

  const S = $derived(live.S);
  const verifying = $derived(isLive() && S?.progress?.kind === "verify");
  const z = $derived(S?.z3now);
  import { serverNow } from "../lib/state.svelte.js";
  // seconds since the engine last wrote its status; worker timers keep counting from it
  const lag = $derived(z ? Math.max(0, serverNow() - z.now_ms / 1000) : 0);

  // ---- workers ----
  let openWorker = $state(null);
  const RC = 2 * Math.PI * 22;

  // ---- work queue ----
  const queue = $derived.by(() => {
    if (!z) return null;
    const bk = z.buckets.filter((b) => b.tasks);
    const total = bk.reduce((a, b) => a + b.exprs, 0) || 1;
    const label = (b) => {
      const i = z.buckets.indexOf(b);
      if (i === 0) return fmtN(b.min_size);
      const hi = z.buckets[i - 1].min_size - 1;
      return hi === b.min_size ? fmtN(b.min_size) : `${fmtN(b.min_size)}–${fmtN(hi)}`;
    };
    const started = bk.reduce((a, b) => a + b.exprs * (b.started / b.tasks), 0);
    const cur = bk.find((b) => b.started > 0 && b.started < b.tasks) || bk.find((b) => b.started < b.tasks);
    return {
      pct: (started / total) * 100,
      cur: cur ? label(cur) : null,
      segs: bk.map((b) => {
        const f = b.started / b.tasks;
        return {
          key: b.min_size, label: label(b), f, exprs: b.exprs,
          state: f >= 1 ? "done" : b === cur ? "cur" : "",
          grow: Math.max(b.exprs / total, 0.035).toFixed(4),
          pctText: f >= 1 ? "done" : (f * 100).toFixed(f && f < 0.1 ? 1 : 0) + "%",
          tip: tipRows(label(b) + " members per task", [["expressions", fmtN(b.exprs)], ["share of all work", ((b.exprs / total) * 100).toFixed(1) + "%"], ["tasks", fmtN(b.tasks)], ["started", `${fmtN(b.started)} (${(f * 100).toFixed(1)}%)`]]),
        };
      }),
    };
  });

  // ---- query log ----
  const RES = { unsat: ["proven", "good"], sat: ["counterexample", "info"], timeout: ["query timeout", "warn"] };
  const HIST_TICK = ["<.5", "1", "2", "4", "8", "16", "33", "66", "131", "262", "524", ">.5s"];
  const HIST_L = ["under 0.5 ms", "0.5–1 ms", "1–2 ms", "2–4 ms", "4–8 ms", "8–16 ms", "16–33 ms", "33–66 ms", "66–131 ms", "131–262 ms", "262–524 ms", "over 0.5 s"];
  let zdata = $state(null);
  let zview = $state("families"), zres = $state(""), zq = $state("");
  let open = $state(new Set());

  async function loadZ3() {
    const r = await fetch("/api/z3log").then((r) => r.json()).catch(() => null);
    if (r) zdata = r;
  }
  $effect(() => {
    loadZ3();
    const t = setInterval(() => { if (!document.hidden) loadZ3(); }, 3000);
    return () => clearInterval(t);
  });

  const totUs = $derived(zdata ? Object.values(zdata.by_result).reduce((a, x) => a + x.us, 0) || 1 : 1);
  const norm = (s) => s.toLowerCase().replace(/\s/g, "");
  const keep = (x) => (!zres || x.result === zres) && (!zq || norm(x.base + x.member).includes(norm(zq)));
  const famKey = (f) => f.result + "|" + f.base + "|" + f.member;
  function toggle(k) { const n = new Set(open); n.has(k) ? n.delete(k) : n.add(k); open = n; }

  function hist(f) {
    const h = f.hist, total = h.reduce((a, b) => a + b, 0) || 1, max = Math.max(1, ...h), peak = h.indexOf(max);
    let acc = 0, med = 0;
    for (let i = 0; i < h.length; i++) { acc += h[i]; if (acc >= total / 2) { med = i; break; } }
    const slow = h.slice(8).reduce((a, b) => a + b, 0);
    return { h, total, max, peak, med, slow };
  }
  const COLS = { unsat: "var(--good)", sat: "var(--info)", timeout: "var(--warn)" };
</script>

<section class="view">
  <div class="card">
    <div class="card-h"><h2>Workers</h2><span class="sub">{verifying && z ? `${z.workers.filter(Boolean).length} busy · task ${fmtN(z.next_task)} of ${fmtN(z.tasks)} handed out` : ""}</span>
      {#if verifying && z && lag > 5}<span class="stale" data-tip="The engine updates this view when a worker finishes a batch of Z3 queries; every worker is inside a long query right now.">last update {fmtDur(lag)} ago</span>{/if}</div>
    {#if verifying && z}
      <div class="workers">
        {#each z.workers as w, i (i)}
          {#if w}
            {@const s = w.age_ms / 1000 + lag}
            {@const col = s > 120 ? "var(--bad)" : s > 20 ? "var(--warn)" : "var(--good)"}
            <div class="wt" class:open={openWorker === i} style={s > 120 ? "border-color:color-mix(in srgb, var(--bad) 45%, transparent)" : ""}
              onclick={() => (openWorker = openWorker === i ? null : i)} role="button" tabindex="0" onkeydown={(e) => e.key === "Enter" && (openWorker = openWorker === i ? null : i)}>
              <div class="mini"><svg viewBox="0 0 52 52"><circle cx="26" cy="26" r="22" stroke="var(--surface-3)" stroke-width="5" fill="none" /><circle cx="26" cy="26" r="22" stroke={col} stroke-width="5" fill="none" stroke-linecap="round" stroke-dasharray={RC.toFixed(2)} stroke-dashoffset={(RC * (1 - Math.min(1, s / 120))).toFixed(2)} /></svg><span class="t">{fmtDur(s)}</span></div>
              <div style="min-width:0">
                <div class="ex" title={w.expr}>{@html hl(w.expr)}</div>
                <div class="meta"><span>worker {i + 1}</span><span>class #{w.class}</span><span>{fmtN(w.members)} members</span><span>{fmtN(w.queries)} queries</span><span>{fmtN(w.ces)} CEs</span>{#if w.timeouts}<span style="color:var(--bad)">{w.timeouts} gave up</span>{/if}</div>
              </div>
              {#if openWorker === i}
                <div class="detail">{@html hl(w.expr)}<div class="muted" style="font-family:var(--font);margin-top:6px;font-size:12px">task {fmtN(w.task)} · running {fmtDur(s)} · {fmtN(w.members)} members checked against this base</div></div>
              {/if}
            </div>
          {:else}
            <div class="wt idle"><div class="mini"></div><div><div class="ex muted">idle</div><div class="meta"><span>worker {i + 1}</span></div></div></div>
          {/if}
        {/each}
      </div>
    {:else}
      <div class="empty"><Icon name="cpu" /><b>{isLive() && S?.progress?.kind === "verify" ? "No live worker view" : "Not verifying"}</b>{isLive() && S?.progress?.kind === "verify" ? "This run's engine predates the live view; rebuild the engine and start a new run." : "Workers appear here while a level is being verified."}</div>
    {/if}
  </div>

  <div class="card">
    <div class="card-h"><h2>Work queue</h2><span class="sub">members per task, largest first</span><span class="spacer"></span>
      <span class="sub" style="color:var(--text-2)">{verifying && queue ? `${queue.pct.toFixed(1)}% handed out${queue.cur ? ` · now on ${queue.cur}-member tasks` : ""}` : ""}</span></div>
    {#if verifying && queue}
      <div class="qseg2">
        {#each queue.segs as g (g.key)}
          <div class="qs {g.state}" style="flex:{g.grow} 1 0" data-tip={g.tip}><span style="width:{(g.f * 100).toFixed(1)}%"></span><em>{g.label}</em></div>
        {/each}
      </div>
      <div class="qsl">
        {#each queue.segs as g (g.key)}
          <div class="ql {g.state}" style="flex:{g.grow} 1 0"><b>{fmtSI(g.exprs)}</b>{g.pctText}</div>
        {/each}
      </div>
    {:else}
      <div class="empty"><Icon name="list" /><b>No work queue</b>Shows how far verification is through the class sizes.</div>
    {/if}
  </div>

  <div class="card">
    <div class="card-h"><h2>Query log</h2><span class="sub">{zdata?.queries ? `${fmtN(zdata.queries)} queries logged` : ""}</span></div>
    {#if !zdata}
      <div class="empty"><Icon name="search" /><b>Loading query log</b>Reading the engine's query logs.</div>
    {:else if !zdata.queries}
      <div class="empty"><Icon name="search" /><b>{zdata.enabled ? "Waiting for Z3 queries" : "Query logging is off for this run"}</b>{zdata.enabled ? "Queries appear once verification starts (or while the server catches up on existing logs)." : "Turn on Log Z3 queries in New run, then start or restart a run."}</div>
    {:else}
      <div class="zsum">
        <div class="kpi"><div class="k">Solver time</div><div class="v">{fmtUs(totUs)}</div>
          <div class="bar2" style="height:10px">
            {#each ["unsat", "sat", "timeout"] as k (k)}
              {@const x = zdata.by_result[k] || { queries: 0, us: 0 }}
              <span style="flex-grow:{x.us};background:{COLS[k]}" data-tip={tipRows(RES[k][0], [["solver time", `${fmtUs(x.us)} (${((x.us / totUs) * 100).toFixed(1)}%)`], ["queries", fmtN(x.queries)], ["average", x.queries ? fmtUs(x.us / x.queries) : "–"]])}></span>
            {/each}
          </div>
        </div>
        {#each ["unsat", "sat", "timeout"] as k (k)}
          {@const x = zdata.by_result[k] || { queries: 0, us: 0 }}
          <div class="kpi"><div class="k"><span class="badge {RES[k][1]}">{RES[k][0]}</span></div><div class="v">{Math.round((x.us / totUs) * 100)}%</div><div class="d" style="color:var(--text-2)">{fmtN(x.queries)} queries · avg {x.queries ? fmtUs(x.us / x.queries) : "–"}</div></div>
        {/each}
      </div>

      <div class="toolbar">
        <div class="chips">
          {#each [["families", "Costliest families"], ["slowest", "Slowest queries"], ["bases", "By base"], ["recent", "Live feed"]] as [v, l] (v)}
            <button class="chip" aria-pressed={zview === v} onclick={() => (zview = v)}>{l}</button>
          {/each}
        </div>
        <div class="chips">
          {#each [["", "All"], ["unsat", "Proven"], ["sat", "Counterexample"], ["timeout", "Timeout"]] as [v, l] (v)}
            <button class="chip" aria-pressed={zres === v} onclick={() => (zres = v)}>{l}</button>
          {/each}
        </div>
        <div class="search"><Icon name="search" cls="sm" /><input id="zQ" placeholder="Filter by expression" bind:value={zq} /></div>
      </div>

      <div class="list">
        {#if zview === "families"}
          {#each zdata.families.filter(keep) as f, fi (fi)}
            {@const k = famKey(f)}
            <div class="row" class:open={open.has(k)}>
              <div class="row-h" onclick={() => toggle(k)} role="button" tabindex="0" onkeydown={(e) => e.key === "Enter" && toggle(k)}>
                <span class="e">{@html hl(f.base)}</span><span class="e">{@html hl(f.member)}</span>
                <span class="badge {RES[f.result]?.[1]}">{RES[f.result]?.[0] ?? f.result}</span>
                <span class="t">{fmtN(f.count)}<br /><small class="muted">members</small></span>
                <span class="t"><b>{fmtUs(f.us)}</b><br /><small class="muted">avg {fmtUs(f.us / f.count)}</small></span>
                <Icon name="right" cls="sm chev" />
              </div>
              {#if open.has(k)}
                <div class="row-b split">
                  <div class="ex-list">
                    {#each f.examples || [] as x, xi (xi)}
                      <div class="ex-i"><span>{@html hl(x.base)}</span><span class="arrow">vs</span><span>{@html hl(x.member)}</span><span class="t num muted" style="text-align:right">{fmtUs(x.us)}</span></div>
                    {/each}
                  </div>
                  {#if f.hist}
                    {@const H = hist(f)}
                    <div class="hcard">
                      <div class="ht"><b>Time per member</b><span class="muted">{fmtN(H.total)} members</span></div>
                      <div class="hs">typically {HIST_L[H.med]} · {((H.slow / H.total) * 100).toFixed(0)}% take over 66 ms</div>
                      <div class="hgraph">
                        {#each H.h as c, bi (bi)}
                          <div class="hb" class:peak={bi === H.peak} class:slow={bi >= 8} class:zero={!c} data-tip={tipRows(HIST_L[bi], [["members", fmtN(c)], ["share", ((c / H.total) * 100).toFixed(1) + "%"]])}>
                            <span style="height:{c ? Math.max(3, (c / H.max) * 100).toFixed(1) : 1}%"></span>
                          </div>
                        {/each}
                      </div>
                      <div class="hticks">{#each HIST_TICK as t (t)}<span>{t}</span>{/each}</div>
                      <div class="hlegend"><span><i style="background:var(--accent)"></i>ms per member</span><span><i style="background:var(--warn)"></i>slow (over 66 ms)</span></div>
                    </div>
                  {/if}
                </div>
              {/if}
            </div>
          {:else}<div class="empty"><b>Nothing matches</b>Try another filter.</div>{/each}
        {:else if zview === "bases"}
          {#each zdata.bases.filter((b) => !zq || norm(b.base).includes(norm(zq))) as b, bi (bi)}
            <div class="row"><div class="row-h" style="cursor:default;grid-template-columns:minmax(0,1fr) auto auto 18px">
              <span class="e">{@html hl(b.base)}</span><span class="t">{fmtN(b.queries)}<br /><small class="muted">queries</small></span><span class="t"><b>{fmtUs(b.us)}</b><br /><small class="muted">avg {fmtUs(b.us / b.queries)}</small></span><span></span>
            </div></div>
          {:else}<div class="empty"><b>Nothing matches</b>Try another filter.</div>{/each}
        {:else}
          {#each (zview === "slowest" ? zdata.slowest : zdata.recent).filter(keep) as x, xi (xi)}
            <div class="row"><div class="row-h" style="cursor:default">
              <span class="e">{@html hl(x.base)}</span><span class="e">{@html hl(x.member)}</span><span class="badge {RES[x.result]?.[1]}">{RES[x.result]?.[0] ?? x.result}</span>
              <span class="t">{x.n}<br /><small class="muted">members</small></span><span class="t"><b>{fmtUs(x.us)}</b></span><span></span>
            </div></div>
          {:else}<div class="empty"><b>Nothing matches</b>Try another filter.</div>{/each}
        {/if}
      </div>
    {/if}
  </div>
</section>
