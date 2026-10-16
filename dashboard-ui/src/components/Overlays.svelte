<script>
  // Toasts and the confirm dialog.
  import Icon from "./Icon.svelte";
  import { toasts, confirmState } from "../lib/ui.svelte.js";

  let dlg;
  let yesBtn = $state(), noBtn = $state();
  $effect(() => {
    if (confirmState.open && dlg && !dlg.open) {
      dlg.showModal();
      (confirmState.danger ? noBtn : yesBtn)?.focus();
    }
  });
  function done(v) {
    confirmState.open = false;
    dlg.close();
    confirmState.resolve?.(v);
  }
</script>

<dialog id="dlg" bind:this={dlg} oncancel={(e) => { e.preventDefault(); done(false); }}>
  <h3>{confirmState.title}</h3>
  <p>{confirmState.body}</p>
  <div class="acts">
    <button class="btn" bind:this={noBtn} onclick={() => done(false)}>Cancel</button>
    <button class="btn {confirmState.danger ? 'danger solid' : 'primary'}" bind:this={yesBtn} onclick={() => done(true)}>{confirmState.yes}</button>
  </div>
</dialog>

<div class="toasts" aria-live="polite">
  {#each toasts as t (t.id)}
    <div class="toast" class:err={t.err}><Icon name={t.err ? "alert" : "check"} cls="sm" /><span>{t.msg}</span></div>
  {/each}
</div>
