import "./app.css";
import { mount } from "svelte";
import App from "./App.svelte";
import { connect } from "./lib/state.svelte.js";

// Uncaught errors (an exception inside a view stops that view from updating) are reported to
// dashboard.py, which writes them to its log.
let reported = 0;
function report(message, stack) {
  if (++reported > 20) return;
  fetch("/api/client_error", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message: String(message), stack: String(stack || ""), where: location.hash }),
  }).catch(() => {});
}
window.addEventListener("error", (e) => report(e.message, e.error && e.error.stack));
window.addEventListener("unhandledrejection", (e) => report(e.reason && e.reason.message ? e.reason.message : e.reason, e.reason && e.reason.stack));

connect();
mount(App, { target: document.getElementById("app") });
