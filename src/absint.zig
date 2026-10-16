//! Cheap abstract interpretation over u32: an unsigned interval plus known-zero / known-one bits
//! (the same pair of facts LLVM tracks as ConstantRange and KnownBits).
//!
//! Why it exists: most members of the big equivalence classes (everything that folds to 0, 1, ...)
//! are "obviously constant" for a range analysis, e.g. `K eq select(v, K, K)`, `K ule (a ult b)`,
//! `(K lshr v) lshr 31`, `popcount(v) lshr 31`. Proving those with Z3 costs ~1.5 ms each; here it
//! costs a few nanoseconds, because children are already summarised per class.
//!
//! Soundness is the whole point: a wrong answer here is a wrong rewrite rule in the database.
//! Every transfer function may only over-approximate. The tests at the bottom check containment
//! against the reference evaluator (`eval.eval_point`) for random trees and for random abstract
//! operands: `zig test src/absint.zig`.

const std = @import("std");
const ast = @import("ast.zig");

pub const AV = struct {
    lo: u32,
    hi: u32,
    /// Bits known to be 0 / known to be 1 in every value of the set.
    kz: u32,
    ko: u32,

    pub const top: AV = .{ .lo = 0, .hi = 0xFFFFFFFF, .kz = 0, .ko = 0 };

    pub fn constant(c: u32) AV {
        return .{ .lo = c, .hi = c, .kz = ~c, .ko = c };
    }

    pub fn isConst(self: AV) bool {
        return self.lo == self.hi;
    }

    pub fn contains(self: AV, v: u32) bool {
        return v >= self.lo and v <= self.hi and (v & self.kz) == 0 and (v & self.ko) == self.ko;
    }

    /// Tightens the range with the bits and the bits with the range. Always sound; falls back to
    /// `top` if the facts contradict (which cannot happen for a non-empty set unless a transfer
    /// function is wrong, so "top" is the safe answer).
    pub fn normalize(self: AV) AV {
        var a = self;
        if (a.lo > a.hi) return top;
        a.lo = @max(a.lo, a.ko);
        a.hi = @min(a.hi, ~a.kz);
        if (a.lo > a.hi) return top;
        // Leading bits shared by lo and hi are shared by every value in between.
        const diff = a.lo ^ a.hi;
        const varying: u64 = (@as(u64, 1) << @intCast(32 - @clz(diff))) - 1; // bits up to the top differing bit
        const shared: u32 = ~@as(u32, @truncate(varying));
        a.kz |= ~a.lo & shared;
        a.ko |= a.lo & shared;
        if ((a.kz & a.ko) != 0) return top;
        if ((a.kz | a.ko) == 0xFFFFFFFF) return constant(a.ko);
        return a;
    }
};

fn bits(kz: u32, ko: u32) AV {
    return (AV{ .lo = 0, .hi = 0xFFFFFFFF, .kz = kz, .ko = ko }).normalize();
}

/// Number of low bits that are known to be zero.
fn knownLowZeros(a: AV) u32 {
    return if (a.kz == 0xFFFFFFFF) 32 else @ctz(~a.kz);
}

fn lowMask(n: u32) u32 {
    return if (n >= 32) 0xFFFFFFFF else (@as(u32, 1) << @intCast(n)) -% 1;
}

fn highMask(n: u32) u32 {
    return ~lowMask(32 - @min(n, 32));
}

fn shiftKnown(b: AV) bool {
    return ((b.kz | b.ko) & 31) == 31;
}

fn boolAV(known: ?bool) AV {
    if (known) |k| return AV.constant(@intFromBool(k));
    return .{ .lo = 0, .hi = 1, .kz = 0xFFFFFFFE, .ko = 0 };
}

fn tnumAdd(a: AV, b: AV) AV {
    const am = ~(a.kz | a.ko);
    const bm = ~(b.kz | b.ko);
    const sm = am +% bm;
    const sv = a.ko +% b.ko;
    const sigma = sm +% sv;
    const chi = sigma ^ sv;
    const mu = chi | am | bm;
    return bits(~sv & ~mu, sv & ~mu);
}

