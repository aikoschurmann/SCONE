# ⚡ SCONE: Superoptimization via Native Enumeration

SCONE is a tool that automatically discovers mathematically proven peephole optimizations and rewrite rules for compilers. You give it a maximum AST depth, and it explores all possible combinations of bitwise operations, using the Z3 SMT Solver to mathematically prove which combinations are identical.

The results are saved as verified rewrite rules into a local SQLite database (`scone.db`).

---

## 🚀 Getting Started

Requires **Zig (`0.13.0`+)**, **Z3**, and **SQLite3**.

```bash
# Install dependencies (macOS)
brew install zig z3 sqlite3

# Build the engine
zig build -Doptimize=ReleaseFast
```

### 1. Run the Engine
Launch SCONE to explore expressions up to Cost 3 (this takes time as Z3 proves the rules). The engine will automatically pause and save state if you hit Ctrl-C, and resume exactly where it left off.

```bash
./zig-out/bin/scone -c 3
```

### 2. View the Results (The Database)
SCONE has no output files other than `scone.db`. Once a cost level is verified, the proven rewrite rules are permanently stored in SQLite. 

You can query the database directly to extract the optimizations. 
For example, to find all expressions that simplify to `0`:

```sql
sqlite3 scone.db "SELECT c.id as class_id, e.id as expr_id, e.tag, e.op 
                  FROM classes c 
                  JOIN expressions e ON e.class_id = c.id 
                  WHERE c.canonical_expr = (SELECT id FROM expressions WHERE tag='constant' AND c2=0);"
```

You can view the canonical (simplest) form of any equivalence class:
```sql
sqlite3 scone.db "SELECT id, canonical_expr FROM classes LIMIT 10;"
```

---

## 🧰 Advanced Tools & Usage

### Distilling Counterexamples
During generation, SCONE accumulates thousands of counterexamples to distinguish mathematical edge cases. You can compress these down to a minimal mathematical set (usually reducing 7,000+ samples down to ~50) using the offline distiller tool:

```bash
# Connects to scone.db and compresses the counterexample grid
./zig-out/bin/compress_db
```

Alternatively, you can tell SCONE to automatically distill the database at the end of every cost level:
```bash
./zig-out/bin/scone -c 3 --distill-ces
```

### CLI Options

You can constrain the search space to find specific types of rules faster:

```text
  -c, --cost <NUM>       Max AST depth to explore (e.g., 3 or 4).
  -t, --threads <NUM>    Number of CPU cores to use. (Default: System max)
  --no-select            Disable ternary select (branching) operations.
  --no-unary             Disable unary operations (not, clz, ctz, popcount).
  --z3-timeout <MS>      Skip proofs that take Z3 longer than <MS> to solve.
  --clean                Delete scone.db and exit immediately.\n  --distill-ces          Automatically compress the counterexamples after proving.
```

## 🛠️ Resuming Interrupted Runs
SCONE is fully resumable. If you run `scone -c 2`, and later want to explore Cost 3, simply run `scone -c 3`. SCONE will read the verified Cost 2 boundaries from `scone.db`, reconstruct the math in memory, and immediately begin Cost 3 without re-evaluating earlier rules.
