const std = @import("std");
const ast = @import("ast.zig");
const database = @import("database.zig");
const config = @import("config.zig");

pub fn write_expr_json(writer: anytype, expr_id: u32, arena: *const @import("arena.zig").ExpressionArena) anyerror!void {
    const expr = arena.get(expr_id);
    switch (expr) {
        .variable => |v| try writer.print("\"{s}\"", .{@tagName(v)}),
        .constant => |c| try writer.print("{d}", .{c}),
        .unary => |u| {
            try writer.print("{{\"op\": \"{s}\", \"args\": [", .{@tagName(u.op)});
            try write_expr_json(writer, u.expr, arena);
            try writer.print("]}}", .{});
        },
        .binary => |b| {
            try writer.print("{{\"op\": \"{s}\", \"args\": [", .{@tagName(b.op)});
            try write_expr_json(writer, b.lhs, arena);
            try writer.print(", ", .{});
            try write_expr_json(writer, b.rhs, arena);
            try writer.print("]}}", .{});
        },
        .select => |s| {
            try writer.print("{{\"op\": \"select\", \"args\": [", .{});
            try write_expr_json(writer, s.cond, arena);
            try writer.print(", ", .{});
            try write_expr_json(writer, s.true_val, arena);
            try writer.print(", ", .{});
            try write_expr_json(writer, s.false_val, arena);
            try writer.print("]}}", .{});
        },
    }
}

pub fn export_rewrite_rules(db: *const database.ExpressionDatabase) !void {
    const out_path = "out/classes.jsonl";
    const file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        std.debug.print("Failed to create export file {s}: {}\n", .{ out_path, err });
        return;
    };
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const writer = bw.writer();

    var num_rules: usize = 0;
    
    const allocator = std.heap.page_allocator;
    var class_members = std.AutoHashMap(u32, std.ArrayList(u32)).init(allocator);
    defer {
        var it = class_members.valueIterator();
        while (it.next()) |list| list.deinit();
        class_members.deinit();
    }

    for (db.expr_to_class.items, 0..) |cid, expr_id| {
        const class_id = @as(u32, @intCast(cid));
        const res = try class_members.getOrPut(class_id);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayList(u32).init(allocator);
        }
    try res.value_ptr.append(@as(u32, @intCast(expr_id)));
    }

    var it = class_members.iterator();
while (it.next()) |entry| {
        const list = entry.value_ptr.*;
    if (list.items.len > 1) {
            const canonical = list.items[0];
            for (list.items[1..]) |alias| {
                try writer.print("{{\"target\": ", .{});
                try write_expr_json(writer, canonical, &db.expr_arena);
                try writer.print(", \"rewrite\": ", .{});
                try write_expr_json(writer, alias, &db.expr_arena);
                try writer.print("}}\n", .{});
                num_rules += 1;
            }
        }
    }

    try bw.flush();
    std.debug.print("Successfully exported {} rewrite rules to {s}\n", .{num_rules, out_path});
}
    