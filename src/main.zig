const std = @import("std");
const Enumerator = @import("enumerate.zig");

pub fn main() !void {
    std.debug.print("Hello, {s}!\n", .{"World"});
}
