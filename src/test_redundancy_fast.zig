const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const database = @import("database.zig");
const enumerate = @import("enumerate.zig");

// A fast wyhash inline to avoid struct overhead
inline fn fast_hash(seed: u64, val: u32) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(std.mem.asBytes(&val));
    return hasher.final();
}

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
    
    // We only need to run Cost 1 to get a decent number of classes (e.g., 20,000+ total from cost 1 + 2)
    // Actually, running cost 2 takes 15 seconds. Let's do a fast cost 2.
    std.debug.print("Generating expressions...\n", .{});
    try enumerator.orchestrate_cost(1, 4);
    try enumerator.orchestrate_cost(2, 4);

    const num_classes = db.classes.items.len;
    std.debug.print("Baseline: {} genuine classes across {} random samples.\n", .{num_classes, eval_ctx.total_samples});
    std.debug.print("Starting ultra-fast Greedy Set Cover...\n", .{});

    var selected_samples = std.ArrayList(usize).init(allocator);
    var current_hashes = try allocator.alloc(u64, num_classes);
    for (0..num_classes) |i| current_hashes[i] = 0; // initial hash state
    
    var hash_map = std.AutoHashMap(u64, void).init(allocator);
    try hash_map.ensureTotalCapacity(@intCast(num_classes));

    var resolved_count: usize = 0;
    
    // We only greedily pick the best 10 samples to prove the point empirically
    const MAX_SAMPLES_TO_PICK = 10;

    var timer = try std.time.Timer.start();
    
    while (selected_samples.items.len < MAX_SAMPLES_TO_PICK) {
        var best_sample: usize = 0;
        var best_resolved: usize = 0;
        
        for (0..eval_ctx.total_samples) |s_idx| {
            hash_map.clearRetainingCapacity();
            
            const batch_idx = s_idx / eval.BATCH_SIZE;
            const lane_idx = s_idx % eval.BATCH_SIZE;
            
            for (0..num_classes) |class_id| {
                const vec = db.class_vectors.get(@intCast(class_id));
                const val = vec[batch_idx][lane_idx];
                
                const new_hash = fast_hash(current_hashes[class_id], val);
                hash_map.putAssumeCapacity(new_hash, {});
            }
            
            const count = hash_map.count();
            if (count > best_resolved) {
                best_resolved = count;
                best_sample = s_idx;
            }
        }
        
        try selected_samples.append(best_sample);
        resolved_count = best_resolved;
        
        // Commit the best sample to current_hashes
        const batch_idx = best_sample / eval.BATCH_SIZE;
        const lane_idx = best_sample % eval.BATCH_SIZE;
        for (0..num_classes) |class_id| {
            const vec = db.class_vectors.get(@intCast(class_id));
            const val = vec[batch_idx][lane_idx];
            current_hashes[class_id] = fast_hash(current_hashes[class_id], val);
        }
        
        std.debug.print("Greedy Pick {d}: Sample {} -> Resolves {}/{} classes ({d:.2}%) in {} ms\n", .{
            selected_samples.items.len,
            best_sample,
            resolved_count,
            num_classes,
            @as(f64, @floatFromInt(resolved_count)) / @as(f64, @floatFromInt(num_classes)) * 100.0,
            timer.read() / 1_000_000,
        });
        timer.reset();
        
        if (resolved_count == num_classes) break;
    }
}