fn tnumSub(a: AV, b: AV) AV {
    const am = ~(a.kz | a.ko);
    const bm = ~(b.kz | b.ko);
    const dv = a.ko -% b.ko;
    const alpha = dv +% am;
    const beta = dv -% bm;
    const chi = alpha ^ beta;
    const mu = chi | am | bm;
    return bits(~dv & ~mu, dv & ~mu);
}

fn add(a: AV, b: AV) AV {
    var r = tnumAdd(a, b);
    const lo = @addWithOverflow(a.lo, b.lo);
    const hi = @addWithOverflow(a.hi, b.hi);
    // Either no sum wraps or every sum wraps exactly once.
    if (lo[1] == hi[1]) {
        r.lo = @max(r.lo, lo[0]);
        r.hi = @min(r.hi, hi[0]);
    }
    return r.normalize();
}

fn sub(a: AV, b: AV) AV {
    var r = tnumSub(a, b);
    if (a.lo >= b.hi or a.hi < b.lo) {
        // No difference underflows, or every difference underflows exactly once.
        r.lo = @max(r.lo, a.lo -% b.hi);
        r.hi = @min(r.hi, a.hi -% b.lo);
    }
    return r.normalize();
}

fn mul(a: AV, b: AV) AV {
    const tz: u32 = knownLowZeros(a) + knownLowZeros(b);
    var r = bits(lowMask(tz), 0);
    const hi: u64 = @as(u64, a.hi) * @as(u64, b.hi);
    if (hi <= 0xFFFFFFFF) {
        r.lo = @max(r.lo, a.lo * b.lo);
        r.hi = @min(r.hi, @as(u32, @intCast(hi)));
    } else if (a.isConst() and b.isConst()) {
        return AV.constant(a.lo *% b.lo);
    }
    return r.normalize();
}

fn shl(a: AV, b: AV) AV {
    if (a.hi == 0) return AV.constant(0);
    if (shiftKnown(b)) {
        const s: u5 = @intCast(b.ko & 31);
        var r = bits((a.kz << s) | lowMask(s), a.ko << s);
        if ((@as(u64, a.hi) << s) <= 0xFFFFFFFF) {
            r.lo = @max(r.lo, a.lo << s);
            r.hi = @min(r.hi, a.hi << s);
        }
        return r.normalize();
    }
    return bits(lowMask(knownLowZeros(a)), 0);
}

fn lshr(a: AV, b: AV) AV {
    if (shiftKnown(b)) {
        const s: u5 = @intCast(b.ko & 31);
        var r = bits((a.kz >> s) | highMask(s), a.ko >> s);
        r.lo = @max(r.lo, a.lo >> s);
        r.hi = @min(r.hi, a.hi >> s);
        return r.normalize();
    }
    return (AV{ .lo = 0, .hi = a.hi, .kz = 0, .ko = 0 }).normalize();
}

fn ashr(a: AV, b: AV) AV {
    const sign_zero = (a.kz >> 31) & 1 == 1;
    const sign_one = (a.ko >> 31) & 1 == 1;
    if (sign_zero) return lshr(a, b);
    if (shiftKnown(b)) {
        const s: u5 = @intCast(b.ko & 31);
        var r: AV = if (sign_one)
            bits(a.kz >> s, (a.ko >> s) | highMask(s))
        else
            bits(a.kz >> s, a.ko >> s);
        if (sign_one) {
            const lo: u32 = @bitCast(@as(i32, @bitCast(a.lo)) >> s);
            const hi: u32 = @bitCast(@as(i32, @bitCast(a.hi)) >> s);
            r.lo = @max(r.lo, lo);
            r.hi = @min(r.hi, hi);
        }
        return r.normalize();
    }
    if (sign_one) return (AV{ .lo = a.lo, .hi = 0xFFFFFFFF, .kz = 0, .ko = 0 }).normalize();
    return AV.top;
}

fn bitand(a: AV, b: AV) AV {
    return (AV{ .lo = 0, .hi = @min(a.hi, b.hi), .kz = a.kz | b.kz, .ko = a.ko & b.ko }).normalize();
}

