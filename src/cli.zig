const std = @import("std");
const Config = @import("config.zig").Config;

pub fn parseArgs(allocator: std.mem.Allocator) !struct { max_cost: usize, threads: usize } {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip executable name

    var config = @import("config.zig").active;
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
            config.enable_select = false;
        } else if (std.mem.eql(u8, arg, "--perf")) {
            config.is_perf_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-unary")) {
            config.enable_unary = false;
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            config.use_pruning = false;
        } else if (std.mem.eql(u8, arg, "--ce-limit")) {
            const val = args.next() orelse return error.MissingArgument;
            config.max_counterexamples_per_iter = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--z3-timeout")) {
            const val = args.next() orelse return error.MissingArgument;
            config.z3_timeout_ms = try std.fmt.parseInt(u32, val, 10);
        }
    }

    @import("config.zig").active = config;
    return .{ .max_cost = max_cost, .threads = threads };
}
