<script>
  // One tooltip for the whole page: any element with a data-tip attribute (HTML from tipRows) shows it.
  let el;
  let on = $state(false);

  function over(e) {
    const t = e.target.closest?.("[data-tip]");
    if (!t || !t.dataset.tip) return;
    el.innerHTML = t.dataset.tip;
    on = true;
  }
  function out(e) {
    const t = e.target.closest?.("[data-tip]");
    if (t && !t.contains(e.relatedTarget)) on = false;
  }
  function move(e) {
    if (!on) return;
    const w = el.offsetWidth, h = el.offsetHeight;
    el.style.left = Math.min(e.clientX + 14, innerWidth - w - 8) + "px";
    el.style.top = (e.clientY + 16 + h > innerHeight ? e.clientY - h - 12 : e.clientY + 16) + "px";
  }
</script>

<svelte:document onpointerover={over} onpointerout={out} onpointermove={move} />
<div id="tt" role="tooltip" class:on bind:this={el}></div>
