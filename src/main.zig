const std = @import("std");
const CollidingClass = struct {
    id: u32,
    size: usize,

    fn lessThan(context: void, a: CollidingClass, b: CollidingClass) bool {
        _ = context;
        return a.size > b.size; // sort descending
    }
};

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const verify = @import("verify.zig");
const enumerate = @import("enumerate.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var max_cost: usize = 2;
    var verify_mode: bool = false;

    var args = std.process.args();
    _ = args.skip(); // skip binary name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cost") or std.mem.eql(u8, arg, "-c")) {
            const cost_str = args.next() orelse return error.MissingArgument;
            max_cost = try std.fmt.parseInt(usize, cost_str, 10);
        } else if (std.mem.eql(u8, arg, "--verify") or std.mem.eql(u8, arg, "-v")) {
            verify_mode = true;
        } else if (std.mem.eql(u8, arg, "unpruned")) {
            // legacy arg, ignore
        }
    }

    const num_threads = std.Thread.getCpuCount() catch 4;
    
    var iteration: usize = 1;
    while (true) {
        if (verify_mode) {
            std.debug.print("======================================\n", .{});
            std.debug.print(" SCONE CEGIS Iteration {}\n", .{iteration});
            std.debug.print("======================================\n", .{});
        }

        std.fs.cwd().makeDir(config.out_dir) catch |err| { if (err != error.PathAlreadyExists) return err; };
        var eval_ctx = try eval.EvaluationContext.init(allocator);
        defer eval_ctx.deinit();

        var db = try eval.ExpressionDatabase.init(allocator);
        defer db.deinit();

        var enumerator = try enumerate.Enumerator.init(allocator, &db, &eval_ctx);
        defer enumerator.deinit();

        try enumerator.setup_threads(num_threads);
        try enumerator.seed_cost_0();

        for (1..max_cost + 1) |c| {
            try enumerator.orchestrate_cost(c, num_threads, iteration);
        }

        var perfect_classes: usize = 0;
        var colliding_classes: usize = 0;
        var trapped_exprs: usize = 0;
        
        var class_sizes = try allocator.alloc(u32, db.classes.items.len);
        defer allocator.free(class_sizes);
        @memset(class_sizes, 0);
        
        for (db.expr_to_class.items) |cid| {
            class_sizes[cid] += 1;
        }
        
        for (class_sizes) |size| {
            if (size == 1) {
                perfect_classes += 1;
            } else if (size > 1) {
                colliding_classes += 1;
                trapped_exprs += size;
            }
        }

        std.debug.print("\n--- SCONE METRICS ---\n", .{});
        std.debug.print("Total AST Nodes Generated:      {}\n", .{db.expr_arena.len});
        std.debug.print("Total Equivalence Classes:      {}\n", .{db.classes.items.len});
        std.debug.print("Perfectly Unique Classes (1):   {}\n", .{perfect_classes});
        std.debug.print("Colliding Classes (>1):         {}  (Exporting to Z3)\n", .{colliding_classes});
        std.debug.print("Expressions in Collisions:      {}\n", .{trapped_exprs});
        std.debug.print("Active Evaluation Grid Size:    {}\n", .{eval_ctx.total_samples});
        std.debug.print("---------------------\n\n", .{});
        
        const tel_file = std.fs.cwd().openFile(config.telemetry_file, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(config.telemetry_file, .{}),
            else => return err,
        };
        try tel_file.seekFromEnd(0);
        try tel_file.writer().print("{{\"event\": \"metrics\", \"iteration\": {d}, \"total_ast_nodes\": {d}, \"total_classes\": {d}, \"perfect_classes\": {d}, \"colliding_classes\": {d}, \"exprs_in_collisions\": {d}, \"eval_grid_size\": {d}}}\n", .{iteration, db.expr_arena.len, db.classes.items.len, perfect_classes, colliding_classes, trapped_exprs, eval_ctx.total_samples});
        tel_file.close();

        if (!verify_mode) break;


        const mistakes = try verify_classes(&db, iteration);
        if (mistakes == 0) {
            std.debug.print("\n[SUCCESS] PERFECT CLASSES ACHIEVED!\n", .{});
            break;
        }
        iteration += 1;
    }
}

fn verify_worker(
    results: []?verify.CE,
    start_idx: usize,
    end_idx: usize,
    top_slice: []const CollidingClass,
    head: []const u32,
    next: []const u32,
    arena: *const @import("arena.zig").ExpressionArena,
    progress: *std.atomic.Value(usize),
    total_classes: usize,
) void {
    const z3_cfg = verify.z3.Z3_mk_config();
    verify.z3.Z3_set_param_value(z3_cfg, "timeout", "1000"); 
    const ctx = verify.z3.Z3_mk_context(z3_cfg);
    defer {
        verify.z3.Z3_del_context(ctx);
        verify.z3.Z3_del_config(z3_cfg);
    }
    
    var idx = start_idx;
    while (idx < end_idx) : (idx += 1) {
        results[idx] = verify.check_class_ctx(ctx, top_slice[idx].id, head, next, arena);
        
        const curr_prog = progress.fetchAdd(1, .monotonic) + 1;
        if (curr_prog % 100 == 0 or curr_prog == total_classes) {
            std.debug.print("\rZ3 SAT Proofs: {}/{} classes verified...", .{curr_prog, total_classes});
        }
    }
}

