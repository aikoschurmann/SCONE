<script>
  import { untrack } from "svelte";
  import Icon from "./Icon.svelte";
  import { ui, live } from "../lib/state.svelte.js";
  import { fmtN, hl, parseExpr, toC, toSmt } from "../lib/util.js";
  import { copy, toast } from "../lib/ui.svelte.js";

  const E = ui.explore;
  const SIZE = 30;
  const KINDS = [["all", "All classes"], ["rules", "With rewrites"], ["unverified", "Unverified"]];
  const ORDERS = [["desc", "Newest first"], ["asc", "Oldest first"], ["size", "Most rewrites"], ["savings", "Biggest savings"]];

  let result = $state(null), loading = $state(false), error = $state("");
  let facets = $state(null);
  let openId = $state(null), detail = $state(null), memberQ = $state(""), loadingAll = $state(false);
  let qInput = $state(E.q);
  let listEl;
  let req = 0, timer;

  async function load() {
    const my = ++req;
    loading = true;
    const params = { page: E.page, size: SIZE, filter: E.filter, order: E.order, cost: E.cost ?? "" };
    const idm = E.q.trim().match(/^#\s*(\d+)$/);
    if (idm) params.id = idm[1];
    else if (E.q) params.q = E.q;
    const r = await fetch("/api/classes?" + new URLSearchParams(params)).then((r) => r.json()).catch(() => ({ error: "Dashboard server unreachable" }));
    if (my !== req) return;
    loading = false;
    if (r.error) { error = r.error; result = null; if (/indexing/i.test(r.error)) setTimeout(() => my === req && load(), 1500); return; }
    error = "";
    if (r.facets) facets = r.facets;
    result = { ...r, jump: !!params.id };
    if (params.id && r.rows.length === 1 && openId !== r.rows[0].id) toggle(r.rows[0].id);
  }

  // reload when the query, filters, order or page change, and when scone.db gains classes
  $effect(() => { E.q; E.filter; E.order; E.page; E.cost; live.dbKey; untrack(load); });
  // keep the input in sync when something else (the ticker, the palette) sets the query
  $effect(() => { const q = E.q; untrack(() => { if (q !== qInput.trim()) qInput = q; }); });

  function onInput() {
    clearTimeout(timer);
    timer = setTimeout(() => { E.q = qInput.trim(); E.page = 1; }, 300);
  }
  function set(k, v) { E[k] = v; E.page = 1; }
  function clearAll() { qInput = ""; E.q = ""; E.filter = "rules"; E.cost = ""; E.page = 1; }

  async function fetchDetail(id, limit) {
    return fetch(`/api/class?id=${id}&limit=${limit}`).then((r) => r.json()).catch(() => ({ error: "Dashboard server unreachable" }));
  }
  async function toggle(id) {
    if (openId === id) { openId = null; detail = null; return; }
    openId = id; detail = null; memberQ = "";
    const c = await fetchDetail(id, 300);
    if (openId === id) detail = c;
  }
  async function showAll() {
    const id = openId;
    loadingAll = true;
    const c = await fetchDetail(id, 5000);
    loadingAll = false;
    if (openId === id) detail = c;
  }

  const mq = $derived(memberQ.replace(/\s+/g, "").toLowerCase());
  const groups = $derived.by(() => {
    if (!detail || detail.error) return [];
    const g = {};
    for (const m of detail.members) if (!mq || m.expr.replace(/\s+/g, "").toLowerCase().includes(mq)) (g[m.cost] ||= []).push(m);
    return Object.keys(g).sort((a, b) => a - b).map((k) => [k, g[k], detail.by_cost?.[k] ?? g[k].length]);
  });
  const hidden = $derived(detail && !detail.error ? detail.count - 1 - detail.members.length : 0);

  const from = $derived(result ? (result.page - 1) * result.size : 0);
  const lastPage = $derived(!result ? true : result.total != null ? from + result.rows.length >= result.total : !result.more);
  const pages = $derived(result?.total != null ? Math.max(1, Math.ceil(result.total / SIZE)) : null);
  const filtered = $derived(!!(E.q || E.filter !== "rules" || E.cost));
  const info = $derived.by(() => {
    if (!result) return "";
    if (result.jump) return result.rows.length ? "" : "No class with that id";
    if (result.searched) return result.complete ? `${fmtN(result.total)} matches` : `${fmtN(result.rows.length ? from + result.rows.length : 0)}+ matches · searched ${fmtN(result.scanned)} of ${fmtN(result.classes)} classes`;
    return `${fmtN(result.total)} ${result.total === 1 ? "class" : "classes"}`;
  });
  const indexing = $derived(error.toLowerCase().includes("indexing"));
  const maxSize = $derived(result?.rows?.reduce((m, c) => Math.max(m, c.size - 1), 1) || 1);

  // arrow keys move between rows, Enter / Space expands
  function rowKey(e, id) {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(id); return; }
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp" && e.key !== "j" && e.key !== "k") return;
    e.preventDefault();
    const rows = [...listEl.querySelectorAll(".xr-h")];
    const i = rows.indexOf(e.currentTarget) + (e.key === "ArrowDown" || e.key === "j" ? 1 : -1);
    rows[Math.max(0, Math.min(rows.length - 1, i))]?.focus();
  }

  function copyAs(kind) {
    const c = detail;
    try {
      if (kind === "all") copy(c.members.map((m) => `${m.expr} => ${c.canonical}`).join("\n"), `${c.members.length} rules`);
      else if (kind === "c") copy(toC(parseExpr(c.canonical)), "C expression");
      else copy(`(assert (= ${toSmt(parseExpr(c.members[0]?.expr ?? c.canonical))} ${toSmt(parseExpr(c.canonical))}))`, "SMT-LIB");
    } catch (e) { toast("Could not convert", true); }
  }
