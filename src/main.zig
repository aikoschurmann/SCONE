const std = @import("std");


const ast = @import("ast.zig");
const eval = @import("eval.zig");
const database = @import("database.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const telemetry = @import("telemetry.zig");
const verify = @import("verify.zig");
const enumerate = @import("enumerate.zig");


fn sigintHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    const msg = "\nCaught SIGINT (Ctrl+C). Terminating forcefully...\n";
    _ = std.posix.write(2, msg) catch {};
    std.posix.exit(1);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);

    const parsed_args = try cli.parseArgs(allocator);
    const max_cost = parsed_args.max_cost;
    const num_threads = if (parsed_args.threads == 0) std.Thread.getCpuCount() catch 4 else parsed_args.threads;
    const verify_mode = true; // Always verify if we are running the CEGIS loop
    
    var proven_cache = std.AutoHashMap(u64, void).init(allocator);
    defer proven_cache.deinit();
    var iteration: usize = 1;
    while (true) {
        if (verify_mode) {
            std.debug.print("======================================\n", .{});
            std.debug.print(" SCONE CEGIS Iteration {}\n", .{iteration});
            std.debug.print("======================================\n", .{});
        }

        std.fs.cwd().makeDir(config.active.out_dir) catch |err| { if (err != error.PathAlreadyExists) return err; };
        var eval_ctx = try eval.EvaluationContext.init(allocator);
        defer eval_ctx.deinit();

        var db = try database.ExpressionDatabase.init(allocator, eval_ctx.num_batches);
        defer db.deinit();

        var enumerator = try enumerate.Enumerator.init(allocator, &db, &eval_ctx);
        defer enumerator.deinit();

        try enumerator.setup_threads(num_threads);
        try enumerator.seed_cost_0();

        const enum_start = std.time.milliTimestamp();
        for (1..max_cost + 1) |c| {
            try enumerator.orchestrate_cost(c, num_threads, iteration);
        }
        const enum_end = std.time.milliTimestamp();
        const enum_elapsed_s = @as(f64, @floatFromInt(enum_end - enum_start)) / 1000.0;
        const total_exprs = db.expr_arena.len;
        _ = if (enum_elapsed_s > 0) @as(f64, @floatFromInt(total_exprs)) / enum_elapsed_s else 0;

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
        
        var tel = try telemetry.Telemetry.init(config.active.telemetry_file);
        try tel.logMetrics(iteration, db.expr_arena.len, db.classes.items.len, perfect_classes, colliding_classes, trapped_exprs, eval_ctx.total_samples);
        tel.deinit();

        if (!verify_mode) break;


        const verify_start = std.time.milliTimestamp();
        const res = try verify.verify_classes(&db, iteration, &proven_cache, num_threads);
        const verify_end = std.time.milliTimestamp();
        const verify_elapsed_s = @as(f64, @floatFromInt(verify_end - verify_start)) / 1000.0;
        _ = if (verify_elapsed_s > 0) @as(f64, @floatFromInt(colliding_classes)) / verify_elapsed_s else 0;
        
        if (config.active.is_perf_mode) {
            const total_point_evals = total_exprs * eval_ctx.total_samples;
            const eval_ops_per_sec = if (enum_elapsed_s > 0) @as(f64, @floatFromInt(total_point_evals)) / enum_elapsed_s else 0;
            const verify_exprs_per_sec = if (verify_elapsed_s > 0) @as(f64, @floatFromInt(trapped_exprs)) / verify_elapsed_s else 0;
            
            std.debug.print("\n======================================\n", .{});
            std.debug.print("          SCONE PERF SUMMARY          \n", .{});
            std.debug.print("======================================\n", .{});
            std.debug.print("Enumeration Throughput: {d:.1} Eval Ops/sec (Grid Points/sec)\n", .{eval_ops_per_sec});
            std.debug.print("Verification Throughput: {d:.1} Z3 Eq-Checks/sec\n", .{verify_exprs_per_sec});
            std.debug.print("======================================\n", .{});
            break;
        }
        
        if (res.mistakes == 0 and res.timeouts == 0) {
            std.debug.print("\n[SUCCESS] PERFECT CLASSES ACHIEVED!\n", .{});
            break;
        } else if (res.mistakes == 0 and res.timeouts > 0) {
            std.debug.print("\n[WARNING] 0 mistakes, but {d} timeouts remaining. Engine must retry with longer timeout or skip.\n", .{res.timeouts});
            break; // Temporary: just break so we don't infinite loop if it's stuck on timeouts
        }
        iteration += 1;
    }
}




