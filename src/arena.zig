const std = @import("std");
const ast = @import("ast.zig");

/// A contiguous memory block for storing all generated expressions.
/// Complex expressions are built by referencing the `ExprId` of existing
/// sub-expressions, avoiding per-node heap allocations.
pub const ExpressionArena = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(ast.Expr),

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) ExpressionArena {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(ast.Expr).initCapacity(allocator, initial_capacity) catch unreachable,
        };
    }

    /// Appends a new expression and returns its index.
    pub fn add(self: *ExpressionArena, expr: ast.Expr) ast.ExprId {
        const id = @as(ast.ExprId, @intCast(self.nodes.items.len));
        self.nodes.append(expr) catch unreachable;
        return id;
    }

    /// Retrieves an expression by its index.
    pub fn get(self: *const ExpressionArena, id: ast.ExprId) ast.Expr {
        return self.nodes.items[id];
    }
};
