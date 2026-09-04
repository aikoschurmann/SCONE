const std = @import("std");


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


        const mistakes = try verify.verify_classes(&db, iteration);
        if (mistakes == 0) {
            std.debug.print("\n[SUCCESS] PERFECT CLASSES ACHIEVED!\n", .{});
            break;
        }
        iteration += 1;
    }
}




