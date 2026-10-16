const std = @import("std");
const clib = @cImport({
    @cInclude("time.h");
});

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const distill = @import("distill.zig");
const database = @import("database.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const verify = @import("verify.zig");
const enumerate = @import("enumerate.zig");

fn sigintHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    const msg = "\nCaught SIGINT (Ctrl+C). Terminating forcefully...\n";
    _ = std.posix.write(2, msg) catch {};
    std.posix.exit(1);
}

extern "c" fn pthread_set_qos_class_self_np(qos_class: c_int, relative_priority: c_int) c_int;

pub fn main() !void {
    if (@import("builtin").os.tag == .macos) {
        _ = pthread_set_qos_class_self_np(0x21, 0); // QOS_CLASS_USER_INTERACTIVE
    }
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
    if (config.active.clean_db) {
        std.debug.print("Wiping existing scone.db database (--clean)...\n", .{});
        std.fs.cwd().deleteFile("scone.db") catch |err| {
            if (err != error.FileNotFound) return err;
        };
        std.fs.cwd().deleteFile("scone.db-shm") catch |err| {
            if (err != error.FileNotFound) return err;
        };
        std.fs.cwd().deleteFile("scone.db-wal") catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    var sqlite = try @import("sqlite_db.zig").SqliteDb.init("scone.db");
    defer sqlite.deinit();

    // The grid is rebuilt whenever Z3 adds counterexamples, so it lives on the page allocator.
    var eval_ctx = try eval.EvaluationContext.init(std.heap.page_allocator, &sqlite);
    defer eval_ctx.deinit();
    var db = try database.ExpressionDatabase.init(allocator, eval_ctx.num_batches);

    const start_cost = try sqlite.load_state(&db);

    var enumerator = try enumerate.Enumerator.init(allocator, &db, &eval_ctx);
    try enumerator.setup_threads(num_threads);

    if (start_cost == 0) {
        try sqlite.reset_state();
        try enumerator.seed_cost_0();
        try sqlite.save_level(&db, 0, 0, 0);
    } else {
        for (0..start_cost + 1) |_| {
            try enumerator.exprs_by_cost.append(std.ArrayList(ast.ExprId).init(allocator));
        }
        for (db.classes.items) |cls| {
            const expr_id = cls.canonical_expr;
            try enumerator.exprs_by_cost.items[ast.compute_cost(&db, expr_id)].append(expr_id);
        }
        // The grid now includes any counterexamples added since the save, so stored hashes are stale.
        try enumerator.rebuild_vectors(num_threads);
    }

    // Each level is built from exact lower levels, verified once (splitting classes in place on
    // counterexamples), and saved before the next level is built from it.
    for (start_cost + 1..max_cost + 1) |c| {
        std.debug.print("======================================\n", .{});
        std.debug.print(" SCONE cost level {}\n", .{c});
        std.debug.print("======================================\n", .{});

        const first_expr = db.expr_arena.len;
        const first_class = db.classes.items.len;

        // Vectors of the last level are only ever read by the next level or by the distiller.
        const need_vectors = c < max_cost or config.active.distill_ces;
        enumerator.materialize = need_vectors;

        const enum_start = std.time.milliTimestamp();
        try enumerator.orchestrate_cost(c, num_threads);
        const enum_elapsed_s = @as(f64, @floatFromInt(std.time.milliTimestamp() - enum_start)) / 1000.0;
        const classes_before_verify = db.classes.items.len;

        const verify_start = std.time.milliTimestamp();
        const res = try verify.verify_level(allocator, &db, first_expr, num_threads);
        const verify_elapsed_s = @as(f64, @floatFromInt(std.time.milliTimestamp() - verify_start)) / 1000.0;

        for (res.new_canonicals) |e| {
            try enumerator.exprs_by_cost.items[ast.compute_cost(&db, e)].append(e);
        }

        if (res.ces.len > 0) {
            try sqlite.append_ces(res.ces);
            if (need_vectors) {
                eval_ctx.deinit();
                eval_ctx = try eval.EvaluationContext.init(std.heap.page_allocator, &sqlite);
                try enumerator.rebuild_vectors(num_threads);
            }
        }

        try sqlite.save_level(&db, first_expr, first_class, c);

        std.debug.print("\n--- COST {} SUMMARY ---\n", .{c});
        std.debug.print("Expressions built:              {} ({d:.2}s)\n", .{ db.expr_arena.len - first_expr, enum_elapsed_s });
        std.debug.print("Classes from fingerprints:      {}\n", .{classes_before_verify - first_class});
        std.debug.print("Classes after Z3 splits:        {} (+{})\n", .{ db.classes.items.len - first_class, res.new_canonicals.len });
        std.debug.print("Total classes:                  {}\n", .{db.classes.items.len});
        std.debug.print("Z3: {} exprs in {} classes, {d:.2}s, {} counterexamples\n", .{ res.exprs_checked, res.classes_checked, verify_elapsed_s, res.ces.len });
        if (res.unverified_classes > 0) {
            std.debug.print("[WARNING] {} groups timed out even after retries; their classes are saved with status 'unverified'.\n", .{res.unverified_classes});
        }
        std.debug.print("Sample grid size:               {}\n", .{eval_ctx.total_samples});
        std.debug.print("-----------------------\n\n", .{});
    }

    if (config.active.distill_ces) {
        const killer_samples = try distill.distill_samples(allocator, &db, &eval_ctx, 128);
        try sqlite.replace_ces(killer_samples, &eval_ctx);
        std.debug.print("Exported {} killer samples to SQLite!\n", .{killer_samples.len});
    }
}
