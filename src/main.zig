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
