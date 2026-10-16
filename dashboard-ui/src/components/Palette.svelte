<script>
  import Icon from "./Icon.svelte";
  import { live, ui, showView } from "../lib/state.svelte.js";
  import { copy } from "../lib/ui.svelte.js";
  import { cmdLine } from "../lib/settings.svelte.js";

  let { togglePause, stopRun, toggleNotify, cycleTheme, notify } = $props();
  let dlg, input = $state();
  let q = $state(""), sel = $state(0);

  $effect(() => {
    if (ui.palette && dlg && !dlg.open) { q = ""; sel = 0; dlg.showModal(); input?.focus(); }
    else if (!ui.palette && dlg?.open) dlg.close();
  });

  function openRules(query) { ui.explore.q = query; ui.explore.page = 1; showView("explore"); }

  const items = $derived.by(() => {
    const S = live.S, ctl = S && (S.status === "running" || S.status === "paused");
    const running = S && ["running", "paused", "stopping"].includes(S.status);
    const all = [
      ["sliders", running ? "Next run settings" : "New run", "N", () => (ui.drawer = true)],
      ["run", "Go to Run", "1", () => showView("run")], ["cpu", "Go to Z3", "2", () => showView("z3")],
      ["search", "Go to Explore", "3", () => showView("explore")], ["hist", "Go to History", "4", () => showView("history")],
      ...(ctl ? [[S.status === "paused" ? "play" : "pause", S.status === "paused" ? "Resume run" : "Pause run", "P", togglePause], ["stop", "Stop run", "", stopRun]] : []),
      ["copy", "Copy run command", "", () => copy(cmdLine(), "command")], ["auto", "Cycle theme", "", cycleTheme],
      ["bell", notify ? "Turn notifications off" : "Notify me when a run ends", "", toggleNotify],
    ];
    const t = q.trim().toLowerCase();
    const out = all.filter((c) => !t || c[1].toLowerCase().includes(t));
    const idm = t.match(/^#?(\d+)$/);
    if (idm) out.unshift(["search", `Open class #${idm[1]}`, "", () => openRules("#" + idm[1])]);
    else if (t.length > 1) out.push(["search", `Search rules for "${t}"`, "", () => openRules(t)]);
    return out;
  });
  $effect(() => { if (sel > items.length - 1) sel = Math.max(0, items.length - 1); });

  function run(i) { const c = items[i]; if (!c) return; ui.palette = false; c[3](); }
  function key(e) {
    if (e.key === "ArrowDown") { e.preventDefault(); sel = Math.min(items.length - 1, sel + 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); sel = Math.max(0, sel - 1); }
    else if (e.key === "Enter") { e.preventDefault(); run(sel); }
  }
</script>

<dialog id="palette" bind:this={dlg} onclose={() => (ui.palette = false)} onclick={(e) => e.target === dlg && (ui.palette = false)}>
  <input bind:this={input} bind:value={q} oninput={() => (sel = 0)} onkeydown={key} placeholder="Type a command, a view, or #class id" autocomplete="off" />
  <div id="pList" role="listbox">
    {#each items as c, i (c[1])}
      <div class="pi-i" role="option" tabindex="-1" aria-selected={i === sel} onclick={() => run(i)} onkeydown={() => {}} onpointermove={() => (sel = i)}>
        <Icon name={c[0]} /><span>{c[1]}</span>{#if c[2]}<span class="h kbd">{c[2]}</span>{/if}
      </div>
    {:else}
      <div class="empty"><b>No matching commands</b></div>
    {/each}
  </div>
</dialog>
