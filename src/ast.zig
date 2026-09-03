/// The input variables available for expression generation.
/// Restricted to 3 variables to cap the combinatorial search space,
/// which is sufficient for most localized peephole optimizations.
pub const Var = enum { x, y, z };

/// Single-argument operations.
/// Restricted to total functions to guarantee evaluation without crashes,
/// mapping directly to fast, single-cycle CPU instructions.
pub const UnOp = enum {
    neg,
    not,
    clz,
    ctz,
    popcount,
};

/// Two-argument operations.
/// Division and modulo are deliberately excluded to avoid divide-by-zero
/// traps and to keep SMT solver proofs simple.
pub const BinOp = enum {
    add,
    sub,
    mul,
    and_op,
    or_op,
    xor,
    shl,
    lshr,
    ashr,
    ult,
    ule,
    slt,
    sle,
    eq,
};

/// A 32-bit index representing a pointer to an expression in the arena.
/// Using an index instead of a heap pointer (`*Expr`) halves memory usage
/// and ensures CPU cache locality during evaluation.
pub const ExprId = u32;

/// The core abstract syntax tree (AST) node.
/// Designed as a strict 16-byte tagged union (12-byte max payload + 4-byte tag),
/// allowing millions of nodes to be tightly packed in memory.
pub const Expr = union(enum) {
    variable: Var,
    constant: u32,
    unary: struct { op: UnOp, expr: ExprId },
    binary: struct { op: BinOp, lhs: ExprId, rhs: ExprId },
    select: struct { cond: ExprId, true_val: ExprId, false_val: ExprId },
};

const arena_mod = @import("arena.zig");
pub fn format_expr(expr_id: ExprId, arena: *const arena_mod.ExpressionArena, writer: anytype) !void {
    const expr = arena.get(expr_id);
    switch (expr) {
        .variable => |v| try writer.print("{s}", .{@tagName(v)}),
        .constant => |c| try writer.print("{}", .{c}),
        .unary => |u| {
            try writer.print("{s}(", .{@tagName(u.op)});
            try format_expr(u.expr, arena, writer);
            try writer.print(")", .{});
        },
        .binary => |b| {
            try writer.print("(", .{});
            try format_expr(b.lhs, arena, writer);
            try writer.print(" {s} ", .{@tagName(b.op)});
            try format_expr(b.rhs, arena, writer);
            try writer.print(")", .{});
        },
        .select => |s| {
            try writer.print("select(", .{});
            try format_expr(s.cond, arena, writer);
            try writer.print(", ", .{});
            try format_expr(s.true_val, arena, writer);
            try writer.print(", ", .{});
            try format_expr(s.false_val, arena, writer);
            try writer.print(")", .{});
        },
    }
}
