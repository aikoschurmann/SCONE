// The run settings form: values, persistence, the command line and the plan text.
import { load, store, fmtN } from "./util.js";
import { live, isLive } from "./state.svelte.js";

export const DEFAULTS = {
  cost: "3", threads: "", lite: false, select: true, unary: true, binops: "", unops: "", consts: "",
  absint: true, z3_log: false, z3_timeout: "", audit_normalize: "", distill_ces: false, clean: false,
};

function initial() {
  try {
    const saved = JSON.parse(load("scone.cfg3") || load("scone.cfg2") || "{}");
    const out = { ...DEFAULTS };
    for (const k of Object.keys(DEFAULTS)) if (k in saved) out[k] = typeof DEFAULTS[k] === "boolean" ? !!saved[k] : String(saved[k] ?? "");
    return out;
  } catch (e) {
    return { ...DEFAULTS };
  }
}

export const cfg = $state(initial());
$effect.root(() => { $effect(() => { store("scone.cfg3", JSON.stringify(cfg)); }); });

export const isDefault = () => Object.keys(DEFAULTS).every((k) => k === "cost" || String(cfg[k]) === String(DEFAULTS[k]));
export function resetCfg() { const cost = cfg.cost; Object.assign(cfg, DEFAULTS, { cost }); }

export function toApi(o = cfg) {
  return {
    cost: o.cost, threads: o.threads, z3_timeout: o.z3_timeout, audit_normalize: o.audit_normalize, lite: o.lite,
    no_select: !o.select, no_unary: !o.unary, no_absint: !o.absint, distill_ces: o.distill_ces, clean: o.clean,
    binops: o.binops, unops: o.unops, consts: o.consts, z3_log: o.z3_log,
  };
}

export function cmdLine(o = cfg) {
  const a = ["./zig-out/bin/scone", "-c", o.cost || "3"];
  if (o.threads !== "") a.push("-t", o.threads);
  if (o.z3_timeout) a.push("--z3-timeout", o.z3_timeout);
  if (+o.audit_normalize > 0) a.push("--audit-normalize", o.audit_normalize);
  if (o.lite) a.push("--lite");
  if (!o.select) a.push("--no-select");
  if (!o.unary) a.push("--no-unary");
  if (!o.absint) a.push("--no-absint");
  if (o.distill_ces) a.push("--distill-ces");
  if (o.clean) a.push("--clean");
  for (const k of ["binops", "unops", "consts"]) if (o[k]) a.push("--" + k, o[k].replace(/\s/g, ""));
  return (o.z3_log ? "SCONE_QUERY_LOG=z3log/q " : "") + a.join(" ");
}

/** What starting (or queueing) these settings would do. */
export function plan() {
  const S = live.S, cost = +cfg.cost || 3, d = (S && S.db) || {}, have = d.exists ? d.max_cost || 0 : 0;
  const running = isLive(), m = (S && S.meta) || {};
  const target = running ? Math.max(have, +m.target || S.level || 0) : have;
  const span = (a, b) => (a === b ? `cost ${b}` : `costs ${a}–${b}`);
  let cls = "", msg, fix = null;
  if (S && S.external_pid) { cls = "crit"; msg = `Another scone process (pid ${S.external_pid}) is using scone.db.`; }
  else if (cfg.clean) { cls = "crit"; msg = `${running ? "After the current run, deletes" : "Deletes"} all ${fmtN(d.classes || 0)} proven classes, then builds ${span(1, cost)} from scratch.`; }
  else if (target >= cost) { cls = "warn"; msg = running ? `The current run already reaches cost ${target}.` : `scone.db is already verified to cost ${have}.`; fix = target + 1; }
  else if (running) msg = `Continues after the current run and proves ${span(target + 1, cost)}.`;
  else if (have > 0) msg = `Resumes from the saved cost ${have} and proves ${span(have + 1, cost)}.`;
  else msg = `Builds ${span(1, cost)} from an empty database.`;
  const blocked = !live.online || !!(S && S.external_pid);
  return { cls, msg, fix, blocked, nothing: !cfg.clean && target >= cost, restartBlocked: blocked || (!cfg.clean && have >= cost) };
}
