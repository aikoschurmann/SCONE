const std = @import("std");
const ast = @import("ast.zig");

/// A contiguous memory block for storing all generated expressions.
/// Complex expressions are built by referencing the `ExprId` of existing
/// sub-expressions, avoiding per-node heap allocations.
pub const ExpressionArena = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(ast.Expr),

    /// Initializes the arena with a pre-allocated capacity.
    /// Returns an OutOfMemory error (!) if the OS denies the allocation.
    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) !ExpressionArena {
        return .{
            .allocator = allocator,
            .nodes = try std.ArrayList(ast.Expr).initCapacity(allocator, initial_capacity),
        };
    }

    /// Safely frees all memory allocated by the arena.
    pub fn deinit(self: *ExpressionArena) void {
        self.nodes.deinit();
    }

    /// Appends a new expression and returns its index.
    /// Returns an OutOfMemory error (!) if the array needs to grow and RAM is exhausted.
    pub fn add(self: *ExpressionArena, expr: ast.Expr) !ast.ExprId {
        const id = @as(ast.ExprId, @intCast(self.nodes.items.len));
        try self.nodes.append(expr);
        return id;
    }

    /// Retrieves an expression by its index.
    pub fn get(self: *const ExpressionArena, id: ast.ExprId) ast.Expr {
        return self.nodes.items[id];
    }
};
