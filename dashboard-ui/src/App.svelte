<script>
  import Icon from "./components/Icon.svelte";
  import Tooltip from "./components/Tooltip.svelte";
  import Overlays from "./components/Overlays.svelte";
  import Drawer from "./components/Drawer.svelte";
  import Palette from "./components/Palette.svelte";
  import RunView from "./components/RunView.svelte";
  import Z3View from "./components/Z3View.svelte";
  import ExploreView from "./components/ExploreView.svelte";
  import HistoryView from "./components/HistoryView.svelte";
  import { live, ui, isLive, serverNow, showView } from "./lib/state.svelte.js";
  import { ask, post, toast } from "./lib/ui.svelte.js";
  import { fmtDur, fmtSI, css, load, store } from "./lib/util.js";

  const TITLES = { run: "Run", z3: "Z3", explore: "Explore", history: "History" };
  const NAV = [["run", "Run", "run"], ["z3", "Z3", "cpu"], ["explore", "Explore", "search"], ["history", "History", "hist"]];

  const S = $derived(live.S);
  const running = $derived(isLive());
  const p = $derived(S?.progress);
  const frac = $derived(p && p.kind === "verify" && p.total ? p.done / p.total : null);
  const st = $derived(!live.online ? "offline" : !S ? "idle" : S.status === "exited" ? (S.phase === "failed" ? "failed" : S.phase === "finished" ? "finished" : "exited") : S.status);
  const statusText = $derived({ offline: "Disconnected", idle: S ? "Idle" : "Connecting", running: "Running", paused: "Paused", stopping: "Stopping",
    failed: `Failed${S?.exit_code != null ? " · exit " + S.exit_code : ""}`, finished: "Finished", exited: S?.phase === "stopped" ? "Stopped" : "Exited" }[st]);
  const stuck = $derived(!!S?.z3now?.workers?.some((w) => w && w.age_ms > 120000));
  const canControl = $derived(S && (S.status === "running" || S.status === "paused"));

  // theme
  const THEMES = ["auto", "dark", "light"], THEME_ICON = { auto: "auto", light: "sun", dark: "moon" };
  let theme = $state(load("scone.theme") || "auto");
  $effect(() => {
    if (theme === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = theme;
    store("scone.theme", theme);
  });
  // Changes whenever the effective colours change (theme switch, or the OS scheme under "auto"):
  // canvas drawings read CSS colours and must redraw then.
  let scheme = $state(0);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => scheme++);
  const themeTick = $derived(`${theme}|${scheme}`);

  // notifications
  let notify = $state(load("scone.notify") === "1" && "Notification" in window && Notification.permission === "granted");
  async function toggleNotify() {
    if (!("Notification" in window)) return toast("Notifications are not supported here", true);
    if (!notify && Notification.permission !== "granted" && (await Notification.requestPermission()) !== "granted") return toast("Notification permission denied", true);
    notify = !notify;
    store("scone.notify", notify ? "1" : "0");
    toast(notify ? "You will be notified when a run ends" : "Notifications off");
  }

  // run end: toast + notification
  let prevSt = null;
  $effect(() => {
    const now = st;
    if (prevSt && ["running", "paused", "stopping"].includes(prevSt) && ["finished", "failed", "exited"].includes(now)) {
      const d = S.db || {};
      const reached = Math.max(d.max_cost || 0, ...(S.levels || []).map((l) => l.level));
      const msg = now === "finished" ? `Finished: verified up to cost ${reached || "?"}` : now === "failed" ? `Run failed${S.exit_code != null ? " (exit " + S.exit_code + ")" : ""}` : "Run stopped";
      toast(msg, now === "failed");
      if (notify && document.hidden) try { new Notification("SCONE", { body: msg }); } catch (e) {}
    }
    prevSt = now;
  });

  // title + favicon ring
  $effect(() => {
    const pct = frac != null ? Math.floor(frac * 100) : null;
    document.title = running ? `${S.status === "paused" ? "Paused · " : ""}${pct != null ? pct + "% · " : ""}cost ${S.level ?? "…"} · SCONE` : `${st === "failed" ? "Failed · " : st === "finished" ? "Done · " : ""}SCONE`;
  });
  let favKey = "";
  $effect(() => {
    const pct = frac != null ? Math.floor(frac * 100) : null;
    const key = `${st}|${pct}|${themeTick}`;
    if (key === favKey) return;
    favKey = key;
    const c = document.createElement("canvas"); c.width = c.height = 32;
    const g = c.getContext("2d");
    const col = { running: css("--accent"), paused: css("--warn"), stopping: css("--warn"), failed: css("--bad"), finished: css("--good") }[st] || "#6f7888";
    g.lineWidth = 5; g.strokeStyle = "rgba(128,128,128,.35)"; g.beginPath(); g.arc(16, 16, 12, 0, 7); g.stroke();
    g.strokeStyle = col; g.beginPath(); g.arc(16, 16, 12, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * (pct != null ? pct / 100 : st === "running" ? 0.25 : 1)); g.stroke();
    document.getElementById("favicon").href = c.toDataURL();
  });

  async function stopRun() {
    const lvl = S.level ? `cost ${S.level}` : "the current level";
    if (await ask("Stop the run?", `Progress on ${lvl} is discarded; finished levels stay saved.${S.queued ? " The queued run is cancelled too." : ""} Use Pause to keep everything.`, "Stop run", true)) post("stop");
  }
  const togglePause = () => post(S?.status === "paused" ? "resume" : "pause");

  function onKey(e) {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); ui.palette = !ui.palette; return; }
    if (e.key === "Escape" && ui.drawer) { ui.drawer = false; return; }
    if (e.target.closest("input, select, textarea, dialog") || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "/") {
      e.preventDefault();
      if (ui.view === "explore") document.getElementById("eQ")?.focus();
      else if (ui.view === "z3") document.getElementById("zQ")?.focus();
      else { showView("history"); setTimeout(() => document.getElementById("logQ")?.focus(), 0); }
    } else if (e.key === "n" || e.key === "N") ui.drawer = true;
    else if ((e.key === "p" || e.key === "P") && canControl) togglePause();
    else if (e.key >= "1" && e.key <= "4") showView(["run", "z3", "explore", "history"][+e.key - 1]);
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="app">
  <nav class="rail" aria-label="Views">
    <div class="logo" title="SCONE superoptimizer"><Icon name="logo" /></div>
    {#each NAV as [v, label, icon] (v)}
      <button class="nav" aria-current={ui.view === v ? "page" : undefined} onclick={() => showView(v)}>
        <Icon name={icon} />{label}
        {#if v === "z3" && stuck}<span class="dotb"></span>{/if}
      </button>
    {/each}
    <div class="grow"></div>
    <button class="tool" title="Command palette (Cmd K)" onclick={() => (ui.palette = true)}><Icon name="cmd" /></button>
    <button class="tool" title="Notify me when a run ends" aria-pressed={notify} onclick={toggleNotify}><Icon name={notify ? "bell" : "bell-off"} /></button>
    <button class="tool" title="Theme: {theme}" onclick={() => (theme = THEMES[(THEMES.indexOf(theme) + 1) % 3])}><Icon name={THEME_ICON[theme]} /></button>
  </nav>

  <div class="main">
    <header class="top">
      <h1>{TITLES[ui.view]}</h1>
      <span class="sep"></span>
      <span class="pill" data-s={st}><span class="dot"></span><span>{statusText}</span></span>
      <span class="runinfo" title={S?.meta?.pid ? `pid ${S.meta.pid}` : ""}>
        {#if running && S.level}<span><b>Cost {S.level}</b></span>{/if}
        {#if running && frac != null}<span>Verify <b>{(frac * 100).toFixed(frac < 0.1 ? 1 : 0)}%</b></span>
        {:else if running && p?.kind === "enumerate"}<span>Enumerate <b>{fmtSI(p.processed)}</b></span>{/if}
        {#if S?.meta?.started}<span>{running ? "" : "ran "}{fmtDur((running ? serverNow() : S.ended || serverNow()) - S.meta.started)}</span>{/if}
      </span>
      <span class="spacer"></span>
      {#if canControl}
        <div style="display:flex;gap:8px">
          <button class="btn" class:primary={S.status === "paused"} onclick={togglePause}>
            <Icon name={S.status === "paused" ? "play" : "pause"} cls="sm" />{S.status === "paused" ? "Resume" : "Pause"}
          </button>
          <button class="btn danger" onclick={stopRun}><Icon name="stop" cls="sm" />Stop</button>
        </div>
      {/if}
      <button class="btn primary" onclick={() => (ui.drawer = true)}><Icon name="sliders" cls="sm" />{running ? "Next run" : "New run"}</button>
      {#if running}
        <div class="top-prog" class:indet={frac == null && S.status !== "paused"}><span style="width:{frac != null ? (frac * 100).toFixed(2) : 0}%"></span></div>
      {/if}
    </header>

    <div class="content">
      <div class="banners">
        {#if S?.external_pid}<div class="banner crit"><Icon name="alert" /><b>External run</b><span>scone (pid {S.external_pid}) was started outside the dashboard; Start is disabled until it exits.</span></div>{/if}
        {#if S?.last_error}<div class="banner crit"><Icon name="alert" /><b>Engine error</b><span class="mono">{S.last_error}</span></div>{/if}
        {#if !live.online && S}<div class="banner"><Icon name="plug" /><b>Disconnected</b><span>Lost contact with the dashboard server, retrying. A running engine is unaffected.</span></div>{/if}
      </div>

      {#if ui.view === "run"}<RunView {themeTick} />
      {:else if ui.view === "z3"}<Z3View />
      {:else if ui.view === "explore"}<ExploreView />
      {:else}<HistoryView />{/if}
    </div>
  </div>
</div>

<Drawer />
<Palette {togglePause} {stopRun} {toggleNotify} cycleTheme={() => (theme = THEMES[(THEMES.indexOf(theme) + 1) % 3])} {notify} />
<Overlays />
<Tooltip />
