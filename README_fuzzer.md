# Semantic Property Fuzzer

To guarantee that the Zig SIMD evaluator (`eval_batch` / `combine_binary_into`) and the SMT Verification lowering (`to_z3`) share the exact same bit-level semantics, we have introduced a property fuzzer.

Run it at CI time using:
`zig run src/fuzzer.zig -I/opt/homebrew/Cellar/z3/4.15.4/include -L/opt/homebrew/Cellar/z3/4.15.4/lib -lz3 -lc`

It exhaustively tests thousands of random `u32` boundary cases across every single unary and binary operator, asserting that Zig's native vector behavior perfectly matches the constructed Z3 AST semantics.
