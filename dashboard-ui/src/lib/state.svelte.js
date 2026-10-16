// Live state from the dashboard server's event stream, plus app-wide UI state.
import { load, store } from "./util.js";

const VIEWS = ["run", "z3", "explore", "history"];
const startView = (() => {
  const h = location.hash.slice(1);
  if (VIEWS.includes(h)) return h;
  const v = load("scone.view");
  return VIEWS.includes(v) ? v : "run";
})();

export const live = $state({
  S: null, // last snapshot from /api/events
  online: false,
  clockSkew: 0, // local clock minus server clock, seconds
  now: Date.now() / 1000, // ticks every second so durations stay fresh
  ratesVersion: 0, // bumped when `rates` changes (the array itself is not reactive)
  dbKey: "", // changes whenever scone.db gains classes or levels
});

export const ui = $state({
  view: startView,
  drawer: false,
  palette: false,
  explore: { q: "", page: 1, filter: "rules", order: "desc", cost: "" },
});

/** Throughput samples [t, phase, level, rate], kept outside reactivity: they are only drawn. */
export const rates = [];

const logListeners = new Set();
/** Registers fn(lines, reset) for engine log lines; returns an unsubscribe function. */
export function onLog(fn) { logListeners.add(fn); return () => logListeners.delete(fn); }
let logBacklog = []; // everything received so far, replayed to late subscribers
export const logLines = () => logBacklog;

export const isLive = () => !!live.S && ["running", "paused", "stopping"].includes(live.S.status);
export function serverNow() { return live.now - live.clockSkew; }

export function showView(v) {
  if (!VIEWS.includes(v)) return;
  ui.view = v;
  store("scone.view", v);
  if (location.hash !== "#" + v) history.replaceState(null, "", "#" + v);
  window.scrollTo({ top: 0 });
}
window.addEventListener("hashchange", () => showView(location.hash.slice(1)));

// The server sends a state update on every change and a ping at least every 15 s. A connection
// that goes quiet for longer (laptop sleep, network change, server restart) is dead even if the
// browser has not noticed, so it is replaced.
const STALE_MS = 35_000;

export function connect() {
  let es = null;
  let first = true;
  let lastSeen = Date.now();

  function onState(e) {
    lastSeen = Date.now();
    live.online = true;
    let s;
    try { s = JSON.parse(e.data); } catch (err) { console.error("[scone] bad update", err); return; }
    live.clockSkew = Date.now() / 1000 - s.now;
    const newRun = live.S && live.S.meta && s.meta && live.S.meta.started !== s.meta.started;
    const reset = first || !!s.log_reset || newRun;
    first = false;
    if (reset) { rates.length = 0; logBacklog = []; }
    logBacklog = logBacklog.concat(s.log || []);
    if (logBacklog.length > 2000) logBacklog = logBacklog.slice(-2000);
    for (const r of s.rates || []) rates.push(r);
    if (rates.length > 1500) rates.splice(0, rates.length - 1200);
    if ((s.rates && s.rates.length) || reset) live.ratesVersion++;
    const key = s.db ? `${s.db.classes}|${s.db.max_cost}` : "";
    if (key !== live.dbKey) live.dbKey = key;
    live.S = s;
    // listeners last: one that throws must not keep the state from updating
    for (const fn of logListeners) {
      try { fn(s.log || [], reset); } catch (err) { console.error("[scone] log listener", err); }
    }
  }

  function open() {
    if (es) es.close();
    first = true; // the server sends the whole state and log again on a new connection
    lastSeen = Date.now();
    es = new EventSource("/api/events");
    es.onopen = () => { live.online = true; lastSeen = Date.now(); };
    es.onmessage = onState;
    es.addEventListener("ping", () => { lastSeen = Date.now(); live.online = true; });
    es.onerror = () => { live.online = false; }; // EventSource retries on its own
  }

  function check() {
    if (Date.now() - lastSeen > STALE_MS) open();
  }

  open();
  setInterval(() => { live.now = Date.now() / 1000; }, 1000);
  setInterval(check, 5000);
  // background tabs get their timers throttled: check as soon as the tab is shown again
  document.addEventListener("visibilitychange", () => { if (!document.hidden) check(); });
  window.addEventListener("online", open);
}

