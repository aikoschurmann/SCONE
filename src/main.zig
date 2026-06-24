const std = @import("std");
const ast = @import("ast.zig");
const arena = @import("arena.zig");
const eval = @import("eval.zig");
// const Enumerator = @import("enumerate.zig");

pub fn main() !void {
    std.debug.print("SCONE Enumerator Initialized.\n", .{});
    std.debug.print("Run `zig test src/main.zig` to execute the test suite.\n", .{});
}

// ==========================================
// TEST SUITE
// ==========================================

test "ExpressionArena stores and retrieves nodes" {
    // std.testing.allocator will panic if we forget to call deinit()
    var expr_arena = try arena.ExpressionArena.init(std.testing.allocator, 10);
    defer expr_arena.deinit();

    // Add some test expressions
    const id1 = try expr_arena.add(.{ .constant = 42 });
    const id2 = try expr_arena.add(.{ .variable = .x });
    const id3 = try expr_arena.add(.{ .binary = .{ .op = .add, .lhs = id1, .rhs = id2 } });

    // Verify the IDs are sequential
    try std.testing.expectEqual(@as(ast.ExprId, 0), id1);
    try std.testing.expectEqual(@as(ast.ExprId, 1), id2);
    try std.testing.expectEqual(@as(ast.ExprId, 2), id3);

    // Verify the retrieved data matches
    const retrieved = expr_arena.get(id3);
    try std.testing.expectEqual(ast.BinOp.add, retrieved.binary.op);
    try std.testing.expectEqual(id1, retrieved.binary.lhs);
}

test "SmallClassList safely upgrades to dynamic memory" {
    // 1. Test the inline (zero-allocation) state
    var list = eval.SmallClassList.init(999);
    // Even if we call deinit on an inline val, it shouldn't crash
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.slice().len);
    try std.testing.expectEqual(@as(eval.ClassId, 999), list.slice()[0]);

    // 2. Trigger the collision upgrade (forces a heap allocation)
    try list.append(std.testing.allocator, 1000);
    try list.append(std.testing.allocator, 1001);

    // 3. Verify it holds all 3 items properly
    const result_slice = list.slice();
    try std.testing.expectEqual(@as(usize, 3), result_slice.len);
    try std.testing.expectEqual(@as(eval.ClassId, 999), result_slice[0]);
    try std.testing.expectEqual(@as(eval.ClassId, 1001), result_slice[2]);

    // When the test ends, `defer list.deinit()` will run.
    // If it fails to free the dynamic array, the testing allocator will catch the leak.
}

test "EvaluationContext generates Smart Seeds properly" {
    var prng = std.rand.DefaultPrng.init(12345);
    const ctx = eval.EvaluationContext.init(prng.random());

    // Check Lane 0 (Should be 0, with +1 and +2 offsets for y and z)
    try std.testing.expectEqual(@as(u32, 0), ctx.x_samples[0]);
    try std.testing.expectEqual(@as(u32, 1), ctx.y_samples[0]);
    try std.testing.expectEqual(@as(u32, 2), ctx.z_samples[0]);

    // Check Lane 9 (Should be 0xFFFFFFFF / -1)
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), ctx.x_samples[9]);
    try std.testing.expectEqual(@as(u32, 0), ctx.y_samples[9]); // 0xFFFFFFFF + 1 wraps to 0
    try std.testing.expectEqual(@as(u32, 1), ctx.z_samples[9]); // 0xFFFFFFFF + 2 wraps to 1
}

test "ExpressionDatabase initializes and frees without leaking" {
    // We pass a tiny expected count just to test the initialization logic
    var db = try eval.ExpressionDatabase.init(std.testing.allocator, 5, 5);
    defer db.deinit();

    try std.testing.expect(db.expr_arena.nodes.capacity == 5);
}