</script>

<section class="view">
  {#if facets}
    <div class="xstats">
      <button class="xstat" class:on={E.filter === "all" && !E.cost} onclick={() => { set("filter", "all"); set("cost", ""); }} data-tip="Every equivalence class in scone.db">
        <span class="k">Classes</span><span class="v">{fmtN(facets.classes)}</span><span class="s">canonical cost {Object.keys(facets.costs)[0] ?? 0}–{Object.keys(facets.costs).at(-1) ?? 0}</span>
      </button>
      <button class="xstat" class:on={E.filter === "rules"} onclick={() => set("filter", "rules")} data-tip="Classes with at least one expression that rewrites to the canonical form">
        <span class="k">With rewrites</span><span class="v">{fmtN(facets.with_rules)}</span><span class="s">{((facets.with_rules / Math.max(1, facets.classes)) * 100).toFixed(1)}% of classes</span>
      </button>
      <div class="xstat static" data-tip="Non-canonical expressions: each one is a proven rewrite to its class's canonical form">
        <span class="k">Rewrite rules</span><span class="v">{fmtN(facets.rules)}</span><span class="s">{(facets.rules / Math.max(1, facets.with_rules)).toFixed(1)} per class with rewrites</span>
      </div>
      <button class="xstat" class:on={E.filter === "unverified"} class:bad={facets.unverified > 0} onclick={() => set("filter", "unverified")} data-tip="Classes whose equivalence Z3 could not prove in time">
        <span class="k">Unverified</span><span class="v">{fmtN(facets.unverified)}</span><span class="s">{facets.unverified ? "Z3 gave up on these" : "every class is proven"}</span>
      </button>
    </div>
  {/if}

  <div class="card">
    <div class="toolbar">
      <div class="search"><Icon name="search" cls="sm" /><input id="eQ" placeholder="Search expressions, e.g. x << 1, or #1234 to open a class   ( / )" bind:value={qInput} oninput={onInput} spellcheck="false" autocomplete="off" />
        {#if qInput}<button class="clear" aria-label="Clear search" onclick={() => { qInput = ""; E.q = ""; E.page = 1; }}><Icon name="x" cls="sm" /></button>{/if}
      </div>
      <select class="sel" value={E.order} onchange={(e) => set("order", e.currentTarget.value)} aria-label="Sort">
        {#each ORDERS as [v, l] (v)}<option value={v}>{l}</option>{/each}
      </select>
    </div>
    <div class="toolbar xfilters">
      <div class="seg" role="group" aria-label="Classes">
        {#each KINDS as [v, l] (v)}<button aria-pressed={E.filter === v} onclick={() => set("filter", v)}>{l}</button>{/each}
      </div>
      {#if facets}
        <div class="xcost">
          <span class="lbl">Canonical cost</span>
          <div class="seg" role="group" aria-label="Canonical cost">
            <button aria-pressed={!E.cost} onclick={() => set("cost", "")}>Any</button>
            {#each Object.entries(facets.costs) as [k, n] (k)}
              <button aria-pressed={E.cost === k} onclick={() => set("cost", k)} data-tip={`${fmtN(n)} classes whose canonical form costs ${k}${k === "0" ? " (a constant or a variable)" : ""}`}>{k}</button>
            {/each}
          </div>
        </div>
      {/if}
      <span class="spacer"></span>
      <span class="xinfo">{#if loading}<span class="spin"></span>{/if}{info}</span>
      {#if filtered}<button class="link" onclick={clearAll}>Clear filters</button>{/if}
    </div>

    <div class="xhead" aria-hidden="true"><span>Class</span><span>Cheapest rewrite → canonical form</span><span class="r">Rewrites</span><span class="r">Cost</span><span></span></div>
    <div class="xlist" bind:this={listEl} style:opacity={loading && result ? 0.6 : 1}>
      {#if error}
        <div class="empty"><Icon name={indexing ? "db" : "alert"} /><b>{indexing ? "Indexing scone.db" : "Could not load classes"}</b>{error}</div>
      {:else if !result}
        {#each Array(8) as _, i (i)}<div class="skel"></div>{/each}
      {:else}
        {#each result.rows as c (c.id)}
          <div class="xr" class:open={openId === c.id}>
            <div class="xr-h" onclick={() => toggle(c.id)} role="button" tabindex="0" aria-expanded={openId === c.id} onkeydown={(e) => rowKey(e, c.id)}>
              <span class="cid">#{c.id}</span>
              <span class="e">
                {#if c.best}<span class="from">{@html hl(c.best)}</span><Icon name="right" cls="sm arr" /><span class="to">{@html hl(c.canonical)}</span>
                {:else}<span class="to">{@html hl(c.canonical)}</span><span class="none">no rewrites</span>{/if}
                {#if c.status === "unverified"}<span class="badge bad">unverified</span>{/if}
              </span>
              <span class="xn" data-tip={c.size > 1 ? `${fmtN(c.size - 1)} expressions rewrite to this form` : "Only the canonical form"}>
                {#if c.size > 1 && maxSize > 1}<span class="bar"><i style:width={Math.max(4, (Math.log(c.size) / Math.log(maxSize + 1)) * 100) + "%"}></i></span>{/if}
                <span class="num">{c.size > 1 ? fmtN(c.size - 1) : "–"}</span>
              </span>
              <span class="xc" data-tip={c.best ? `Rewrites cost ${c.best_cost}–${c.max_cost}; canonical costs ${c.cost}` : `Canonical costs ${c.cost}`}>
                {#if c.best && c.max_cost > c.cost}<span class="muted">{c.max_cost}</span><Icon name="right" cls="sm arr" />{/if}<b>{c.cost}</b>
              </span>
              <Icon name="right" cls="sm chev" />
            </div>
            {#if openId === c.id}
              <div class="xr-b">
                {#if !detail}
                  <div class="skel"></div>
                {:else if detail.error}
                  {detail.error}
                {:else}
                  <div class="xd-h">
                    <div class="xd-canon"><span class="k">Canonical</span><span class="mono">{@html hl(detail.canonical)}</span><span class="badge">cost {detail.cost}</span></div>
                    <span class="spacer"></span>
                    <button class="btn sm" disabled={detail.count < 2} onclick={() => copyAs("all")}><Icon name="copy" cls="sm" />Copy rules</button>
                    <button class="btn sm" onclick={() => copyAs("c")}><Icon name="code" cls="sm" />As C</button>
                    <button class="btn sm" onclick={() => copyAs("smt")}><Icon name="code" cls="sm" />As SMT-LIB</button>
                  </div>
                  {#if detail.count < 2}
                    <div class="muted xd-none">No other expression in this class: this form is new, nothing cheaper or equal rewrites to it yet.</div>
                  {:else}
                    <div class="xd-bar">
                      <span class="muted"><b class="fg">{fmtN(detail.count - 1)}</b> {detail.count === 2 ? "expression rewrites" : "expressions rewrite"} to it</span>
                      {#each Object.entries(detail.by_cost || {}) as [k, n] (k)}<span class="badge" data-tip={`${fmtN(n)} rewrites of cost ${k}`}>cost {k} · {fmtN(n)}</span>{/each}
                      <span class="spacer"></span>
                      {#if detail.count > 8}
                        <div class="search mini"><Icon name="search" cls="sm" /><input placeholder="Filter members" bind:value={memberQ} spellcheck="false" /></div>
                      {/if}
                    </div>
                    <div class="xd-groups">
                      {#each groups as [k, ms, total] (k)}
                        <div class="cgroup">
                          <h4>cost {k} <span>· {mq ? `${fmtN(ms.length)} shown` : fmtN(total)}</span></h4>
                          {#each ms as m (m.id)}
                            <div class="member" data-tip={m.expr.length > 30 ? m.expr : null}>
                              <span>{@html hl(m.expr)}</span>
                              <span class="acts"><button class="btn sm icon ghost" data-tip="Copy rule" aria-label="Copy rule" onclick={() => copy(`${m.expr} => ${detail.canonical}`, "rule")}><Icon name="copy" cls="sm" /></button></span>
                            </div>
                          {/each}
                        </div>
                      {:else}
                        <div class="muted xd-none">No member matches "{memberQ}"{hidden > 0 ? " among the ones loaded" : ""}.</div>
                      {/each}
                    </div>
                    {#if hidden > 0}
                      <div class="xd-more">
                        <span class="muted">Showing the {fmtN(detail.members.length)} cheapest of {fmtN(detail.count - 1)}</span>
                        <button class="btn sm" disabled={loadingAll} onclick={showAll}>{loadingAll ? "Loading…" : `Show ${detail.count - 1 > 5000 ? "5,000" : "all"}`}</button>
                      </div>
                    {/if}
                  {/if}
                {/if}
              </div>
            {/if}
          </div>
        {:else}
          <div class="empty"><Icon name="search" /><b>No classes found</b>{filtered ? "Nothing matches these filters." : "Run SCONE to fill the database."}{#if filtered}<br /><button class="link" style="margin-top:8px" onclick={clearAll}>Clear filters</button>{/if}</div>
        {/each}
      {/if}
    </div>

    <div class="pager">
      <span class="num">{result && result.rows.length && !result.jump ? `${fmtN(from + 1)}–${fmtN(from + result.rows.length)}${result.total != null ? " of " + fmtN(result.total) : ""}` : ""}</span>
      {#if result && result.page > 2}<button class="link" onclick={() => (E.page = 1)}>First page</button>{/if}
      <button class="btn sm icon" aria-label="Previous page" disabled={!result || result.page <= 1} onclick={() => E.page--}><Icon name="left" cls="sm" /></button>
      {#if pages}<span class="num">page {fmtN(result.page)} of {fmtN(pages)}</span>{/if}
      <button class="btn sm icon" aria-label="Next page" disabled={lastPage} onclick={() => E.page++}><Icon name="right" cls="sm" /></button>
    </div>
  </div>
</section>
