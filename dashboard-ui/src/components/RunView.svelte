<script>
  import { untrack } from "svelte";
  import Icon from "./Icon.svelte";
  import Num from "./Num.svelte";
  import Chart from "./Chart.svelte";
  import { live, ui, isLive, serverNow, showView } from "../lib/state.svelte.js";
  import { fmtN, fmtSI, fmtB, fmtDur, hl, tipRows } from "../lib/util.js";

  let { themeTick } = $props();

  const PHASES = [["enumerate", "Enumerate", "list"], ["recompute", "Fingerprint", "code"], ["verify", "Verify", "cpu"], ["saving", "Save", "db"]];
  const RING = 540.35;
  const exact = (v) => fmtN(Math.round(v));

  const S = $derived(live.S);
  const running = $derived(isLive());
  const p = $derived(S?.progress);
  const d = $derived(S?.db || {});
  const m = $derived(S?.meta || {});
  const verifying = $derived(p?.kind === "verify");
  const frac = $derived(verifying && p.total ? p.done / p.total : null);
  const finished = $derived(S?.status === "exited" && S?.phase === "finished");

  const levelChips = $derived.by(() => {
    if (!S) return [];
    const target = running || m.target ? m.target || S.level : null;
    const doneRun = new Set((S.levels || []).map((l) => l.level));
    const top = Math.max(target || 0, d.max_cost || 0, S.level || 0);
    const out = [];
    for (let c = 1; c <= top; c++) {
      const active = running && c === S.level;
      out.push({ c, active, done: !active && (doneRun.has(c) || c <= (d.max_cost || 0)) });
    }
    return out;
  });
  const phaseIdx = $derived(PHASES.findIndex(([k]) => k === S?.phase));

  const ring = $derived.by(() => {
    if (verifying) return { frac: frac || 0, big: (frac * 100).toFixed(frac < 0.1 ? 1 : 0), unit: "%", lbl: running ? `verifying cost ${S.level}` : S.phase === "stopped" ? "stopped" : "verified", indet: false };
    if (p?.kind === "enumerate") return { frac: 0, big: fmtSI(p.processed), unit: "", lbl: running ? "expressions built" : "built", indet: running && S.status !== "paused" };
    if (running) return { frac: 0, big: "…", unit: "", lbl: S.phase === "loading" ? "loading db" : "starting", indet: false };
    return { frac: d.exists ? 1 : 0, big: d.exists ? String(d.max_cost || 0) : "–", unit: "", lbl: d.exists ? "verified cost" : "no database", indet: false };
  });
  const ringTip = $derived(verifying ? tipRows(`Cost ${S.level} verification`, [["verified", fmtN(p.done)], ["of", fmtN(p.total)], ["progress", ((frac || 0) * 100).toFixed(3) + "%"]])
    : p?.kind === "enumerate" ? tipRows(`Cost ${S.level} enumeration`, [["built", fmtN(p.processed)], ["unique", fmtN(p.unique)]]) : undefined);

  // headline stats: [label, value, format, sub, tooltip]
  const stats = $derived.by(() => {
    if (verifying) {
      const eta = p.rate > 0 ? (p.total - p.done) / p.rate : null, etaAll = (p.rate_overall || 0) > 0 ? (p.total - p.done) / p.rate_overall : null;
      const pct = p.total ? (p.done / p.total) * 100 : 0;
      const solver = Math.max(0, p.done - p.normal_form - p.rewriting - (p.absint || 0));
      const elapsedAll = running ? serverNow() - (m.started || serverNow()) : p.elapsed;
      return [
        ["Verified", p.done, exact, `of ${fmtN(p.total)} · ${pct.toFixed(2)}%`, tipRows("Verification", [["verified", fmtN(p.done)], ["remaining", fmtN(p.total - p.done)], ["total", fmtN(p.total)], ["done", pct.toFixed(3) + "%"], ["by normal form", fmtN(p.normal_form)], ["by Z3 rewriter", fmtN(p.rewriting)], ["by Z3 solver", fmtN(solver)]])],
        ["Throughput", p.rate, exact, `per second · ${fmtN(Math.round(p.rate_overall ?? p.rate))} overall`, tipRows("Expressions per second", [["last 30 s", fmtN(Math.round(p.rate))], ["whole phase", fmtN(Math.round(p.rate_overall ?? p.rate))], ["Z3 queries", fmtN(p.queries)], ["queries / s", p.elapsed ? (p.queries / p.elapsed).toFixed(1) : "–"]])],
        [running ? "Time left" : "Verify time", running ? eta : p.elapsed, fmtDur, running ? `${fmtDur(etaAll)} at the overall rate` : "", running ? tipRows("Estimated time left", [["at the 30 s rate", fmtDur(eta)], ["at the overall rate", fmtDur(etaAll)], ["finishes around", eta ? new Date(Date.now() + eta * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "–"]]) : undefined],
        ["Elapsed", elapsedAll, fmtDur, `${fmtN(p.tasks_done)} / ${fmtN(p.tasks)} tasks`, tipRows("Time", [["whole run", fmtDur(elapsedAll)], ["verifying", fmtDur(p.elapsed)], ["tasks done", `${fmtN(p.tasks_done)} of ${fmtN(p.tasks)}`], ["tasks done", (p.tasks ? (p.tasks_done / p.tasks) * 100 : 0).toFixed(2) + "%"]])],
      ];
    }
    if (p?.kind === "enumerate") return [
      ["Built", p.processed, exact, "expressions"],
      ["Unique classes", p.unique, exact, `${p.processed ? ((p.unique / p.processed) * 100).toFixed(1) : 0}% of built`],
      ["Throughput", p.rate, fmtSI, `per second · ${fmtSI(p.rate_overall ?? p.rate)} overall`],
      ["Elapsed", p.elapsed, fmtDur, ""],
    ];
    return [
      ["Classes", d.classes, exact, d.exists ? "in scone.db" : ""],
      ["Expressions", d.expressions, exact, ""],
      ["Counterexamples", d.ces, exact, ""],
      ["Unverified", d.unverified, exact, d.unverified ? "timed out in Z3" : ""],
    ];
  });

  const heroNote = $derived(!S ? "" : !running && verifying && S.phase !== "level done" ? `This run ended part-way through cost ${S.level}; unfinished levels are not saved, so the next run redoes it.`
    : !running && !p ? (d.exists && d.max_cost ? `Next level is cost ${d.max_cost + 1}. Open New run to start it.` : "Open New run to start.") : "");

  // verification flow
  const flow = $derived.by(() => {
    if (!(verifying && p.normal_form != null)) return null;
    const settled = p.normal_form + p.rewriting + (p.absint || 0);
    const rows = [["Normal form", p.normal_form, "var(--accent)", "algebraic rewrite, no solver"], ["Z3 rewriter", p.rewriting, "var(--tok-fn)", "simplify only"], ["Z3 solver", Math.max(0, p.done - settled), "var(--warn)", `${fmtN(p.queries)} queries`]];
    if (p.absint) rows.unshift(["Abstract interp.", p.absint, "var(--good)", "range facts"]);
    return { rows, max: Math.max(1, p.done) };
  });

  // stat tiles
  const kpis = $derived.by(() => {
    const base = m.db_at_start || null, pr = S?.proc;
    const delta = (k) => (base && d[k] != null && base[k] != null && d[k] - base[k] > 0 ? "+" + fmtN(d[k] - base[k]) + " this run" : "");
    const tip = (k, v, f, b0) => tipRows(k, [["now", v == null ? "–" : f(v)], ...(b0 != null && v != null ? [["at run start", fmtN(b0)], ["added this run", fmtN(v - b0)]] : [])]);
    return [
      ["db", "Classes", d.classes, fmtN, delta("classes"), false, tip("Classes", d.classes, fmtN, base?.classes)],
      ["list", "Expressions", d.expressions, fmtN, delta("expressions"), false, tip("Expressions", d.expressions, fmtN, base?.expressions)],
      ["alert", "Unverified", d.unverified, fmtN, d.unverified ? "timed out" : "", !!d.unverified, tip("Unverified classes", d.unverified, fmtN)],
      ["check", "Counterexamples", d.ces, fmtN, delta("ces"), false, tip("Counterexamples", d.ces, fmtN, base?.ces)],
      ["db", "Database", d.size, (v) => (v ? fmtB(v) : "–"), "", false, tip("Database size", d.size, (v) => `${fmtB(v)} (${fmtN(v)} bytes)`)],
      ["cpu", "CPU", pr ? pr.cpu : null, (v) => Math.round(v) + "%", pr ? `${pr.procs} process${pr.procs === 1 ? "" : "es"}` : "", false, tip("CPU", pr ? pr.cpu : null, (v) => v.toFixed(1) + "%")],
      ["cpu", "Memory", pr ? pr.rss : null, (v) => (v ? fmtB(v) : "–"), "", false, tip("Memory", pr ? pr.rss : null, (v) => `${fmtB(v)} (${fmtN(v)} bytes)`)],
    ];
  });

  // newest rules
  let ticker = $state(null);
  $effect(() => {
    live.dbKey;
    untrack(() => fetch("/api/recent_rules?n=8")
      .then((r) => r.json()).then((r) => { if (!r.error) ticker = r.rows; }).catch(() => {}));
  });
  function openRule(id) { ui.explore.q = "#" + id; ui.explore.page = 1; showView("explore"); }
</script>

<section class="view">
  <div class="card hero">
    <div class="ring" class:indet={ring.indet} data-tip={ringTip}>
      <svg viewBox="0 0 200 200"><circle class="track" cx="100" cy="100" r="86" stroke-width="14" fill="none" /><circle class="bar" cx="100" cy="100" r="86" stroke-width="14" fill="none" stroke-linecap="round" stroke-dasharray={RING} stroke-dashoffset={ring.indet ? RING * 0.72 : RING * (1 - ring.frac)} /></svg>
      <div class="center"><div class="big num">{ring.big}{#if ring.unit}<small>{ring.unit}</small>{/if}</div><div class="lbl">{ring.lbl}</div></div>
    </div>
    <div style="min-width:0;position:relative;z-index:1">
      <div class="levels-chips">
        {#each levelChips as l (l.c)}
          <span class="lchip" class:active={l.active} class:done={l.done}><i>{#if l.done}<Icon name="check" cls="xs" />{:else}{l.c}{/if}</i>Cost {l.c}</span>
        {:else}<span class="muted">No levels verified yet</span>{/each}
      </div>
      <div class="phases">
        {#each PHASES as [k, n, icon], i (k)}
          {@const cls = running && i === phaseIdx ? "on" : (running && i < phaseIdx) || (!running && finished) ? "ok" : ""}
          <div class="phase {cls}"><span class="pi">{#if cls === "ok"}<Icon name="check" cls="xs" />{:else}<Icon name={icon} cls="sm" />{/if}</span>{n}</div>
        {/each}
      </div>
      <div class="stats">
        {#each stats as [k, v, f, sub, tip], i (i)}
          <div class="stat" data-tip={tip}><div class="k">{k}</div><div class="v num"><Num value={v} format={f} /></div><div class="d">{sub}</div></div>
        {/each}
      </div>
      {#if heroNote}<div class="hero-note">{heroNote}</div>{/if}
    </div>
  </div>

  <div class="grid2">
    <Chart {themeTick} />
    <div class="card">
      <div class="card-h"><h2>Where verification goes</h2><span class="spacer"></span><span class="sub">{flow ? fmtN(p.done) + " settled" : ""}</span></div>
      {#if flow}
        <div class="flow">
          {#each flow.rows as [n, v, c, s] (n)}
            <div class="fl" data-tip={tipRows(n, [["expressions", fmtN(v)], ["share", ((v / flow.max) * 100).toFixed(2) + "%"], ["how", s]])}>
              <span class="n">{n}<small>{s}</small></span>
              <div class="track"><span style="width:{((v / flow.max) * 100).toFixed(2)}%;background:{c}"></span></div>
              <span class="v num"><Num value={v} format={fmtSI} /><small>{Math.round((v / flow.max) * 100)}%</small></span>
            </div>
          {/each}
        </div>
        <div class="outcomes">
          <div class="oc" data-tip={tipRows("Counterexamples", [["meaning", "inputs where members differ"], ["used for", "splitting classes"]])}><b class="num"><Num value={p.ces} format={exact} /></b><span>counterexamples</span></div>
          <div class="oc" data-tip={tipRows("New classes", [["meaning", "classes split off by counterexamples"]])}><b class="num"><Num value={p.splits} format={exact} /></b><span>new classes</span></div>
          <div class="oc" class:bad={!!p.timeouts} data-tip={tipRows("Gave up", [["meaning", "Z3 could not decide"], ["saved as", "unverified classes"]])}><b class="num"><Num value={p.timeouts} format={exact} /></b><span>gave up</span></div>
        </div>
      {:else}
        <div class="empty"><Icon name="chart" /><b>{running ? "Waiting for verification" : "No verification yet"}</b>Shows how each expression was settled once Z3 starts.</div>
      {/if}
    </div>
  </div>

  <div class="kpis">
    {#each kpis as [icon, k, v, f, dd, bad, tip] (k)}
      <div class="kpi" data-tip={tip}><div class="k"><Icon name={icon} cls="sm" />{k}</div><div class="v"><Num value={v} format={(x) => f(Math.round(x))} /></div><div class="d" class:bad>{dd}</div></div>
    {/each}
  </div>

  <div class="card">
    <div class="card-h"><h2>Newest rewrite rules</h2><span class="sub">from scone.db</span><span class="spacer"></span><button class="btn sm ghost" onclick={() => showView("explore")}>Open explorer<Icon name="right" cls="sm" /></button></div>
    <div class="ticker">
      {#if ticker && ticker.length}
        {#each ticker as c, i (i)}
          <button class="tick" onclick={() => openRule(c.id)} data-tip={`Class #${c.id} · cost ${c.cost} → ${c.ccost} · ${c.status}`}>
            <span class="badge">#{c.id}</span><span class="expr">{@html hl(c.expr)}<span class="arrow">→</span>{@html hl(c.canonical)}</span><span class="badge {c.status === 'unverified' ? 'bad' : 'good'}">cost {c.cost} → {c.ccost}</span>
          </button>
        {/each}
      {:else if ticker}
        <div class="empty"><Icon name="db" /><b>No rules yet</b>Proven rewrite rules appear here once a level is saved.</div>
      {/if}
    </div>
  </div>
</section>
