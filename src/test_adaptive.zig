const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const database = @import("database.zig");
const enumerate = @import("enumerate.zig");
const config = @import("config.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var eval_ctx = try eval.EvaluationContext.init(allocator);
    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();
    for (0..eval_ctx.total_samples) |i| {
        eval_ctx.setSample(i, random.int(u32), random.int(u32), random.int(u32));
    }

    var db = try database.ExpressionDatabase.init(allocator, eval_ctx.num_batches);
    var enumerator = try enumerate.Enumerator.init(allocator, &db, &eval_ctx);

    try enumerator.setup_threads(4);
    try enumerator.seed_cost_0();

    std.debug.print("Running Cost 1...\n", .{});
    try enumerator.orchestrate_cost(1, 4);
    std.debug.print("Running Cost 2...\n", .{});
    try enumerator.orchestrate_cost(2, 4);

    const num_classes = db.classes.items.len;
    std.debug.print("Generated {} genuine classes using {} samples.\n", .{num_classes, eval_ctx.total_samples});

    const batch_sizes = [_]usize{ 1, 2, 4, 8 }; 
    
    for (batch_sizes) |batches_to_use| {
        var small_hash_map = std.AutoHashMap(u128, void).init(allocator);
        var collisions: usize = 0;
        
        for (0..num_classes) |class_id| {
            const vec = db.class_vectors.get(@intCast(class_id));
            const sub_vec = vec[0..batches_to_use];
            const hash = eval.hash_vectors(sub_vec);
            
            const gop = try small_hash_map.getOrPut(hash);
            if (gop.found_existing) {
                collisions += 1;
            }
        }
        
        std.debug.print("Using {d} samples (Fast Grid): Unique Classes: {d} | Collisions: {d} ({d:.2}% resolved)\n", .{
            batches_to_use * 64,
            small_hash_map.count(),
            collisions,
            @as(f64, @floatFromInt(small_hash_map.count())) / @as(f64, @floatFromInt(num_classes)) * 100.0,
        });
        small_hash_map.deinit();
    }
}
