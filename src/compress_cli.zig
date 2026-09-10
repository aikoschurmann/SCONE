const std = @import("std");
const eval = @import("eval.zig");
const ast = @import("ast.zig");
const database = @import("database.zig");
const sqlite_db = @import("sqlite_db.zig");
const distill = @import("distill.zig");
const enumerate = @import("enumerate.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sqlite = try sqlite_db.SqliteDb.init("scone.db");
    defer sqlite.deinit();
    var eval_ctx = try eval.EvaluationContext.init(allocator, &sqlite);
    var db = try database.ExpressionDatabase.init(allocator, eval_ctx.num_batches);

    const max_cost = try sqlite.load_state(&db);
    if (max_cost == 0) {
        std.debug.print("No database found!\n", .{});
        return;
    }
    
    std.debug.print("\nLoaded database with {d} classes across {d} samples.\n", .{db.classes.items.len, eval_ctx.total_samples});
    std.debug.print("Recomputing deep vectors in RAM...\n", .{});
    
    var enumerator = try enumerate.Enumerator.init(allocator, &db, &eval_ctx);
    enumerator.recompute_worker(0, db.classes.items.len);
    
    const max_picks = 128;
    const killer_samples = try distill.distill_samples(allocator, &db, &eval_ctx, max_picks);
    try sqlite.replace_ces(killer_samples, &eval_ctx);
    std.debug.print("\nDistillation Complete. Saved {} Killer Samples to scone.db!\n", .{killer_samples.len});
}