test "evaluator: Constants and Variables" {
    var db = try eval.ExpressionDatabase.init(std.testing.allocator, 10, 10);
    defer db.deinit();

    var prng = std.rand.DefaultPrng.init(123);
    const ctx = eval.EvaluationContext.init(prng.random());

    // 1. Test Constant Evaluator
    const const_expr = ast.Expr{ .constant = 42 };
    const const_fp = db.eval(&ctx, const_expr);

    // Check that lane 0 and lane 63 both successfully splatted '42'
    try std.testing.expectEqual(@as(u32, 42), const_fp.output[0]);
    try std.testing.expectEqual(@as(u32, 42), const_fp.output[63]);

    // 2. Test Variable Evaluator
    const var_expr = ast.Expr{ .variable = .y };
    const var_fp = db.eval(&ctx, var_expr);

    // Check that it perfectly copied the `y_samples` vector from the context
    try std.testing.expectEqual(ctx.y_samples[0], var_fp.output[0]);
    try std.testing.expectEqual(ctx.y_samples[15], var_fp.output[15]);
}

test "evaluator: Binary Operations (SIMD addition)" {
    var db = try eval.ExpressionDatabase.init(std.testing.allocator, 10, 10);
    defer db.deinit();

    var prng = std.rand.DefaultPrng.init(123);
    const ctx = eval.EvaluationContext.init(prng.random());

    // MOCKING DATA:
    // Because the evaluator looks up the children's fingerprints from the database,
    // we need to manually insert two dummy classes into the database for the test.

    // ExprId 0 maps to ClassId 0 (Holds an array of 10s)
    try db.expr_to_class.append(0);
    try db.classes.append(.{
        .fingerprint = .{ .output = @splat(10) },
        .canonical_expr = 0,
    });

    // ExprId 1 maps to ClassId 1 (Holds an array of 25s)
    try db.expr_to_class.append(1);
    try db.classes.append(.{
        .fingerprint = .{ .output = @splat(25) },
        .canonical_expr = 1,
    });

    // Create an expression: ADD(Expr 0, Expr 1)
    const add_expr = ast.Expr{ .binary = .{ .op = .add, .lhs = 0, .rhs = 1 } };

    // Evaluate it!
    const result_fp = db.eval(&ctx, add_expr);

    // 10 + 25 should equal 35 across all 64 lanes
    try std.testing.expectEqual(@as(u32, 35), result_fp.output[0]);
    try std.testing.expectEqual(@as(u32, 35), result_fp.output[63]);
}

test "evaluator: The Sign Bit Proof (ult vs slt)" {
    var db = try eval.ExpressionDatabase.init(std.testing.allocator, 10, 10);
    defer db.deinit();

    var prng = std.rand.DefaultPrng.init(123);
    const ctx = eval.EvaluationContext.init(prng.random());

    // MOCKING DATA:
    // ExprId 0: The sequence 0xFFFFFFFF (-1 signed, or 4.29 Billion unsigned)
    try db.expr_to_class.append(0);
    try db.classes.append(.{
        .fingerprint = .{ .output = @splat(0xFFFFFFFF) },
        .canonical_expr = 0,
    });

    // ExprId 1: The sequence 0x00000000 (Zero)
    try db.expr_to_class.append(1);
    try db.classes.append(.{
        .fingerprint = .{ .output = @splat(0) },
        .canonical_expr = 1,
    });

    // --- TEST UNSIGNED LESS THAN (ult) ---
    // Is 4.29 Billion < 0? No (False/0).
    const ult_expr = ast.Expr{ .binary = .{ .op = .ult, .lhs = 0, .rhs = 1 } };
    const ult_fp = db.eval(&ctx, ult_expr);
    try std.testing.expectEqual(@as(u32, 0), ult_fp.output[0]);

    // --- TEST SIGNED LESS THAN (slt) ---
    // Is -1 < 0? Yes (True/1).
    const slt_expr = ast.Expr{ .binary = .{ .op = .slt, .lhs = 0, .rhs = 1 } };
    const slt_fp = db.eval(&ctx, slt_expr);
    try std.testing.expectEqual(@as(u32, 1), slt_fp.output[0]);
}
