const std = @import("std");
const ast = @import("ast.zig");
const arena = @import("arena.zig");
const eval = @import("eval.zig");
const enumerate = @import("enumerate.zig");
const Enumerator = enumerate.Enumerator;

pub fn main() !void {
    std.debug.print("SCONE Enumerator Initialized.\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.rand.DefaultPrng.init(12345);
    const ctx = eval.EvaluationContext.init(prng.random());

    // Allocate DB with enough capacity for Cost 2
    var db = try eval.ExpressionDatabase.init(allocator, 5_000_000, 1_000_000);
    defer db.deinit();

    var enumerator = try Enumerator.init(allocator, &db, &ctx);
    defer enumerator.deinit();

    const num_threads = std.Thread.getCpuCount() catch 4;
    try enumerator.setup_threads(num_threads);

    const start_time = std.time.milliTimestamp();

    // Cost 0
    try enumerator.seed_cost_0();
    std.debug.print("Cost 0: {} classes (Time: {} ms)\n", .{ enumerator.exprs_by_cost.items[0].items.len, std.time.milliTimestamp() - start_time });

    // Cost 1
    const t1 = std.time.milliTimestamp();
    try enumerator.orchestrate_cost(1, num_threads);
    std.debug.print("Cost 1: {} classes (Time: {} ms)\n", .{ enumerator.exprs_by_cost.items[1].items.len, std.time.milliTimestamp() - t1 });

    // Cost 2
    const t2 = std.time.milliTimestamp();
    try enumerator.orchestrate_cost(2, num_threads);
    std.debug.print("Cost 2: {} classes (Time: {} ms)\n", .{ enumerator.exprs_by_cost.items[2].items.len, std.time.milliTimestamp() - t2 });

    const end_time = std.time.milliTimestamp();
    std.debug.print("Total Time: {} ms\n", .{ end_time - start_time });
    std.debug.print("Total Unique Equivalence Classes: {}\n", .{ db.classes.items.len });
    std.debug.print("Total AST Nodes: {}\n", .{ db.expr_arena.nodes.items.len });
}
