<script>
  import { untrack } from "svelte";
  import Icon from "./Icon.svelte";
  import { live, onLog, logLines } from "../lib/state.svelte.js";
  import { fmtN, fmtDur } from "../lib/util.js";
  import { copy } from "../lib/ui.svelte.js";

  const levels = $derived(live.S?.levels || []);
  const sec = (x) => (x == null ? "–" : x < 1 ? (x * 1000).toFixed(0) + " ms" : fmtDur(x));

  // The log is appended to the DOM directly: thousands of lines, only ever added at the end.
  let logEl;
  let lines = $state(0), warnings = $state(0);
  let onlyWarn = $state(false), query = $state("");
  const MAX = 2000;

  function classify(l) {
    if (/\[BUG\]|error|panic|Failed/i.test(l)) return "e";
    if (/\[WARNING\]|Caught SIGINT|timed out/.test(l)) return "w";
    if (/^\s*SCONE cost level|^--- COST/.test(l)) return "h";
    if (/^=+$|^-+$/.test(l)) return "dim";
    return "";
  }
  const escHtml = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
  function paint(div, q) {
    const l = div._t || " ";
    if (q) {
      const i = l.toLowerCase().indexOf(q);
      div.hidden = i < 0;
      if (i >= 0) { div.innerHTML = escHtml(l.slice(0, i)) + "<mark>" + escHtml(l.slice(i, i + q.length)) + "</mark>" + escHtml(l.slice(i + q.length)); return; }
    } else div.hidden = false;
    div.textContent = l;
  }
  function append(newLines, reset) {
    if (!logEl) return;
    if (reset) { logEl.textContent = ""; warnings = 0; }
    if (!newLines.length) return;
    const stick = logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 40;
    const frag = document.createDocumentFragment();
    const q = query.toLowerCase();
    for (const l of newLines) {
      const div = document.createElement("div");
      const c = classify(l);
      if (c) div.className = c;
      if (c === "w" || c === "e") warnings++;
      div._t = l;
      paint(div, q);
      frag.appendChild(div);
    }
    logEl.appendChild(frag);
    let extra = logEl.childElementCount - MAX;
    while (extra-- > 0) logEl.firstElementChild.remove();
    lines = logEl.childElementCount;
    if (stick) logEl.scrollTop = logEl.scrollHeight;
  }
  $effect(() => {
    // Runs once on mount; the counters it updates must not become dependencies.
    untrack(() => { append(logLines(), true); logEl.scrollTop = logEl.scrollHeight; });
    return onLog((l, r) => untrack(() => append(l, r)));
  });
  let qt;
  function onQuery() { clearTimeout(qt); qt = setTimeout(() => { const q = query.toLowerCase(); for (const d of logEl.children) paint(d, q); }, 120); }
</script>

<section class="view">
  <div class="card">
    <div class="card-h"><h2>Levels in this run</h2></div>
    <div class="scroll"><table>
      <thead><tr><th>Cost</th><th>Built</th><th>Enumerate</th><th>Fingerprint classes</th><th>Z3 splits</th><th>Total classes</th><th>Verify</th><th>CEs</th><th>Gave up</th></tr></thead>
      <tbody>
        {#each levels as l (l.level)}
          <tr><td><b>{l.level}</b></td><td>{fmtN(l.exprs_built)}</td><td>{sec(l.enum_s)}</td><td>{fmtN(l.fp_classes)}</td><td>{fmtN(l.splits)}</td><td>{fmtN(l.total_classes)}</td><td>{sec(l.verify_s)}</td><td>{fmtN(l.ces)}</td><td style={l.timeouts ? "color:var(--bad)" : ""}>{fmtN(l.timeouts ?? 0)}</td></tr>
        {:else}
          <tr><td colspan="9"><div class="empty"><Icon name="db" /><b>No level finished in this run</b>Each level's summary appears here as soon as it is saved.</div></td></tr>
        {/each}
      </tbody>
    </table></div>
  </div>
  <div class="card">
    <div class="card-h"><h2>Engine log</h2><span class="sub">{fmtN(lines)} lines{warnings ? ` · ${warnings} warnings` : ""}</span></div>
    <div class="toolbar">
      <div class="search"><Icon name="search" cls="sm" /><input id="logQ" placeholder="Filter log  ( / )" bind:value={query} oninput={onQuery} /></div>
      <div class="chips"><button class="chip" aria-pressed={!onlyWarn} onclick={() => (onlyWarn = false)}>All</button><button class="chip" aria-pressed={onlyWarn} onclick={() => (onlyWarn = true)}>Warnings</button></div>
      <button class="btn sm" onclick={() => copy(Array.from(logEl.children, (d) => d._t).join("\n"), "log")}><Icon name="copy" cls="sm" />Copy</button>
    </div>
    <div id="log" class:only-w={onlyWarn} bind:this={logEl}></div>
  </div>
</section>
