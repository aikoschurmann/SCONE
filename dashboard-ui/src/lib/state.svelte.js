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

export function connect() {
  const es = new EventSource("/api/events");
  let first = true;
  es.onopen = () => { live.online = true; };
  es.onmessage = (e) => {
    live.online = true;
    const s = JSON.parse(e.data);
    live.clockSkew = Date.now() / 1000 - s.now;
    const newRun = live.S && live.S.meta && s.meta && live.S.meta.started !== s.meta.started;
    const reset = first || !!s.log_reset || newRun;
    if (reset) { rates.length = 0; logBacklog = []; }
    logBacklog = logBacklog.concat(s.log);
    if (logBacklog.length > 2000) logBacklog = logBacklog.slice(-2000);
    for (const fn of logListeners) fn(s.log, reset);
    for (const r of s.rates) rates.push(r);
    if (rates.length > 1500) rates.splice(0, rates.length - 1200);
    if (s.rates.length || reset) live.ratesVersion++;
    const key = s.db ? `${s.db.classes}|${s.db.max_cost}` : "";
    if (key !== live.dbKey) live.dbKey = key;
    first = false;
    live.S = s;
  };
  es.onerror = () => { live.online = false; };
  setInterval(() => { live.now = Date.now() / 1000; }, 1000);
}
