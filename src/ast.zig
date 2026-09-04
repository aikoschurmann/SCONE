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

    pub fn isCommutative(self: BinOp) bool {
        return self == .add or self == .mul or self == .and_op or self == .or_op or self == .xor or self == .eq;
    }
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