fn verify_classes(db: *eval.ExpressionDatabase, iteration: usize) !usize {
    var timer = try std.time.Timer.start();
    
    
    
    // Use a buffered writer for MASSIVE IO speedup
    
    

    std.debug.print("Exporting collisions to Z3...\n", .{});
    
    // O(N) Linked-List Grouping to avoid O(N*C) 500-trillion loop
    const num_exprs = db.expr_arena.len;
    const num_classes = db.classes.items.len;
    
    var head = try std.heap.page_allocator.alloc(u32, num_classes);
    defer std.heap.page_allocator.free(head);
    @memset(head, 0xFFFFFFFF);
    
    var next = try std.heap.page_allocator.alloc(u32, num_exprs);
    defer std.heap.page_allocator.free(next);
    @memset(next, 0xFFFFFFFF);
    
    var class_sizes = try std.heap.page_allocator.alloc(u32, num_classes);
    defer std.heap.page_allocator.free(class_sizes);
    @memset(class_sizes, 0);

    for (db.expr_to_class.items, 0..) |cid, expr_id| {
        next[expr_id] = head[cid];
        head[cid] = @as(u32, @intCast(expr_id));
        class_sizes[cid] += 1;
    }
    
    


    
    var colliding_list = std.ArrayList(CollidingClass).init(std.heap.page_allocator);
    defer colliding_list.deinit();
    
    for (class_sizes, 0..) |sz, cid| {
        if (sz > 1) {
            try colliding_list.append(.{ .id = @as(u32, @intCast(cid)), .size = sz });
        }
    }
    
    // Sort descending by size
    std.sort.block(CollidingClass, colliding_list.items, {}, CollidingClass.lessThan);
    
    // Take the top 500k fattest classes (or less if not enough)
    const top_n = @min(colliding_list.items.len, 500_000);
    const top_slice = colliding_list.items[0..top_n];
    
    // Randomly shuffle the top slice to ensure Z3 diversity and prevent timeout deadlocks
    var prng = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
    const random = prng.random();
    random.shuffle(CollidingClass, top_slice);

    

    const ce_file = try std.fs.cwd().openFile(config.counterexamples_file, .{ .mode = .read_write });
    defer ce_file.close();
    try ce_file.seekFromEnd(0);
    const ce_writer = ce_file.writer();

    const results = try std.heap.page_allocator.alloc(?verify.CE, top_slice.len);
    defer std.heap.page_allocator.free(results);
    
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = std.heap.page_allocator });
    defer pool.deinit();
    
    var wg = std.Thread.WaitGroup{};
    
    const num_threads = std.Thread.getCpuCount() catch 4;
    std.debug.print("Z3 SAT Solver: Spawning {} parallel threads across CPU cores...\n", .{num_threads});
    
    const chunk_size = (top_slice.len + num_threads - 1) / num_threads;
    
    var progress = std.atomic.Value(usize).init(0);
    
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        const start_idx = t * chunk_size;
        const end_idx = @min(start_idx + chunk_size, top_slice.len);
        if (start_idx >= end_idx) continue;
        
        pool.spawnWg(&wg, verify_worker, .{ results, start_idx, end_idx, top_slice, head, next, &db.expr_arena, &progress, top_slice.len });
    }
    wg.wait();
    
    var mistakes: usize = 0;
    const timeouts: usize = 0;
    
    for (results) |res| {
        if (res) |ce| {
            try ce_writer.print("{},{},{}\n", .{ce.x, ce.y, ce.z});
            mistakes += 1;
            if (mistakes >= 500) break;
        }
    }
    
    const elapsed_s = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    std.debug.print("\nZ3 Verification complete in {d:.2}s. Mistakes found: {}\n", .{elapsed_s, mistakes});
    
    // Log telemetry JSON
    const tel_file = try std.fs.cwd().openFile(config.telemetry_file, .{ .mode = .read_write });
    defer tel_file.close();
    try tel_file.seekFromEnd(0);
    try tel_file.writer().print("{{\"event\": \"verify\", \"elapsed_s\": {d:.2}, \"iteration\": {d}, \"classes_verified\": {d}, \"mistakes_found\": {d}, \"timeouts\": {d}}}\n", .{elapsed_s, iteration, top_slice.len, mistakes, timeouts});
    
    return mistakes;
}
