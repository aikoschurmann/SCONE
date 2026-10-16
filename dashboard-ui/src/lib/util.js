// Formatting, expression rendering and small helpers shared by every component.

export const fmtN = (n) => (n == null || n === "" || Number.isNaN(+n) ? "–" : Number(n).toLocaleString());
export const fmtSI = (n) =>
  n == null ? "–"
  : n >= 1e9 ? (n / 1e9).toFixed(1) + "B"
  : n >= 1e6 ? (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + "M"
  : n >= 1e3 ? (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + "k"
  : String(Math.round(n));
export const fmtB = (b) => (b >= 2 ** 30 ? (b / 2 ** 30).toFixed(1) + " GB" : b >= 2 ** 20 ? (b / 2 ** 20).toFixed(0) + " MB" : (b / 1024).toFixed(0) + " KB");
export const fmtDur = (s) => {
  if (s == null || !isFinite(s)) return "–";
  s = Math.max(0, Math.round(s));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : m ? `${m}m ${x}s` : `${x}s`;
};
export const fmtUs = (us) => (us >= 1e6 ? (us / 1e6).toFixed(us >= 1e7 ? 0 : 1) + " s" : us >= 1e3 ? Math.round(us / 1e3) + " ms" : Math.round(us) + " µs");
export const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
export const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();

export function store(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
export function load(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }

/** Tooltip HTML: a bold title and label/value rows. Pass the result to a `data-tip` attribute. */
export const tipRows = (title, rows) =>
  (title ? `<b>${esc(title)}</b>` : "") + rows.map(([k, v]) => `<div class="r"><span>${esc(k)}</span><span>${esc(v)}</span></div>`).join("");

/** Syntax-highlighted HTML for an expression in the dashboard's text form. */
export function hl(s) {
  return esc(s).replace(/0x[0-9a-f]+|\b\d+\b|\b[xyz]\b|\b(?:clz|ctz|popcount)\b|&lt;=?[su]?|&gt;&gt;s?|&lt;&lt;|==|[+\-*^|~?:]|&amp;|[()]/g, (t) => {
    const c = /^[xyz]$/.test(t) ? "tv" : /^(0x|\d)/.test(t) ? "tn" : /^[a-z]/.test(t) ? "tf" : /^[()]$/.test(t) ? "tp" : "to";
    return `<span class="${c}">${t}</span>`;
  });
}

// Parses the dashboard's expression text back into a tree (nested binaries are always parenthesized).
export function parseExpr(src) {
  const toks = src.match(/0x[0-9a-fA-F]+|\d+|[A-Za-z_]+|<=u|<=s|<u|<s|>>s|>>|<<|==|[-+*&|^~?:()]/g) || [];
  let i = 0;
  const peek = () => toks[i], next = () => toks[i++];
  const BIN = new Set(["+", "-", "*", "&", "|", "^", "<<", ">>", ">>s", "<u", "<=u", "<s", "<=s", "=="]);
  function atom() {
    const t = next();
    if (t === "(") { const e = full(); next(); return e; }
    if (t === "-") return { op: "neg", a: atom() };
    if (t === "~") return { op: "not", a: atom() };
    if (t === "popcount" || t === "clz" || t === "ctz") { next(); const e = full(); next(); return { op: t, a: e }; }
    if (/^[xyz]$/.test(t)) return { v: t };
    return { k: Number(t) >>> 0 };
  }
  function full() {
    const l = atom();
    if (peek() === "?") { next(); const a = full(); next(); const b = full(); return { op: "sel", c: l, a, b }; }
    if (BIN.has(peek())) { const op = next(); return { op, l, r: atom() }; }
    return l;
  }
  return full();
}

export function toC(n) {
  if (n.v) return n.v;
  if (n.k != null) return n.k > 64 ? "0x" + n.k.toString(16) + "u" : n.k + "u";
  const C = toC;
  switch (n.op) {
    case "neg": return `(-${C(n.a)})`;
    case "not": return `(~${C(n.a)})`;
    case "popcount": return `(uint32_t)__builtin_popcount(${C(n.a)})`;
    case "clz": return `(${C(n.a)} ? (uint32_t)__builtin_clz(${C(n.a)}) : 32u)`;
    case "ctz": return `(${C(n.a)} ? (uint32_t)__builtin_ctz(${C(n.a)}) : 32u)`;
    case "sel": return `(${C(n.c)} ? ${C(n.a)} : ${C(n.b)})`;
    case "<<": return `(${C(n.l)} << (${C(n.r)} & 31u))`;
    case ">>": return `(${C(n.l)} >> (${C(n.r)} & 31u))`;
    case ">>s": return `(uint32_t)((int32_t)${C(n.l)} >> (${C(n.r)} & 31u))`;
    case "<u": return `(uint32_t)(${C(n.l)} < ${C(n.r)})`;
    case "<=u": return `(uint32_t)(${C(n.l)} <= ${C(n.r)})`;
    case "<s": return `(uint32_t)((int32_t)${C(n.l)} < (int32_t)${C(n.r)})`;
    case "<=s": return `(uint32_t)((int32_t)${C(n.l)} <= (int32_t)${C(n.r)})`;
    case "==": return `(uint32_t)(${C(n.l)} == ${C(n.r)})`;
    default: return `(${C(n.l)} ${n.op} ${C(n.r)})`;
  }
}

export function toSmt(n) {
  const S = toSmt, hex = (k) => "#x" + (k >>> 0).toString(16).padStart(8, "0"), bool = (b) => `(ite ${b} #x00000001 #x00000000)`;
  if (n.v) return n.v;
  if (n.k != null) return hex(n.k);
  const sh = (r) => `(bvand ${S(r)} #x0000001f)`;
  switch (n.op) {
    case "neg": return `(bvneg ${S(n.a)})`;
    case "not": return `(bvnot ${S(n.a)})`;
    case "sel": return `(ite (= ${S(n.c)} #x00000000) ${S(n.b)} ${S(n.a)})`;
    case "+": return `(bvadd ${S(n.l)} ${S(n.r)})`;
    case "-": return `(bvsub ${S(n.l)} ${S(n.r)})`;
    case "*": return `(bvmul ${S(n.l)} ${S(n.r)})`;
    case "&": return `(bvand ${S(n.l)} ${S(n.r)})`;
    case "|": return `(bvor ${S(n.l)} ${S(n.r)})`;
    case "^": return `(bvxor ${S(n.l)} ${S(n.r)})`;
    case "<<": return `(bvshl ${S(n.l)} ${sh(n.r)})`;
    case ">>": return `(bvlshr ${S(n.l)} ${sh(n.r)})`;
    case ">>s": return `(bvashr ${S(n.l)} ${sh(n.r)})`;
    case "<u": return bool(`(bvult ${S(n.l)} ${S(n.r)})`);
    case "<=u": return bool(`(bvule ${S(n.l)} ${S(n.r)})`);
    case "<s": return bool(`(bvslt ${S(n.l)} ${S(n.r)})`);
    case "<=s": return bool(`(bvsle ${S(n.l)} ${S(n.r)})`);
    case "==": return bool(`(= ${S(n.l)} ${S(n.r)})`);
    default: return `(${n.op} ${S(n.a)})`; // popcount, clz, ctz: define these in your SMT preamble
  }
}