fn bitor(a: AV, b: AV) AV {
    return (AV{ .lo = @max(a.lo, b.lo), .hi = 0xFFFFFFFF, .kz = a.kz & b.kz, .ko = a.ko | b.ko }).normalize();
}

fn bitxor(a: AV, b: AV) AV {
    return bits((a.kz & b.kz) | (a.ko & b.ko), (a.ko & b.kz) | (a.kz & b.ko));
}

/// The set of signed values as an interval, or null when the unsigned range straddles 2^31.
fn signedRange(a: AV) ?struct { lo: i32, hi: i32 } {
    const lo_neg = a.lo >= 0x80000000;
    const hi_neg = a.hi >= 0x80000000;
    if (lo_neg != hi_neg) return null;
    return .{ .lo = @bitCast(a.lo), .hi = @bitCast(a.hi) };
}

fn ult(a: AV, b: AV) ?bool {
    if (a.hi < b.lo) return true;
    if (a.lo >= b.hi) return false;
    return null;
}

fn ule(a: AV, b: AV) ?bool {
    if (a.hi <= b.lo) return true;
    if (a.lo > b.hi) return false;
    return null;
}

fn slt(a: AV, b: AV) ?bool {
    const x = signedRange(a) orelse return null;
    const y = signedRange(b) orelse return null;
    if (x.hi < y.lo) return true;
    if (x.lo >= y.hi) return false;
    return null;
}

fn sle(a: AV, b: AV) ?bool {
    const x = signedRange(a) orelse return null;
    const y = signedRange(b) orelse return null;
    if (x.hi <= y.lo) return true;
    if (x.lo > y.hi) return false;
    return null;
}

fn eq(a: AV, b: AV) ?bool {
    if (a.isConst() and b.isConst()) return a.lo == b.lo;
    if (a.hi < b.lo or b.hi < a.lo) return false;
    if (((a.ko & b.kz) | (a.kz & b.ko)) != 0) return false;
    return null;
}

pub fn unary(op: ast.UnOp, a: AV) AV {
    return switch (op) {
        .not => (AV{ .lo = ~a.hi, .hi = ~a.lo, .kz = a.ko, .ko = a.kz }).normalize(),
        .neg => sub(AV.constant(0), a),
        .clz => (AV{ .lo = @clz(a.hi), .hi = @clz(a.lo), .kz = 0, .ko = 0 }).normalize(),
        .ctz => blk: {
            if (a.hi == 0) break :blk AV.constant(32);
            const hi: u32 = if (a.ko != 0) @ctz(a.ko) else 32;
            break :blk (AV{ .lo = knownLowZeros(a), .hi = hi, .kz = 0, .ko = 0 }).normalize();
        },
        .popcount => (AV{ .lo = @popCount(a.ko), .hi = 32 - @popCount(a.kz), .kz = 0, .ko = 0 }).normalize(),
    };
}

pub fn binary(op: ast.BinOp, a: AV, b: AV) AV {
    return switch (op) {
        .add => add(a, b),
        .sub => sub(a, b),
        .mul => mul(a, b),
        .and_op => bitand(a, b),
        .or_op => bitor(a, b),
        .xor => bitxor(a, b),
        .shl => shl(a, b),
        .lshr => lshr(a, b),
        .ashr => ashr(a, b),
        .ult => boolAV(ult(a, b)),
        .ule => boolAV(ule(a, b)),
        .slt => boolAV(slt(a, b)),
        .sle => boolAV(sle(a, b)),
        .eq => boolAV(eq(a, b)),
    };
}

pub fn select(c: AV, t: AV, f: AV) AV {
    if (c.lo > 0 or c.ko != 0) return t; // condition is certainly non-zero
    if (c.hi == 0) return f;
    return (AV{ .lo = @min(t.lo, f.lo), .hi = @max(t.hi, f.hi), .kz = t.kz & f.kz, .ko = t.ko & f.ko }).normalize();
}

