# ⚡ SCONE: Superoptimization via Native Enumeration

SCONE is a tool that automatically discovers mathematically proven peephole optimizations and rewrite rules for compilers. You give it a maximum cost (expression size), and it enumerates every expression over `x`, `y`, `z` and a set of constants, groups them by their values on a sample grid, and proves which ones are identical, mostly with fast algebraic checks and otherwise with the Z3 SMT solver.

The results are saved as verified rewrite rules into a local SQLite database (`scone.db`).

---

## 🚀 Getting Started

Requires **Zig (`0.13.0`+)**, **Z3**, and **SQLite3**; the dashboard also needs **Python 3** and **Node 20+**.

```bash
# Install dependencies (macOS)
brew install zig z3 sqlite3

# Build the engine
zig build -Doptimize=ReleaseFast
```

### 1. Run the Engine
Launch SCONE to explore expressions up to cost 3. The engine saves after every finished cost level and stops cleanly on Ctrl-C; the next run resumes from the last saved level.

```bash
./zig-out/bin/scone -c 3
```

### 2. Web Dashboard
Start, pause, queue and stop runs, follow live progress (phases, throughput, what every Z3 worker is
doing right now, the work queue, the Z3 query log) and browse the proven rules:

```bash
cd dashboard-ui && npm install && npm run build && cd ..   # once, and after UI changes
python3 dashboard.py                                         # http://127.0.0.1:8080  (--port to change)
```

The engine runs detached and logs to `scone_run.log`, so closing the dashboard doesn't stop it;
reopening re-attaches. Stopping discards only the level in progress. For UI work, `npm run dev`
in `dashboard-ui/` serves the UI with hot reload and forwards `/api` to the running `dashboard.py`.

### 3. View the Results (The Database)
Every proven rule is in `scone.db`: each class has one canonical (cheapest) expression, and every
other expression in the class rewrites to it. The dashboard's Explore view searches and browses
them; you can also query SQLite directly. Expressions are stored as rows (`tag` is `variable`,
`constant`, `unary`, `binary` or `select`; `op` holds the operator, constant or variable index;
`c1`..`c3` are child expression ids).

```sql
-- classes whose canonical form is the constant 0 (everything in them simplifies to 0)
sqlite3 scone.db "SELECT c.id, count(*) FROM classes c
                  JOIN expressions k ON k.id = c.canonical_expr_id AND k.tag = 'constant' AND k.op = '0'
                  JOIN expressions e ON e.class_id = c.id GROUP BY c.id;"

-- the canonical expression of the first classes
sqlite3 scone.db "SELECT id, canonical_expr_id, status FROM classes LIMIT 10;"
```

---

## 🔍 How Verification Works

Expressions with the same values on the sample grid form a candidate class; each member is then
checked against the class's canonical expression, cheapest method first:

1. **Abstract interpretation** (`src/absint.zig`): ranges and known bits prove members that are a constant.
2. **Algebraic normal forms** (`src/normalize.zig`): two expressions with the same normal form are equal.
   This settles most members in microseconds.
3. **Z3's rewriter**, then **Z3 queries** in chunks of 32 members. A counterexample splits the class
   and is shared with every worker, so it separates other classes too.
4. A single member that still times out is searched for a needle counterexample; if it uses only one
   variable, it is **decided exactly on all 2^32 inputs** (`src/exhaustive.zig`). Otherwise Z3 gets
   longer timeouts, and if it still cannot decide, the class is marked `unverified`.

Set `SCONE_QUERY_LOG=z3log/q` to log every Z3 query with its time and result (the dashboard does this
when "Log Z3 queries" is on); the Z3 view summarises the log.

---

## 🧰 Advanced Usage

### CLI Options

```text
  -c, --cost <NUM>         Max cost (expression size) to explore, e.g. 3 or 4. Default 3.
  -t, --threads <NUM>      Number of worker processes. Default: all cores.
  --lite                   Small search space for fast testing: no select, no unary,
                           binops add,sub,and_op,or_op,xor,shl,lshr, constants 0,1,0xFFFFFFFF.
  --no-select              Disable ternary select.
  --no-unary               Disable unary operations (neg, not, clz, ctz, popcount).
  --binops LIST            Only enumerate these binary ops (e.g. add,xor,shl).
  --unops LIST             Only enumerate these unary ops (e.g. not,neg); enables unary.
  --consts LIST            Only seed these constants (subset of search_constants, e.g. 0,1,0xFFFFFFFF).
  --z3-timeout <MS>        First Z3 timeout per query (default 1000; retries use 4x and 16x).
  --no-absint              Skip the abstract-interpretation pass.
  --audit-absint <N>       Re-check every Nth abstract-interpretation proof with Z3.
  --audit-normalize <N>    Re-check every Nth normal-form proof with Z3.
  --distill-ces            Compress the counterexample grid after each level.
  --clean                  Delete scone.db before starting.
  --no-prune, --uniform-random, --cartesian, --random-samples <N>
                           Enumeration and sample-grid experiments.
```

### Resuming
SCONE is resumable. If you run `scone -c 2` and later want cost 3, run `scone -c 3`: it loads the
verified classes from `scone.db` and starts at cost 3 without re-proving earlier levels.

---

## 🧪 Development

```bash
scripts/check.sh                       # normalizer and exhaustive-check tests, sharded over all cores (~30 s)
scripts/check.sh replay pairs.tsv      # replay logged Z3 pairs through the normalizer
REPLAY_EXHAUSTIVE=1 scripts/check.sh replay pairs.tsv   # ... and decide open single-variable pairs
```

A replay file has one pair per line: `weight<TAB>base<TAB>member`, in the expression syntax of the Z3
query log; the summary reports how much of the logged solver time the normalizer would settle, and
the most expensive families it leaves to Z3. While a scone run is live, the script uses only 2
processes so the run's Z3 timings stay meaningful.
