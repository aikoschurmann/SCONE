# ⚡ SCONE: Synthesis of Compiler Optimizations via Native Enumeration

SCONE is a hyper-optimized, lock-free **Counterexample-Guided Inductive Synthesis (CEGIS)** engine written in Zig. 

It automatically discovers and formally verifies mathematically equivalent bitwise operations, peephole optimizations, and rewrite rules by enumerating abstract syntax trees (ASTs), hashing their execution outputs, and querying the **Z3 SMT Solver** to mathematically prove their equivalence.

SCONE is designed to scale horizontally across CPU cores and vertically into the billions of expressions. It generates millions of equivalence classes per second on Apple Silicon, compresses counterexamples using Greedy Set Cover algorithms, and is completely backed by an asynchronous SQLite database to guarantee zero data loss on complex multi-day runs.

---

## 🚀 Key Features

* **Lock-Free RingBuffer Engine:** Enumeration workers utilize lock-free atomic `MPSC` and `SPSC` RingBuffers, pushing evaluation throughput to **3.2+ Million expressions per second** per node.
* **SQLite Persistence (Resumable State):** SCONE continuously saves its exact evaluation grid, proven classes, and mathematical proofs to a local `scone.db`. If Z3 times out or the machine reboots, SCONE instantly reconstructs the RAM arenas and resumes on the next unverified Cost boundary.
* **Greedy Set Cover Distillation:** Over long CEGIS loops, the grid of counterexamples balloons into the thousands, slowing down evaluation. SCONE uses an ultra-fast Greedy Set Cover algorithm to mathematically compress redundant counterexamples by 99% (e.g., from 7,000 samples down to 50 killer samples) with absolutely zero loss of resolution.
* **128-bit Composite Wyhash:** To support evaluation runs probing $10^9+$ expressions, SCONE employs dual-seeded 128-bit `Wyhash` fingerprinting to entirely eliminate Birthday-Bound collisions on the evaluation grid.
* **Native Z3 Integration:** Zero subprocess overhead. Z3 queries are routed directly through Zig's C-ABI bindings (`-lz3`) in parallel across the verification worker pool.
* **Offline Distillation CLI:** Includes a standalone `compress_db` tool to dynamically distill active counterexamples directly from the SQLite database asynchronously, without halting the main synthesis engine.

---

## 🛠️ The Architecture

### The Search Space (Cost Boundaries)
SCONE explores combinations iteratively by AST Depth ("Cost").
* **Cost 0:** Base variables (`x`, `y`, `z`) and edge-case constants (`0`, `1`, `-1`, `INT_MAX`, `INT_MIN`).
* **Cost N:** Combinations of lower-cost trees using native LLVM-like IR instructions.
  * **Binary:** `add`, `sub`, `mul`, `and`, `or`, `xor`, `shl`, `lshr`, `ashr`, `eq`, `ult`, `slt`
  * **Unary:** `not`, `neg`, `clz`, `ctz`, `popcount`
  * **Ternary:** `select` (conditional branching)

### The Fast-Grid vs Deep-Grid
To conserve Gigabytes of RAM, SCONE employs a hierarchical memory model. New expressions are evaluated against a SIMD-optimized 256-byte **Fast Grid**. Only expressions that collide on the Fast Grid trigger a deferred, parallelized computation on the **Deep Grid** (thousands of counterexamples) to determine true equivalence.

---

## 📦 Build & Installation

Requires **Zig (`0.13.0`+)**, **Z3**, and **SQLite3**.

### macOS (via Homebrew)
```bash
brew install zig z3 sqlite3
```

### Building the Project
```bash
zig build -Doptimize=ReleaseFast
```

---

## 💻 CLI Usage

SCONE is completely self-contained. It stores all output and progress locally in `scone.db`.

```bash
# Run SCONE up to Cost 3, utilizing 10 CPU cores
./zig-out/bin/scone -c 3 -t 10
```

### Core Options
* `-c, --cost <NUM>`: Max AST depth (cost) to generate and verify.
* `-t, --threads <NUM>`: Number of lock-free workers and Z3 verification threads. Defaults to CPU core count.
* `--distill-ces`: Automatically distill the counterexample grid into a minimal `killer_samples.txt` file at the end of every successful Cost level.
* `--no-select`: Disables ternary `select` operations to exponentially reduce search space.
* `--no-unary`: Disables unary operations.
* `--z3-timeout <MS>`: Hard limit for a single Z3 mathematical proof in milliseconds (Default: `1000`).
* `--ce-limit <NUM>`: Caps the maximum number of unique counterexamples integrated per CEGIS iteration.

### Standalone Tools
You can extract or compress data from SCONE's live database using the bundled offline tools:

```bash
# Mathematically compress the active counterexamples in scone.db
./zig-out/bin/compress_db
```

---

## 🗂️ Module Layout

* `src/main.zig` - The CEGIS Orchestrator & CLI entrypoint.
* `src/sqlite_db.zig` - The native SQLite persistence and state reconstruction layer.
* `src/distill.zig` - The Greedy Set Cover mathematical distillation pipeline.
* `src/enumerate.zig` - Multithreaded lock-free ringbuffer orchestration.
* `src/eval.zig` - Unswitched batch SIMD math instructions (`combine_binary_into`).
* `src/verify.zig` - Native multi-threaded Z3 verification and C-bindings.
* `src/database.zig` - Internal lock-free RAM Arenas (`ExpressionArena`, `ClassVectorArena`).
* `src/ast.zig` - AST generation and cost resolution logic.
* `src/compress_cli.zig` - Standalone offline CLI tool for database manipulation.

---

> **Note:** SCONE is actively developed. The SQLite backing allows runs to continue for weeks without data loss. If a run hits Z3 timeouts on heavily nested bit-shifts (Cost 4+), SCONE gracefully isolates the timeouts in the database and preserves the surrounding logic.