pub fn eval_expr(expr: ast.Expr, class_av: []const AV, expr_to_class: []const u32) AV {
    return switch (expr) {
        .variable => AV.top,
        .constant => |c| AV.constant(c),
        .unary => |u| unary(u.op, class_av[expr_to_class[u.expr]]),
        .binary => |b| binary(b.op, class_av[expr_to_class[b.lhs]], class_av[expr_to_class[b.rhs]]),
        .select => |sel| select(class_av[expr_to_class[sel.cond]], class_av[expr_to_class[sel.true_val]], class_av[expr_to_class[sel.false_val]]),
    };
}

pub fn eval_id(id: ast.ExprId, arena: anytype, class_av: []const AV, expr_to_class: []const u32) AV {
    return eval_expr(arena.get(id), class_av, expr_to_class);
}

// ---------------------------------------------------------------------------------------------
// Tests: `zig test src/absint.zig`
// ---------------------------------------------------------------------------------------------

const eval = @import("eval.zig");
const ExpressionArena = @import("arena.zig").ExpressionArena;

const interesting = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32, 33, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFE, 0xFFFFFFFF, 0x55555555, 0xAAAAAAAA };

fn randValue(rand: std.Random) u32 {
    return switch (rand.uintLessThan(u8, 4)) {
        0 => interesting[rand.uintLessThan(usize, interesting.len)],
        1 => rand.uintLessThan(u32, 70),
        2 => rand.int(u32) >> rand.uintLessThan(u5, 31),
        else => rand.int(u32),
    };
}

/// Abstraction of a small finite set (the join of its constants) plus the set itself.
const Sample = struct {
    av: AV,
    vals: [6]u32,
    n: usize,
};

fn randSample(rand: std.Random) Sample {
    var s: Sample = undefined;
    s.n = 1 + rand.uintLessThan(usize, 6);
    var av: AV = undefined;
    for (0..s.n) |i| {
        s.vals[i] = randValue(rand);
        const c = AV.constant(s.vals[i]);
        av = if (i == 0) c else (AV{ .lo = @min(av.lo, c.lo), .hi = @max(av.hi, c.hi), .kz = av.kz & c.kz, .ko = av.ko & c.ko }).normalize();
    }
    s.av = av;
    return s;
}

test "transfer functions are sound on random finite sets" {
    var prng = std.Random.DefaultPrng.init(12345);
    const rand = prng.random();
    for (0..200_000) |_| {
        const a = randSample(rand);
        const b = randSample(rand);
        const c = randSample(rand);
        inline for (@typeInfo(ast.BinOp).Enum.fields) |field| {
            const op: ast.BinOp = @enumFromInt(field.value);
            const r = binary(op, a.av, b.av);
            for (a.vals[0..a.n]) |x| for (b.vals[0..b.n]) |y| {
                const v = concreteBinary(op, x, y);
                if (!r.contains(v)) {
                    std.debug.print("UNSOUND {s}: {any} {any} -> {any}, but {} {s} {} = {}\n", .{ field.name, a.av, b.av, r, x, field.name, y, v });
                    return error.Unsound;
                }
            };
        }
        inline for (@typeInfo(ast.UnOp).Enum.fields) |field| {
            const op: ast.UnOp = @enumFromInt(field.value);
            const r = unary(op, a.av);
            for (a.vals[0..a.n]) |x| {
                const v = concreteUnary(op, x);
                if (!r.contains(v)) {
                    std.debug.print("UNSOUND {s}: {any} -> {any}, but f({}) = {}\n", .{ field.name, a.av, r, x, v });
                    return error.Unsound;
                }
            }
        }
        const r = select(c.av, a.av, b.av);
        for (c.vals[0..c.n]) |cv| for (a.vals[0..a.n]) |x| for (b.vals[0..b.n]) |y| {
            const v = if (cv != 0) x else y;
            if (!r.contains(v)) {
                std.debug.print("UNSOUND select\n", .{});
                return error.Unsound;
            }
        };
    }
}

fn concreteUnary(op: ast.UnOp, a: u32) u32 {
    return switch (op) {
        .not => ~a,
        .neg => 0 -% a,
        .clz => @clz(a),
        .ctz => @ctz(a),
        .popcount => @popCount(a),
    };
}

