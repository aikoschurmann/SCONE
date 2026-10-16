const std = @import("std");
const Config = @import("config.zig").Config;
const config = @import("config.zig");
const ast = @import("ast.zig");

/// Binary ops kept by `--lite`: cheap bitvector ops that Z3 decides quickly.
const lite_binops = [_]ast.BinOp{ .add, .sub, .and_op, .or_op, .xor, .shl, .lshr };
/// Constants kept by `--lite`.
const lite_consts = [_]u32{ 0, 1, 0xFFFFFFFF };

/// Parses a comma-separated list of enum tag names (e.g. "add,xor,shl") into a bit mask.
fn parseOpMask(comptime Op: type, list: []const u8) !u32 {
    var mask: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |name| {
        const op = std.meta.stringToEnum(Op, name) orelse {
            std.debug.print("Unknown {s} '{s}'. Valid: ", .{ @typeName(Op), name });
            inline for (@typeInfo(Op).Enum.fields) |f| std.debug.print("{s} ", .{f.name});
            std.debug.print("\n", .{});
            return error.InvalidArgument;
        };
        mask |= @as(u32, 1) << @intFromEnum(op);
    }
    return mask;
}

/// Parses a comma-separated list of constants (decimal or 0x hex) into a mask over search_constants.
fn parseConstMask(list: []const u8) !u32 {
    var mask: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |tok| {
        const v = try std.fmt.parseInt(u32, tok, 0);
        const idx = std.mem.indexOfScalar(u32, &config.search_constants, v) orelse {
            std.debug.print("Constant {s} is not in search_constants\n", .{tok});
            return error.InvalidArgument;
        };
        mask |= @as(u32, 1) << @intCast(idx);
    }
    return mask;
}

pub fn parseArgs(allocator: std.mem.Allocator) !struct { max_cost: usize, threads: usize } {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip executable name

    var max_cost: usize = 3;
    var threads: usize = 0; // 0 = auto

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cost")) {
            const val = args.next() orelse return error.MissingArgument;
            max_cost = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            const val = args.next() orelse return error.MissingArgument;
            threads = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--no-select")) {
            config.active.enable_select = false;
        } else if (std.mem.eql(u8, arg, "--clean")) {
            config.active.clean_db = true;
        } else if (std.mem.eql(u8, arg, "--distill-ces")) {
            config.active.distill_ces = true;
        } else if (std.mem.eql(u8, arg, "--no-unary")) {
            config.active.enable_unary = false;
        } else if (std.mem.eql(u8, arg, "--lite")) {
            // Small search space for fast soundness testing; later flags can override parts of it.
            config.active.enable_select = false;
            config.active.enable_unary = false;
            config.active.binop_mask = 0;
            for (lite_binops) |op| config.active.binop_mask |= @as(u32, 1) << @intFromEnum(op);
            config.active.const_mask = 0;
            for (lite_consts) |c| config.active.const_mask |= @as(u32, 1) << @intCast(std.mem.indexOfScalar(u32, &config.search_constants, c).?);
        } else if (std.mem.eql(u8, arg, "--binops")) {
            config.active.binop_mask = try parseOpMask(ast.BinOp, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--unops")) {
            config.active.enable_unary = true;
            config.active.unop_mask = try parseOpMask(ast.UnOp, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--consts")) {
            config.active.const_mask = try parseConstMask(args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            config.active.use_pruning = false;
        } else if (std.mem.eql(u8, arg, "--uniform-random")) {
            config.active.uniform_random_samples = true;
        } else if (std.mem.eql(u8, arg, "--z3-timeout")) {
            const val = args.next() orelse return error.MissingArgument;
            config.active.z3_timeout_ms = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--no-absint")) {
            config.active.use_absint = false;
        } else if (std.mem.eql(u8, arg, "--audit-absint")) {
            const val = args.next() orelse return error.MissingArgument;
            config.active.audit_absint = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--audit-normalize")) {
            const val = args.next() orelse return error.MissingArgument;
            config.active.audit_normalize = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--cartesian")) {
            config.active.use_cartesian_grid = true;
        } else if (std.mem.eql(u8, arg, "--random-samples")) {
            const val = args.next() orelse return error.MissingArgument;
            config.active.num_random_samples = try std.fmt.parseInt(usize, val, 10);
        } else {
            std.debug.print("Unknown option '{s}'. Options: -c/--cost N, -t/--threads N, --lite, --no-select, --no-unary, " ++
                "--binops LIST, --unops LIST, --consts LIST, --z3-timeout MS, --no-absint, --audit-absint N, " ++
                "--audit-normalize N, --distill-ces, --clean, --no-prune, --uniform-random, --cartesian, --random-samples N\n", .{arg});
            return error.InvalidArgument;
        }
    }

    return .{ .max_cost = max_cost, .threads = threads };
}
