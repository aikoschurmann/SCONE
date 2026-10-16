//! Decides equality of two expressions over one variable by evaluating both on all 2^32 inputs.
//!
//! Why it exists: after the normalizer, most of the solver time that is left goes to members
//! that mention a single variable (about 60% in the cost-3 logs), and those are the ones Z3 keeps
//! timing out on. A function of one 32-bit input is fully determined by its 2^32 values, so
//! comparing them is a complete proof with no rules involved: equal everywhere means equal, and
//! the first difference is a counterexample.
//!
//! The two expressions are compiled into one straight-line program (shared subterms once) and
//! run on blocks of consecutive inputs, one operator at a time over the whole block, so each
//! operator is a tight vector loop.

const std = @import("std");
const ast = @import("ast.zig");
const ExpressionArena = @import("arena.zig").ExpressionArena;

const block = 1024; // 4 KB per register: a typical program's registers stay in L1
const lanes = 16;
const V = @Vector(lanes, u32);

const Instr = struct {
    tag: enum { input, konst, unary, binary, select },
    un: ast.UnOp = .neg,
    bin: ast.BinOp = .add,
    val: u32 = 0,
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,
};

/// The single variable an expression pair depends on, or null when it uses two or more.
/// `.x` is returned for a pair of constants (any variable works).
pub fn singleVar(arena: *const ExpressionArena, a: ast.ExprId, b: ast.ExprId) ?ast.Var {
    var seen: [3]bool = .{ false, false, false };
    mark(arena, a, &seen);
    mark(arena, b, &seen);
    var n: usize = 0;
    var v: ast.Var = .x;
    for (seen, 0..) |s, i| if (s) {
        n += 1;
        v = @enumFromInt(i);
    };
    return if (n <= 1) v else null;
}

fn mark(arena: *const ExpressionArena, id: ast.ExprId, seen: *[3]bool) void {
    switch (arena.get(id)) {
        .variable => |v| seen[@intFromEnum(v)] = true,
        .constant => {},
        .unary => |u| mark(arena, u.expr, seen),
        .binary => |bn| {
            mark(arena, bn.lhs, seen);
            mark(arena, bn.rhs, seen);
        },
        .select => |s| {
            mark(arena, s.cond, seen);
            mark(arena, s.true_val, seen);
            mark(arena, s.false_val, seen);
        },
    }
}

const Program = struct {
    code: [64]Instr = undefined,
    len: usize = 0,
    ids: [64]ast.ExprId = undefined,

    fn emit(p: *Program, arena: *const ExpressionArena, id: ast.ExprId) error{TooBig}!u16 {
        for (p.ids[0..p.len], 0..) |seen, i| if (seen == id) return @intCast(i);
        const ins: Instr = switch (arena.get(id)) {
            .variable => .{ .tag = .input },
            .constant => |k| .{ .tag = .konst, .val = k },
            .unary => |u| .{ .tag = .unary, .un = u.op, .a = try p.emit(arena, u.expr) },
            .binary => |bn| .{ .tag = .binary, .bin = bn.op, .a = try p.emit(arena, bn.lhs), .b = try p.emit(arena, bn.rhs) },
            .select => |s| .{ .tag = .select, .a = try p.emit(arena, s.cond), .b = try p.emit(arena, s.true_val), .c = try p.emit(arena, s.false_val) },
        };
        if (p.len == p.code.len) return error.TooBig;
        p.code[p.len] = ins;
        p.ids[p.len] = id;
        p.len += 1;
        return @intCast(p.len - 1);
    }
};

fn b2v(m: @Vector(lanes, bool)) V {
    return @select(u32, m, @as(V, @splat(1)), @as(V, @splat(0)));
}