fn concreteBinary(op: ast.BinOp, l: u32, r: u32) u32 {
    const sh: u5 = @truncate(r);
    return switch (op) {
        .add => l +% r,
        .sub => l -% r,
        .mul => l *% r,
        .and_op => l & r,
        .or_op => l | r,
        .xor => l ^ r,
        .shl => l << sh,
        .lshr => l >> sh,
        .ashr => @bitCast(@as(i32, @bitCast(l)) >> sh),
        .eq => @intFromBool(l == r),
        .ult => @intFromBool(l < r),
        .ule => @intFromBool(l <= r),
        .slt => @intFromBool(@as(i32, @bitCast(l)) < @as(i32, @bitCast(r))),
        .sle => @intFromBool(@as(i32, @bitCast(l)) <= @as(i32, @bitCast(r))),
    };
}

const consts = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xFFFF };

/// Random tree plus its abstraction; also checks that the abstraction contains the value at
/// many random points, evaluated by the reference evaluator that Z3 is fuzzed against.
fn randTree(rand: std.Random, arena: *ExpressionArena, depth: usize, av_out: *AV) !ast.ExprId {
    if (depth == 0 or rand.uintLessThan(u8, 5) == 0) {
        if (rand.boolean()) {
            const v: ast.Var = @enumFromInt(rand.uintLessThan(u8, 3));
            av_out.* = AV.top;
            return arena.add(.{ .variable = v });
        }
        const c = consts[rand.uintLessThan(usize, consts.len)];
        av_out.* = AV.constant(c);
        return arena.add(.{ .constant = c });
    }
    switch (rand.uintLessThan(u8, 6)) {
        0 => {
            var a: AV = undefined;
            const child = try randTree(rand, arena, depth - 1, &a);
            const op: ast.UnOp = @enumFromInt(rand.uintLessThan(u8, 5));
            av_out.* = unary(op, a);
            return arena.add(.{ .unary = .{ .op = op, .expr = child } });
        },
        1 => {
            var c: AV = undefined;
            var t: AV = undefined;
            var f: AV = undefined;
            const ce = try randTree(rand, arena, depth - 1, &c);
            const te = try randTree(rand, arena, depth - 1, &t);
            const fe = try randTree(rand, arena, depth - 1, &f);
            av_out.* = select(c, t, f);
            return arena.add(.{ .select = .{ .cond = ce, .true_val = te, .false_val = fe } });
        },
        else => {
            var a: AV = undefined;
            var b: AV = undefined;
            const l = try randTree(rand, arena, depth - 1, &a);
            const r = try randTree(rand, arena, depth - 1, &b);
            const op: ast.BinOp = @enumFromInt(rand.uintLessThan(u8, 14));
            av_out.* = binary(op, a, b);
            return arena.add(.{ .binary = .{ .op = op, .lhs = l, .rhs = r } });
        },
    }
}

test "abstraction of random trees contains the reference evaluation" {
    var prng = std.Random.DefaultPrng.init(777);
    const rand = prng.random();
    var arena = try ExpressionArena.init(std.testing.allocator);
    defer arena.deinit();
    var proven_const: usize = 0;
    for (0..60_000) |_| {
        var av: AV = undefined;
        const e = try randTree(rand, &arena, 4, &av);
        if (av.isConst()) proven_const += 1;
        for (0..48) |_| {
            const x = randValue(rand);
            const y = if (rand.uintLessThan(u8, 6) == 0) x else randValue(rand);
            const z = if (rand.uintLessThan(u8, 6) == 0) y else randValue(rand);
            const v = eval.eval_point(e, &arena, x, y, z);
            if (!av.contains(v)) {
                var buf: [512]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                @import("arena.zig").format_expr(e, &arena, fbs.writer()) catch {};
                std.debug.print("UNSOUND tree {s}: av={any} but eval({}, {}, {}) = {}\n", .{ fbs.getWritten(), av, x, y, z, v });
                return error.Unsound;
            }
        }
    }
    // Sanity: the analysis must actually prove something, or the soundness checks are vacuous.
    try std.testing.expect(proven_const > 1000);
}
