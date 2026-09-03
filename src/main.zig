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

        const ctx = eval.EvaluationContext.init();

        var db = try eval.ExpressionDatabase.init(allocator);
        defer db.deinit();

        var enumerator = try enumerate.Enumerator.init(allocator, &db, &ctx);
        defer enumerator.deinit();

        try enumerator.setup_threads(num_threads);
        try enumerator.seed_cost_0();

        for (1..max_cost + 1) |c| {
            try enumerator.orchestrate_cost(c, num_threads);
        }

        std.debug.print("Total Unique Equivalence Classes: {}\n", .{db.classes.items.len});
        std.debug.print("Total AST Nodes: {}\n", .{db.expr_arena.len});
        
        if (!verify_mode) break;

        try export_classes(&db);

        var child = std.process.Child.init(&[_][]const u8{ "python3", "scripts/verify.py" }, allocator);
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
