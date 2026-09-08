const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const verify = @import("verify.zig");
const z3 = @cImport({
    @cInclude("z3.h");
});

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const z3_cfg = z3.Z3_mk_config();
    const ctx = z3.Z3_mk_context(z3_cfg);
    z3.Z3_del_config(z3_cfg);
    defer z3.Z3_del_context(ctx);

    const sort = z3.Z3_mk_bv_sort(ctx, 32);
    
    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();

    var expr_arena = try @import("arena.zig").ExpressionArena.init(allocator);
    defer expr_arena.deinit();

    var eval_ctx = try eval.EvaluationContext.init(allocator);
    defer eval_ctx.deinit();

    const x_id = try expr_arena.add(ast.Expr{ .variable = .x });
    const y_id = try expr_arena.add(ast.Expr{ .variable = .y });
    const z_id = try expr_arena.add(ast.Expr{ .variable = .z });
    _ = z_id;

    var num_tested: usize = 0;
    var num_failed: usize = 0;
    const NUM_ITERATIONS = 1000;

    std.debug.print("Starting Semantic Fuzzer (Z3 vs SIMD Zig)...\n", .{});

    inline for (std.meta.fields(ast.BinOp)) |field| {
        const op: ast.BinOp = @enumFromInt(field.value);
        const op_expr_id = try expr_arena.add(ast.Expr{ .binary = .{ .op = op, .lhs = x_id, .rhs = y_id } });
        const op_expr = expr_arena.get(op_expr_id);
        
        for (0..NUM_ITERATIONS) |i| {
            _ = i;
            const x_val = random.int(u32);
            const y_val = random.int(u32);
            const z_val = random.int(u32);
            
            eval_ctx.x_batches[0][0] = x_val;
            eval_ctx.y_batches[0][0] = y_val;
            eval_ctx.z_batches[0][0] = z_val;
            const zig_vec = eval.eval_batch(&eval_ctx, op_expr, &expr_arena, 0);
            const zig_res = zig_vec[0];
            
            const z3_x = z3.Z3_mk_unsigned_int(ctx, x_val, sort);
            const z3_y = z3.Z3_mk_unsigned_int(ctx, y_val, sort);
            const z3_z = z3.Z3_mk_unsigned_int(ctx, z_val, sort);
            
            const z3_ast = verify.to_z3(ctx, op_expr_id, &expr_arena, z3_x, z3_y, z3_z);
            const z3_simplified = z3.Z3_simplify(ctx, z3_ast);
            
            var z3_res: u64 = 0;
            if (z3.Z3_get_numeral_uint64(ctx, z3_simplified, &z3_res) != true) {
                std.debug.print("FAIL: Z3 failed to extract numeral for {s}\n", .{@tagName(op)});
                num_failed += 1;
                continue;
            }
            const z3_res_u32 = @as(u32, @truncate(z3_res));
            
            if (zig_res != z3_res_u32) {
                std.debug.print("SEMANTIC MISMATCH [{s}]: x={d}, y={d} | Zig={} vs Z3={}\n", .{@tagName(op), x_val, y_val, zig_res, z3_res_u32});
                num_failed += 1;
            } else {
                num_tested += 1;
            }
        }
    }
    
    inline for (std.meta.fields(ast.UnOp)) |field| {
        const op: ast.UnOp = @enumFromInt(field.value);
        const op_expr_id = try expr_arena.add(ast.Expr{ .unary = .{ .op = op, .expr = x_id } });
        const op_expr = expr_arena.get(op_expr_id);
        
        for (0..NUM_ITERATIONS) |i| {
            _ = i;
            const x_val = random.int(u32);
            
            eval_ctx.x_batches[0][0] = x_val;
            const zig_vec = eval.eval_batch(&eval_ctx, op_expr, &expr_arena, 0);
            const zig_res = zig_vec[0];
            
            const z3_x = z3.Z3_mk_unsigned_int(ctx, x_val, sort);
            const z3_y = z3.Z3_mk_unsigned_int(ctx, 0, sort);
            const z3_z = z3.Z3_mk_unsigned_int(ctx, 0, sort);
            
            const z3_ast = verify.to_z3(ctx, op_expr_id, &expr_arena, z3_x, z3_y, z3_z);
            const z3_simplified = z3.Z3_simplify(ctx, z3_ast);
            
            var z3_res: u64 = 0;
            if (z3.Z3_get_numeral_uint64(ctx, z3_simplified, &z3_res) != true) {
                std.debug.print("FAIL: Z3 failed to extract numeral for {s}\n", .{@tagName(op)});
                num_failed += 1;
                continue;
            }
            const z3_res_u32 = @as(u32, @truncate(z3_res));
            
            if (zig_res != z3_res_u32) {
                std.debug.print("SEMANTIC MISMATCH [{s}]: x={d} | Zig={} vs Z3={}\n", .{@tagName(op), x_val, zig_res, z3_res_u32});
                num_failed += 1;
            } else {
                num_tested += 1;
            }
        }
    }

    std.debug.print("\nFuzzed {} ops successfully. {} failures.\n", .{num_tested, num_failed});
    if (num_failed > 0) std.posix.exit(1);
}
