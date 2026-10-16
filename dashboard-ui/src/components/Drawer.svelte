<script>
  import Icon from "./Icon.svelte";
  import { live, ui, isLive, showView } from "../lib/state.svelte.js";
  import { ask, post, toast, copy } from "../lib/ui.svelte.js";
  import { cfg, isDefault, resetCfg, toApi, cmdLine, plan } from "../lib/settings.svelte.js";
  import { fmtN } from "../lib/util.js";

  const S = $derived(live.S);
  const running = $derived(isLive());
  const P = $derived(plan());
  const m = $derived(S?.meta || {});
  let costInput = $state();

  let advOps = $state(!!(cfg.binops || cfg.unops || cfg.consts));
  let advVerify = $state(!!(cfg.z3_timeout || cfg.audit_normalize || cfg.distill_ces));
  let advDanger = $state(cfg.clean);
  $effect(() => { if (cfg.clean) advDanger = true; });
  

  const summary = $derived.by(() => {
    if (!running) return [];
    const args = m.args || [];
    const v = (f) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : null; }, has = (f) => args.includes(f);
    const rows = [["Max cost", v("-c") ?? m.target ?? "–"], ["Threads", v("-t") ?? "all cores"],
      ["Search space", [has("--lite") ? "lite" : "full", !has("--no-select") && "select", !has("--no-unary") && "unary"].filter(Boolean).join(" · ")],
      ["Z3 timeout", v("--z3-timeout") ? v("--z3-timeout") + " ms" : "1000 ms"], ["Z3 query log", m.z3_log ? "on" : "off"]];
    for (const [f, n] of [["--binops", "Binary ops"], ["--unops", "Unary ops"], ["--consts", "Constants"]]) if (v(f)) rows.push([n, v(f)]);
    return rows;
  });

  const step = (d) => (cfg.cost = String(Math.min(12, Math.max(1, (+cfg.cost || 3) + d))));
  const close = () => (ui.drawer = false);

  async function start() {
    if (cfg.clean && !(await ask("Wipe scone.db?", `All ${fmtN(S.db.classes || 0)} proven classes will be deleted ${running ? "when the current run ends" : "before the run starts"}. This cannot be undone.`, running ? "Queue wipe" : "Wipe and start", true))) return;
    if (!running) { if (await post("start", toApi())) { toast("Run started"); close(); showView("run"); } return; }
    if (await post("queue", toApi())) toast(S.queued ? "Queued run updated" : "Queued: starts when this run finishes");
  }
  async function restart() {
    const lvl = S.level ? `cost ${S.level}` : "the current level";
    if (!(await ask("Restart with these settings?", `The current run stops and its progress on ${lvl} is discarded. Finished levels stay saved.`, "Restart", true))) return;
    if (await post("restart", toApi())) { toast("Restarting"); close(); }
  }
  async function unqueue() { if (await post("unqueue")) toast("Queued run cancelled"); }
</script>

