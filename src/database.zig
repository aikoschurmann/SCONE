const std = @import("std");
const ast = @import("ast.zig");
const expr_arena = @import("arena.zig");
const vector_arena = @import("vector_arena.zig");
const eval = @import("eval.zig");

pub const FingerprintHash = u64;

pub const EquivalenceClass = struct {
    hash: FingerprintHash,
    canonical_expr: ast.ExprId,
};


pub const ClassId = u32;

pub const SmallClassList = union(enum) {
    inline_val: ClassId,
    dynamic: std.ArrayList(ClassId),

    pub fn init(first_val: ClassId) SmallClassList {
        return .{ .inline_val = first_val };
    }

    pub fn append(self: *SmallClassList, allocator: std.mem.Allocator, val: ClassId) !void {
        switch (self.*) {
            .inline_val => |existing_val| {
                var list = try std.ArrayList(ClassId).initCapacity(allocator, 4);
                list.appendAssumeCapacity(existing_val);
                list.appendAssumeCapacity(val);
                self.* = .{ .dynamic = list };
            },
            .dynamic => |*list| {
                try list.append(val);
            },
        }
    }

    pub fn slice(self: *const SmallClassList) []const ClassId {
        switch (self.*) {
            .inline_val => |*val| return @as(*const [1]ClassId, @ptrCast(val))[0..],
            .dynamic => |*list| return list.items,
        }
    }

    pub fn deinit(self: *SmallClassList) void {
        if (self.* == .dynamic) {
            self.dynamic.deinit();
        }
    }
};

pub const ExpressionDatabase = struct {
    allocator: std.mem.Allocator,
    
    expr_arena: expr_arena.ExpressionArena,
    expr_to_class: std.ArrayList(ClassId),
    classes: std.ArrayList(EquivalenceClass),
    fp_to_class: std.AutoHashMap(FingerprintHash, SmallClassList),
    class_vectors: vector_arena.ClassVectorArena,

    pub fn init(allocator: std.mem.Allocator, num_batches: usize) !ExpressionDatabase {
        return .{
            .allocator = allocator,
            .expr_arena = try expr_arena.ExpressionArena.init(allocator),
            .expr_to_class = blk: {
                var list = std.ArrayList(ClassId).init(allocator);
                list.ensureTotalCapacity(5_000_000) catch @panic("oom");
                break :blk list;
            },
            .classes = std.ArrayList(EquivalenceClass).init(allocator),
            .fp_to_class = std.AutoHashMap(FingerprintHash, SmallClassList).init(allocator),
            .class_vectors = try vector_arena.ClassVectorArena.init(allocator, num_batches),
        };
    }

    pub fn deinit(self: *ExpressionDatabase) void {
        var it = self.fp_to_class.valueIterator();
        while (it.next()) |list| {
            list.deinit();
        }
        self.fp_to_class.deinit();
        self.classes.deinit();
        self.expr_to_class.deinit();
        self.expr_arena.deinit();
        self.class_vectors.deinit();
    }



    };
