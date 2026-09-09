const std = @import("std");
const eval = @import("eval.zig");
const database = @import("database.zig");

inline fn fast_hash(seed: u64, val: u32) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(std.mem.asBytes(&val));
    return hasher.final();
}

pub fn distill_samples(allocator: std.mem.Allocator, db: *database.ExpressionDatabase, eval_ctx: *const eval.EvaluationContext, max_picks: usize) ![]usize {
    const num_classes = db.classes.items.len;
    var selected_samples = std.ArrayList(usize).init(allocator);
    
    var current_hashes = try allocator.alloc(u64, num_classes);
    defer allocator.free(current_hashes);
    for (0..num_classes) |i| current_hashes[i] = 0;
    
    var hash_map = std.AutoHashMap(u64, void).init(allocator);
    defer hash_map.deinit();
    try hash_map.ensureTotalCapacity(@intCast(num_classes));

    var resolved_count: usize = 0;
    
    std.debug.print("\n--- DISTILLING KILLER SAMPLES ---\n", .{});
    std.debug.print("Greedy Set Cover over {} classes and {} samples.\n", .{num_classes, eval_ctx.total_samples});
    
    while (selected_samples.items.len < max_picks) {
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
        
        const batch_idx = best_sample / eval.BATCH_SIZE;
        const lane_idx = best_sample % eval.BATCH_SIZE;
        for (0..num_classes) |class_id| {
            const vec = db.class_vectors.get(@intCast(class_id));
            const val = vec[batch_idx][lane_idx];
            current_hashes[class_id] = fast_hash(current_hashes[class_id], val);
        }
        
        std.debug.print("Pick {d}: Sample {} -> Resolves {}/{} classes ({d:.2}%)\n", .{
            selected_samples.items.len,
            best_sample,
            resolved_count,
            num_classes,
            @as(f64, @floatFromInt(resolved_count)) / @as(f64, @floatFromInt(num_classes)) * 100.0,
        });
        
        if (resolved_count == num_classes) break;
    }
    
    return selected_samples.toOwnedSlice();
}
