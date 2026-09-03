const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
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

        try export_classes(&db);

        var iter_str_buf: [32]u8 = undefined;
        const iter_str = std.fmt.bufPrint(&iter_str_buf, "{d}", .{iteration}) catch "1";
        var child = std.process.Child.init(&[_][]const u8{ "python3", "scripts/verify.py", iter_str }, allocator);
        try child.spawn();
        const term = try child.wait();
        
        if (term == .Exited and term.Exited == 0) {
            std.debug.print("\n[SUCCESS] PERFECT CLASSES ACHIEVED!\n", .{});
            break;
        }
        iteration += 1;
    }
}

fn export_classes(db: *eval.ExpressionDatabase) !void {
    var out_file = try std.fs.cwd().createFile(config.verification_export_file, .{});
    defer out_file.close();
    
    // Use a buffered writer for MASSIVE IO speedup
    var buf_writer = std.io.bufferedWriter(out_file.writer());
    var writer = buf_writer.writer();

    std.debug.print("Grouping expressions for export (O(N) pass)... ", .{});
    
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
    
    std.debug.print("Done. Sorting and randomizing for Hybrid Export...\n", .{});

    const CollidingClass = struct {
        id: u32,
        size: u32,
        
        pub fn lessThan(context: void, a: @This(), b: @This()) bool {
            _ = context;
            return a.size > b.size; // Descending sort (Fattest First)
        }
    };
    
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

    std.debug.print("Done. Exporting classes...\n", .{});

    var exported: usize = 0;
    for (top_slice) |cc| {
        try writer.print("Class {}:\n", .{cc.id});
        
        var curr: u32 = head[cc.id];
        while (curr != 0xFFFFFFFF) {
            try ast.format_expr(curr, &db.expr_arena, writer);
            try writer.writeAll("\n");
            curr = next[curr];
        }
        try writer.writeAll("\n");
        exported += 1;

        if (exported >= config.max_classes_to_export) break;
    }
    
    try buf_writer.flush();
    std.debug.print("Exported {} classes with collisions to classes.txt for Z3 verification.\n", .{exported});
}
