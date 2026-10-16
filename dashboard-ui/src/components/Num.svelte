<script>
  // A number that glides to its new value instead of jumping.
  import { Tween } from "svelte/motion";
  import { cubicOut } from "svelte/easing";

  let { value, format = (v) => String(Math.round(v)) } = $props();
  const valid = $derived(value != null && isFinite(value));
  const tween = new Tween(0, { duration: 600, easing: cubicOut });
  let started = false;
  $effect(() => {
    if (!valid) return;
    if (!started) { tween.set(value, { duration: 0 }); started = true; }
    else tween.target = value;
  });
</script>

{valid ? format(tween.current) : "–"}
