// Toasts, the confirm dialog and server actions.

export const toasts = $state([]);
let toastId = 0;
export function toast(msg, err) {
  const t = { id: ++toastId, msg, err: !!err };
  toasts.push(t);
  setTimeout(() => { const i = toasts.findIndex((x) => x.id === t.id); if (i >= 0) toasts.splice(i, 1); }, err ? 6000 : 2800);
}

export const confirmState = $state({ open: false, title: "", body: "", yes: "OK", danger: false, resolve: null });
/** Resolves true when the user confirms, false otherwise. */
export function ask(title, body, yes, danger) {
  return new Promise((resolve) => Object.assign(confirmState, { open: true, title, body, yes, danger: !!danger, resolve }));
}

export async function post(action, body) {
  try {
    const r = await fetch("/api/" + action, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { toast(j.error || "Request failed", true); return false; }
    return true;
  } catch (e) {
    toast("Dashboard server unreachable", true);
    return false;
  }
}

export function copy(text, what) {
  if (navigator.clipboard) navigator.clipboard.writeText(text).then(() => toast(`Copied ${what}`), () => toast("Copy failed", true));
}