/// Runs one instruction over a block (registers hold `block` values each).
fn exec(ins: Instr, regs: [][block / lanes]V, dst: usize, first: u32) void {
    const out = &regs[dst];
    switch (ins.tag) {
        .input => {
            var base: V = std.simd.iota(u32, lanes) + @as(V, @splat(first));
            for (out) |*o| {
                o.* = base;
                base +%= @as(V, @splat(lanes));
            }
        },
        .konst => @memset(out, @as(V, @splat(ins.val))),
        .unary => {
            const a = &regs[ins.a];
            for (out, a) |*o, x| o.* = switch (ins.un) {
                .neg => @as(V, @splat(0)) -% x,
                .not => ~x,
                .clz => @clz(x),
                .ctz => @ctz(x),
                .popcount => @popCount(x),
            };
        },
        .binary => {
            const a = &regs[ins.a];
            const b = &regs[ins.b];
            const s31: V = @splat(31);
            switch (ins.bin) {
                .add => for (out, a, b) |*o, l, r| {
                    o.* = l +% r;
                },
                .sub => for (out, a, b) |*o, l, r| {
                    o.* = l -% r;
                },
                .mul => for (out, a, b) |*o, l, r| {
                    o.* = l *% r;
                },
                .and_op => for (out, a, b) |*o, l, r| {
                    o.* = l & r;
                },
                .or_op => for (out, a, b) |*o, l, r| {
                    o.* = l | r;
                },
                .xor => for (out, a, b) |*o, l, r| {
                    o.* = l ^ r;
                },
                .shl => for (out, a, b) |*o, l, r| {
                    o.* = l << @as(@Vector(lanes, u5), @truncate(r & s31));
                },
                .lshr => for (out, a, b) |*o, l, r| {
                    o.* = l >> @as(@Vector(lanes, u5), @truncate(r & s31));
                },
                .ashr => for (out, a, b) |*o, l, r| {
                    o.* = @bitCast(@as(@Vector(lanes, i32), @bitCast(l)) >> @as(@Vector(lanes, u5), @truncate(r & s31)));
                },
                .ult => for (out, a, b) |*o, l, r| {
                    o.* = b2v(l < r);
                },
                .ule => for (out, a, b) |*o, l, r| {
                    o.* = b2v(l <= r);
                },
                .slt => for (out, a, b) |*o, l, r| {
                    o.* = b2v(@as(@Vector(lanes, i32), @bitCast(l)) < @as(@Vector(lanes, i32), @bitCast(r)));
                },
                .sle => for (out, a, b) |*o, l, r| {
                    o.* = b2v(@as(@Vector(lanes, i32), @bitCast(l)) <= @as(@Vector(lanes, i32), @bitCast(r)));
                },
                .eq => for (out, a, b) |*o, l, r| {
                    o.* = b2v(l == r);
                },
            }
        },
        .select => {
            const c = &regs[ins.a];
            const t = &regs[ins.b];
            const f = &regs[ins.c];
            for (out, c, t, f) |*o, cv, tv, fv| o.* = @select(u32, cv != @as(V, @splat(0)), tv, fv);
        },
    }
}

pub const Verdict = union(enum) {
    equal,
    /// The first input value (of the single variable) where the two differ.
    differ: u32,
    /// Too large to compile (more than 64 distinct subterms); not decided.
    skipped,
};

/// Compares a and b on every value of their single variable (see `singleVar`).
pub fn compare(gpa: std.mem.Allocator, arena: *const ExpressionArena, a: ast.ExprId, b: ast.ExprId) !Verdict {
    var p = Program{};
    const ra = p.emit(arena, a) catch return .skipped;
    const rb = p.emit(arena, b) catch return .skipped;
    if (ra == rb) return .equal;
    const regs = try gpa.alloc([block / lanes]V, p.len);
    defer gpa.free(regs);
    var first: u64 = 0;
    while (first < (1 << 32)) : (first += block) {
        for (p.code[0..p.len], 0..) |ins, i| {
            if (ins.tag == .konst and first != 0) continue; // constants stay from the first block
            exec(ins, regs, i, @intCast(first));
        }
        for (regs[ra], regs[rb], 0..) |va, vb, k| {
            if (@reduce(.And, va == vb)) continue;
            for (0..lanes) |l| if (va[l] != vb[l]) return .{ .differ = @intCast(first + k * lanes + l) };
        }
    }
    return .equal;
}

test "exhaustive comparison decides single-variable identities" {
    const gpa = std.testing.allocator;
    var arena = try ExpressionArena.init(gpa);
    defer arena.deinit();
    const x = try arena.add(.{ .variable = .x });
    const k = struct {
        fn f(ar: *ExpressionArena, c: u32) !ast.ExprId {
            return ar.add(.{ .constant = c });
        }
    }.f;
    const bin = struct {
        fn f(ar: *ExpressionArena, op: ast.BinOp, l: ast.ExprId, r: ast.ExprId) !ast.ExprId {
            return ar.add(.{ .binary = .{ .op = op, .lhs = l, .rhs = r } });
        }
    }.f;
    // popcount(select(x, x, 1)) == popcount(select(x ult 3, 1, x)): true (x = 0, 1, 2 all give 1)
    const p1 = try arena.add(.{ .unary = .{ .op = .popcount, .expr = try arena.add(.{ .select = .{ .cond = x, .true_val = x, .false_val = try k(&arena, 1) } }) } });
    const p2 = try arena.add(.{ .unary = .{ .op = .popcount, .expr = try arena.add(.{ .select = .{ .cond = try bin(&arena, .ult, x, try k(&arena, 3)), .true_val = try k(&arena, 1), .false_val = x } }) } });
    try std.testing.expectEqual(Verdict.equal, try compare(gpa, &arena, p1, p2));
    // x mul x vs x: differ first at x = 2
    try std.testing.expectEqual(Verdict{ .differ = 2 }, try compare(gpa, &arena, try bin(&arena, .mul, x, x), x));
    // differ only at the very last input: x ult 0xffffffff vs 1
    try std.testing.expectEqual(Verdict{ .differ = 0xFFFFFFFF }, try compare(gpa, &arena, try bin(&arena, .ult, x, try k(&arena, 0xFFFFFFFF)), try k(&arena, 1)));
    try std.testing.expect(singleVar(&arena, p1, p2) == .x);
}