<div class="scrim" class:on={ui.drawer} onclick={close} role="presentation"></div>
<aside class="drawer" class:on={ui.drawer} aria-label="Run settings">
  <div class="drawer-h">
    <div class="dh-t">
      <h2>{running ? "Next run" : "New run"}</h2>
      <span class="sub">{running ? "Queue it after the current run, or restart with it now" : "Choose what to search and how to verify it"}</span>
    </div>
    <span class="spacer"></span>
    {#if !isDefault()}<button class="link" onclick={() => { resetCfg(); advOps = advVerify = advDanger = false; toast("Settings reset"); }}>Reset</button>{/if}
    <button class="btn sm icon ghost" aria-label="Close" onclick={close}><Icon name="x" cls="sm" /></button>
  </div>

  <div class="drawer-b">
    {#if running}
      <div class="cur-run" data-tip={summary.map(([k, v]) => `${k}: ${v}`).join("\n")}>
        <span class="dot"></span><span class="lbl">Running now</span>
        {#each summary.slice(0, 4) as [k, v] (k)}<span class="chip-s">{k === "Max cost" ? "cost " + v : k === "Z3 timeout" ? v : v}</span>{/each}
      </div>
    {/if}

    <section class="ds">
      <div class="ds-h"><span>Max cost</span><span class="hint">largest expression size to prove</span></div>
      <div class="seg cost-seg" role="group" aria-label="Max cost">
        {#each [1, 2, 3, 4, 5, 6, 7, 8] as c (c)}
          <button type="button" aria-pressed={+cfg.cost === c} onclick={() => (cfg.cost = String(c))}>{c}</button>
        {/each}
      </div>
      <div class="plan-l {P.cls}">
        <Icon name={P.cls ? "alert" : "info"} cls="sm" />
        <span>{P.msg}{#if P.fix}{" "}<button class="link" onclick={() => (cfg.cost = String(P.fix))}>Use cost {P.fix}</button>{/if}</span>
      </div>
    </section>

    <section class="ds">
      <div class="ds-h"><span>Threads</span></div>
      <div class="thr">
        <div class="seg" role="group" aria-label="Threads">
          <button type="button" aria-pressed={cfg.threads === ""} onclick={() => (cfg.threads = "")}>All cores</button>
          <button type="button" aria-pressed={cfg.threads !== ""} onclick={() => { if (cfg.threads === "") cfg.threads = "8"; }}>Custom</button>
        </div>
        {#if cfg.threads !== ""}
          <div class="stepper sm">
            <button type="button" aria-label="Fewer threads" onclick={() => (cfg.threads = String(Math.max(1, (+cfg.threads || 1) - 1)))}><Icon name="minus" cls="sm" /></button>
            <input type="number" min="1" bind:value={cfg.threads} bind:this={costInput} aria-label="Threads" />
            <button type="button" aria-label="More threads" onclick={() => (cfg.threads = String((+cfg.threads || 0) + 1))}><Icon name="plus" cls="sm" /></button>
          </div>
        {/if}
      </div>
    </section>

    <section class="ds">
      <div class="ds-h"><span>Search space</span></div>
      <div class="glist">
        <label class="t"><span>Lite<small>7 cheap binops, constants 0, 1, ~0</small></span><input class="sw" type="checkbox" bind:checked={cfg.lite} /></label>
        <label class="t"><span>Select<small>ternary c ? a : b</small></span><input class="sw" type="checkbox" bind:checked={cfg.select} /></label>
        <label class="t"><span>Unary ops<small>neg, not, clz, ctz, popcount</small></span><input class="sw" type="checkbox" bind:checked={cfg.unary} /></label>
      </div>
      <details class="adv" bind:open={advOps}><summary><Icon name="right" cls="sm" />Restrict operators and constants</summary><div>
        <label class="f">Binary ops<input type="text" placeholder="all, e.g. add,xor,shl" spellcheck="false" bind:value={cfg.binops} /></label>
        <label class="f">Unary ops<input type="text" placeholder="all, e.g. not,neg" spellcheck="false" bind:value={cfg.unops} /></label>
        <label class="f">Constants<input type="text" placeholder="all, e.g. 0,1,0xFFFFFFFF" spellcheck="false" bind:value={cfg.consts} /></label>
      </div></details>
    </section>

    <section class="ds">
      <div class="ds-h"><span>Verification</span></div>
      <div class="glist">
        <label class="t"><span>Abstract interpretation<small>settle easy members before Z3</small></span><input class="sw" type="checkbox" bind:checked={cfg.absint} /></label>
        <label class="t"><span>Log Z3 queries<small>feeds the query log in the Z3 view</small></span><input class="sw" type="checkbox" bind:checked={cfg.z3_log} /></label>
      </div>
      <details class="adv" bind:open={advVerify}><summary><Icon name="right" cls="sm" />Advanced</summary><div>
        <div class="fields">
          <label class="f">Z3 timeout (ms)<input type="number" min="1" placeholder="1000" bind:value={cfg.z3_timeout} /></label>
          <label class="f">Audit every N<input type="number" min="0" placeholder="off" bind:value={cfg.audit_normalize} /></label>
        </div>
        <div class="glist"><label class="t"><span>Distill counterexamples<small>compress the sample grid when done</small></span><input class="sw" type="checkbox" bind:checked={cfg.distill_ces} /></label></div>
      </div></details>
    </section>

    <details class="adv danger" bind:open={advDanger}><summary><Icon name="right" cls="sm" />Danger zone</summary><div>
      <div class="glist bad"><label class="t"><span>Wipe scone.db first<small>deletes every proven class before the run</small></span><input class="sw danger" type="checkbox" bind:checked={cfg.clean} /></label></div>
    </div></details>
  </div>

  <div class="drawer-f">
    {#if S?.queued}
      <div class="queued">
        <Icon name="clock" cls="sm" />
        <div class="q-b"><b>{S.queued.restart ? "Restarting with" : "Queued after this run"}</b><code>{S.queued.args.join(" ")}</code></div>
        <button class="link" onclick={unqueue}>Cancel</button>
      </div>
    {/if}
    <div class="cmd"><code>{cmdLine()}</code><button class="btn sm icon ghost" aria-label="Copy command" data-tip="Copy command" onclick={() => copy(cmdLine(), "command")}><Icon name="copy" cls="sm" /></button></div>
    <div class="acts2" class:one={!running}>
      <button class="btn {cfg.clean ? 'danger solid' : 'primary'}" disabled={P.blocked || P.nothing} data-tip={P.nothing ? "Nothing new to prove at this cost" : running ? "Start these settings when the current run finishes" : null} onclick={start}>
        <Icon name={running ? "clock" : "play"} cls="sm" />{running ? (S.queued ? "Update queue" : "Queue next") : cfg.clean ? "Wipe and start" : "Start run"}
      </button>
      {#if running}<button class="btn" disabled={P.restartBlocked} data-tip={P.restartBlocked ? "scone.db already reaches this cost" : "Stop the current run and start this one"} onclick={restart}><Icon name="restart" cls="sm" />Restart now</button>{/if}
    </div>
  </div>
</aside>
