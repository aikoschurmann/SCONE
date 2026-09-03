const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const enumerate = @import("enumerate.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = eval.EvaluationContext.init();

    // Initialize DB (ExpressionArena is segmented lock-free, HashMaps grow dynamically)
    var db = try eval.ExpressionDatabase.init(allocator);
    defer db.deinit();

    var enumerator = try enumerate.Enumerator.init(allocator, &db, &ctx);
    defer enumerator.deinit();

    const num_threads = std.Thread.getCpuCount() catch 4;
    try enumerator.setup_threads(num_threads);

    std.debug.print("SCONE Enumerator Initialized.\n", .{});

    try enumerator.seed_cost_0();

    // We only go up to Cost 2 for quick verification unless running a full bench
    try enumerator.orchestrate_cost(1, num_threads);
    try enumerator.orchestrate_cost(2, num_threads);
    // try enumerator.orchestrate_cost(3, num_threads);

    std.debug.print("Total Unique Equivalence Classes: {}\n", .{db.classes.items.len});
    std.debug.print("Total AST Nodes: {}\n", .{db.expr_arena.len});
    // Export classes for Z3 verification
    try export_classes(&db);
}

fn export_classes(db: *eval.ExpressionDatabase) !void {
    var out_file = try std.fs.cwd().createFile(config.verification_export_file, .{});
    defer out_file.close();
    var writer = out_file.writer();

    var exported: usize = 0;
    for (db.classes.items, 0..) |_, class_id_usize| {
        const class_id: u32 = @intCast(class_id_usize);
        var exprs = std.ArrayList(u32).init(std.heap.page_allocator);
        defer exprs.deinit();

        for (db.expr_to_class.items, 0..) |cid, expr_id| {
            if (cid == class_id) {
                try exprs.append(@intCast(expr_id));
            }
        }

        if (exprs.items.len > 1) {
            try writer.print("Class {}:\n", .{class_id});
            for (exprs.items) |expr_id| {
                try ast.format_expr(@intCast(expr_id), &db.expr_arena, writer);
                try writer.writeAll("\n");
            }
            try writer.writeAll("\n");
            exported += 1;
        }

        // Only export first N interesting classes to avoid massive files
        if (exported >= config.max_classes_to_export) break;
    }
    std.debug.print("Exported {} classes with collisions to classes.txt for Z3 verification.\n", .{exported});
}
