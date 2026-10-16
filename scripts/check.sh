#!/usr/bin/env bash
# Fast checks for the verification shortcuts (normalizer, exhaustive single-variable check).
#   scripts/check.sh               soundness tests, sharded over the cores
#   scripts/check.sh replay F.tsv  replay logged Z3 pairs (weight, base, member) and summarise
#   REPLAY_EXHAUSTIVE=1 scripts/check.sh replay F.tsv   also decide open single-variable pairs
# Each binary is compiled once and its shards run directly in parallel. While a scone run is
# live only 2 processes are used, so its Z3 timings stay meaningful.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
if pgrep -f "zig-out/bin/scone" >/dev/null; then
  jobs=2
  echo "a scone run is live: using $jobs processes"
fi

if [ "${1:-}" = "replay" ]; then
  in=${2:?usage: scripts/check.sh replay pairs.tsv}
  zig test -O ReleaseFast -lc src/replay_test.zig --test-filter replay --test-no-exec -femit-bin="$out/replay"
  lines=$(wc -l < "$in")
  split -l $(( (lines + jobs - 1) / jobs )) "$in" "$out/in_"
  start=$(date +%s)
  for f in "$out"/in_*; do REPLAY_IN="$f" REPLAY_OUT="${f/in_/out_}" "$out/replay" >/dev/null 2>&1 & done
  wait
  cat "$out"/out_* > "${REPLAY_RESULT:-replay.out}"
  echo "replayed $lines pairs in $(( $(date +%s) - start ))s -> ${REPLAY_RESULT:-replay.out}"
  python3 - "${REPLAY_RESULT:-replay.out}" <<'PY'
import sys, collections, re
t = collections.Counter(); fam = collections.Counter(); ex = {}
for l in open(sys.argv[1]):
    s, us, b, m = l.rstrip("\n").split("\t")[:4]; t[s] += int(us)
    if s == "open":
        k = re.sub(r"\b\d+\b", "K", b) + " == " + re.sub(r"\b\d+\b", "K", m)
        fam[k] += int(us); ex.setdefault(k, (b, m))
tot = sum(t.values()) or 1
print(f"settled {t['settled']/1e6:.0f} s of {tot/1e6:.0f} s logged solver time ({t['settled']/tot:.1%})")
if t['exhaustive'] or t['differ']: print(f"exhaustive check: {t['exhaustive']/1e6:.0f} s proven equal, {t['differ']/1e6:.0f} s found unequal; together {(t['settled']+t['exhaustive']+t['differ'])/tot:.1%} decided")
for k, v in fam.most_common(15): print(f"  {v/1e6:6.1f}s  {ex[k][0]}  ==  {ex[k][1]}")
PY
  exit 0
fi

zig test -O ReleaseFast -lc src/normalize.zig --test-no-exec -femit-bin="$out/normtest"
start=$(date +%s)
pids=()
for i in $(seq 0 $((jobs - 1))); do
  SCONE_SHARD="$i/$jobs" "$out/normtest" > "$out/shard$i.log" 2>&1 & pids+=($!)
done
fail=0
for i in "${!pids[@]}"; do wait "${pids[$i]}" || { fail=1; echo "shard $i failed:"; grep -v "\.\.\.OK$" "$out/shard$i.log" | head -20; }; done
zig test -O ReleaseFast -lc src/exhaustive.zig --test-no-exec -femit-bin="$out/extest"
"$out/extest" > "$out/ex.log" 2>&1 || { fail=1; echo "exhaustive tests failed:"; grep -v "\.\.\.OK$" "$out/ex.log" | head -20; }
if [ $fail = 0 ]; then echo "all normalizer and exhaustive tests passed ($jobs shards, $(( $(date +%s) - start ))s)"; else exit 1; fi
