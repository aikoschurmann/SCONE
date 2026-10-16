//! Sound algebraic normal forms for u32 expressions.
//!
//! Why it exists: after fingerprinting, almost every member of a class really is equal to the
//! canonical expression, and Z3 spends most of a level proving equalities that are plain algebra:
//! `((a lshr b) lshr c) == ((a lshr c) lshr b)` (hundreds of ms each: two nested barrel shifters
//! per side), `(z xor -1) - s == -1 xor (z + s)`, and so on. Two expressions with the same normal
//! form are equal on every input, so such members are settled without a solver call.
//!
//! Soundness is the whole point: a wrong rule here is a wrong rewrite rule in the database. Every
//! rewrite is an identity of arithmetic modulo 2^32 with shift amounts taken mod 32:
//!   * add / sub / neg / not / mul-by-constant / shl-by-constant are linear:
//!     `not a = -a - 1`, `a shl k = a * 2^k`, and `(sum k_i a_i + c) shl s = sum k_i (a_i shl s) + (c shl s)`
//!     because `shl s` is multiplication by 2^(s & 31).
//!   * and / or / xor / mul are associative-commutative; and / or are idempotent, xor cancels pairs.
//!   * xor with a constant that is linear: `t xor -1 = -t - 1`, `t xor 0x80000000 = t + 0x80000000`
//!     (no carry leaves the top bit), so `t xor 0x7FFFFFFF = 0x7FFFFFFF - t`; and `K xor p = K - p`
//!     whenever every bit p can have is set in K (no borrow).
//!   * `popcount(not a) = 32 - popcount(a)`; `popcount(2^j shl s)` is 1 or 0: the single bit either
//!     stays or is shifted out, so it equals `(2^j shl s) != 0`.
//!   * a chain of one shift op commutes: shifting by k1 then k2 is shifting by k1 + k2, saturating
//!     at 32 (shl, lshr) or 31 (ashr), which is symmetric in k1 and k2.
//!   * in an `and` with an equation `ka*a + kb*b == 0` (ka, kb odd), a is 0 exactly when b is, so zero
//!     tests on either use the smaller of the two. A part `zero(d)` makes d = 0 in the other parts;
//!     `[a != 0]` is dropped when another part `zero(k*m + c)` (c != 0) has a as a factor of m.
//!   * `(t xor K2) == K` is `t == K xor K2`; `select(c, t, K) == 0` (K != 0) is `[c != 0] and [t == 0]`.
//!   * a whole expression of the form `K + k*b` (b in {0, 1}) is reported as `select(b, K + k, K)`, so it
//!     matches selects between two constants; only at the top, nested forms are untouched.
//!   * `select(c, b, 1) = b or [c == 0]`
//!     and `select(c, 1, b) = [c != 0] or b` for b in {0, 1}; `0 slt u` is `not ([u slt 0] or [u == 0])`. De Morgan goes one
//!     way: an `and` of negated 0/1 values `1 - b_i` is `1 - (b_1 or b_2 or ...)`.
//!   * the top bit has one form, `a lshr 31`: `0x7fffffff ult a` is it, `a ult 0x80000000` is 1 minus
//!     it, `a slt 1` is `(a lshr 31) or (a == 0)`, and the top bit of `0x7fffffff - a` (= a xor 0x7fffffff)
//!     is a's, of `a xor 0x80000000` and `not a` it is flipped.
//!   * comparisons: `a eq b = is_zero(a - b)`, `is_zero(u * d) = is_zero(d)` for odd u,
//!     `a ule b = 1 - (b ult a)`, `a slt b = (a + 2^31) ult (b + 2^31)` (or `a ult b` when both are
//!     known non-negative), plus facts that follow from an upper bound `hi` on a term's value:
//!     `a ult K = 1` if hi(a) < K, `a ult hi(a) = 1 - is_zero(a - hi(a))`, `is_zero(b) = 1 - b` for
//!     b in {0, 1}, and `clz(a) = 32`, `ctz(a) = 32`, `popcount(a) = 0` hold exactly when a = 0.
//!   * select: only `c != 0` matters, so `select(c == 0, t, f) = select(c, f, t)` and odd factors
//!     of c drop out; c is 0 in the false branch and nonzero in the true branch, so it may be
//!     replaced accordingly there (a nonzero 0/1 value is 1); `select(c, t, f) = t` when t equals f
//!     wherever c is 0; and every operator distributes over a select operand:
//!     `op(a, select(c, t, f)) = select(c, op(a, t), op(a, f))`.
//!   * zero-ness of a condition: select and `== 0` only ask whether a value is 0, so conditions are
//!     replaced by a canonical value that is 0 for exactly the same inputs (`nonzeroKey`):
//!     `popcount(a)`, `-a`, `u * a` (u odd) and `a shl (a & 31)` are 0 iff a is; `2^t * a`,
//!     `a and (2^(32-t) - 1)` and `a mul a` (t = 16) are 0 iff `a shl t` is; `a xor b` iff `a - b`;
//!     `a ashr s` iff `a lshr s` (one amount, taken mod 32); and `K lshr s`, `K shl s` are 0 iff
//!     `(s & 31) > T` for a T that depends on K only, so K is replaced by 2^T (never 0 when T = 31).
//!     `a or K` (K != 0) and `a + c` that cannot wrap (c != 0, hi(a) < 2^32 - c) are never 0. A
//!     select is never 0 when both branches are never 0, and `select(c, t, f)` with t = c or t a
//!     nonzero constant is 0 iff `c or f` is.
//!   * 0/1 operands become selects so branch facts apply: `a mul b = select(b, a, 0)`,
//!     `a op b = select(b, a op 1, a)` for a shift op, and `a op b = select(b, a op 1, a op 0)` for
//!     and / or / xor, whenever b is 0 or 1 (hi(b) <= 1). A select whose false branch equals the true
//!     branch wherever the condition holds is its false branch.
//!     `select(c, 0, K)` (K != 0) is nonzero exactly when c is 0.
//!   * `a mul (a lshr s) = n` and `a mul (a ashr s) = n` are solved exactly (`solveMulShift`): write
//!     a = (h shl s) + l with l < 2^s; for s >= 16 try every h and solve l*h = n - (h shl s)*h as a
//!     linear congruence, for s <= 8 try every l and lift (h shl s)*h + l*h = n one bit of h at a
//!     time. No solution makes the test 0; exactly one, a == that value. Otherwise it is left alone.
//!   * facts in select branches: where `k*a` is 0 with k = 2^t * u (t >= 1), a is a multiple of
//!     2^(32-t): a's coefficients only matter mod 2^t, and a product with m copies of a is 0 once
//!     m * (32 - t) >= 32. Where `select(c, 0, f)` is nonzero, c is 0. Where `k*a + c` is 0 (k odd)
//!     a is the constant -c / k, and where it is nonzero... nothing; where `zero(k*a + c)` is nonzero,
//!     likewise a = -c / k. Where `a ult 2` holds, `a mul a` is a. Where `a ult K` holds, `a == v` is 0 for v >= K and `a ult K2` is 1
//!     for K2 >= K; where `a or b` is 0, so are a and b; where `k*a + c` is 0 (k odd),
//!     a is the constant `-c / k`.
//!   * order: `a lshr s <= a`, `a and b <= a`, `a or b >= a` (unsigned), so `a ult (a lshr s)`,
//!     `a ult (a and b)` and `(a or b) ult a` are 0; and `a - b` lies in [0, a] when b <= a (b one
//!     of those or `popcount(a)`), so `a ult (a - b)` is 0.
//!     t <= a also holds transitively through `lshr`, `and`, `popcount`, and for `(k*b) lshr s` and
//!     `k * (b lshr s)` with k <= 2^s (no result exceeds b, wrap-around included), so `a ult t` is 0.
//!     Some of those are below a strictly unless a = 0 (`strictlyBelow`): `b lshr s` (s >= 1 constant),
//!     `(k*b) lshr s` and `k*(b lshr s)` with k < 2^s, `a - popcount(a)`. Then `t ult a` is `a != 0`
//!     (and so `a ule t` is `a == 0`). A t <= a that is never negative gives `a slt t` = `a slt 0`.
//!   * `select(c, 1, 0)` is `c != 0` and `select(c, 0, 1)` is `c == 0`. With a 0/1 branch and a 0
//!     branch a select is a conjunction of 0/1 values, kept as `and`: `select(c, b, 0) = [c != 0]
//!     and b`, `select(c, 0, b) = [c == 0] and b`; `a ult b` with b in {0, 1} is `b and [a == 0]`.
//!     `select(c, t, select(d, t, f)) = select(c or d, t, f)`. Nested selects are put in one order,
//!     smaller condition outermost (`select(c, A, B)` with a select on d < c inside becomes
//!     `select(d, select(c, A|d, B|d), select(c, A|!d, B|!d))`), and a select condition that is
//!     itself a select is split by cases: `select(select(d, u, v), A, B) =
//!     select(d, select(u, A, B), select(v, A, B))`. `0x80000000 shl s` is
//!     `select((s and 31) == 0, 0x80000000, 0)`. A shift whose upper bound is 0 is 0, and
//!     `a ashr 31 = -(a lshr 31)`. A comparison with an operand `c + k*b`, b in {0, 1}, is a select on b
//!     over the two values. `k*(a mul a) + c` (k odd) is never 0 when -c/k is not a square, and
//!     `a mul (c - a)` is completed to a square like `a mul (a + c)`. `a mul (a xor K)` with K odd is even. `popcount(b) = b` for b in {0, 1}.
//!     A factor that is always odd does not change whether a product is 0. `(a xor b) == -1` is
//!     `a + b + 1 == 0` (both say b = not a). `a and K` is a when every
//!     bit a can have is in K (likewise `a and (b or K)`). popcount ignores `lshr ctz(a)` and
//!     `shl clz(a)`, and `a shl 1` where a < 2^31 is known (a ult K, K <= 2^31).
//!   * zero tests: `c + sum k_i a_i` is never 0 when every term has more trailing zero bits than c,
//!     counting both the coefficient and the bits a_i always has clear (`minTz`). `a mul a = n` needs
//!     n to be a square mod 2^32 (even trailing zeros, odd part 1 mod 8); so does
//!     `a mul (a + 2m) = n` after completing the square: (a + m)^2 = n + m^2. `a mul (k a + c)` with
//!     k, c odd is always even (one factor is), which feeds the trailing-zero count. Where `select(c, t, K)`
//!     (K != 0) is 0, t is 0; where `select(c, K, f)` is 0, c and f are.
//!     `k a + j f(a) + c == 0` with f a count (popcount, clz, ctz: 0..32) and k odd can only hold
//!     at the 33 values a = -(c + j p) / k, p = 0..32; checking them decides it, or reduces it to
//!     `a == a_p` when exactly one fits.
//! The tests at the bottom check, for random trees, that every normal form evaluates to the same
//! value as the reference evaluator (`eval.eval_point`) and stays within its bound `hi`:
//! `zig test src/normalize.zig`.

const std = @import("std");
const ast = @import("ast.zig");
const ExpressionArena = @import("arena.zig").ExpressionArena;

/// Id of an interned normal-form node; equal ids mean equal functions.
pub const Nf = u32;

const Tag = enum(u32) {
    konst, // [c]
    variable, // [var]
    lin, // [c, atom_1, coeff_1, ...] sorted by atom, coefficients nonzero, not a single plain atom
    ac, // [op, children...] sorted; op is and_op / or_op / xor / mul
    shift, // [op, base, amounts...] amounts sorted; op is shl / lshr / ashr
    bin, // [op, lhs, rhs]; op is ult (every comparison is rewritten into ult or zero)
    zero, // [d]: 1 if d == 0 else 0
    un, // [op, child] for clz / ctz / popcount
    sel, // [cond, t, f]
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: []const u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
    }
    pub fn eql(_: KeyContext, a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};

const Term = struct { atom: Nf, coeff: u32 };

/// Work allowed per expression for select rewrites; the expressions SCONE enumerates use a tiny
/// fraction of it.
const select_budget = 2000;

/// Smallest 2^n - 1 >= v.
fn smear(v: u32) u32 {
    return if (v == 0) 0 else @as(u32, 0xFFFFFFFF) >> @intCast(@clz(v));
}

/// Multiplicative inverse of an odd number modulo 2^32 (Newton's iteration).
fn inverseOdd(k: u32) u32 {
    var inv: u32 = k; // correct to 3 bits
    for (0..4) |_| inv *%= 2 -% k *% inv;
    return inv;
}

pub const Normalizer = struct {
    gpa: std.mem.Allocator,
    keys_arena: std.heap.ArenaAllocator,
    /// keys.items[id] = [tag, payload...]
    keys: std.ArrayListUnmanaged([]const u32) = .{},
    /// his.items[id] is an upper bound on the (unsigned) value of node id.
    his: std.ArrayListUnmanaged(u32) = .{},
    interned: std.HashMapUnmanaged([]const u32, Nf, KeyContext, 80) = .{},
    memo: std.AutoHashMapUnmanaged(ast.ExprId, Nf) = .{},
    /// Select rewrites left for the current top-level `normalize` call. Distributing operators over
    /// selects and rewriting branches can grow exponentially with nested selects; once the budget
    /// is spent, selects are left as they are (always sound, just less complete).
    budget: u32 = 0,
    depth: u32 = 0,
    /// One memo table per nesting level of `subst` (selects inside a branch substitute again),
    /// kept between calls to avoid allocating.
    subst_memos: std.ArrayListUnmanaged(*std.AutoHashMapUnmanaged(Nf, Nf)) = .{},
    subst_depth: usize = 0,
    /// `lowBits` results, keyed by node * 32 + bits.
    low_memo: std.AutoHashMapUnmanaged(u64, Nf) = .{},
    low_depth: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Normalizer {
        return .{ .gpa = gpa, .keys_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Normalizer) void {
        self.keys.deinit(self.gpa);
        self.his.deinit(self.gpa);
        self.interned.deinit(self.gpa);
        self.memo.deinit(self.gpa);
        for (self.subst_memos.items) |m| {
            m.deinit(self.gpa);
            self.gpa.destroy(m);
        }
        self.subst_memos.deinit(self.gpa);
        self.low_memo.deinit(self.gpa);
        self.keys_arena.deinit();
    }

    /// Forgets everything. Normal forms computed before a reset must not be compared with ones
    /// computed after it.
    pub fn reset(self: *Normalizer) void {
        self.keys.clearRetainingCapacity();
        self.his.clearRetainingCapacity();
        self.interned.clearRetainingCapacity();
        self.memo.clearRetainingCapacity();
        self.low_memo.clearRetainingCapacity();
        _ = self.keys_arena.reset(.retain_capacity);
    }

    pub fn size(self: *const Normalizer) usize {
        return self.keys.items.len;
    }

    fn intern(self: *Normalizer, key: []const u32) !Nf {
        const gop = try self.interned.getOrPut(self.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = try self.keys_arena.allocator().dupe(u32, key);
        gop.key_ptr.* = owned;
        gop.value_ptr.* = @intCast(self.keys.items.len);
        try self.keys.append(self.gpa, owned);
        try self.his.append(self.gpa, self.computeHi(owned));
        return gop.value_ptr.*;
    }

    fn hi(self: *const Normalizer, n: Nf) u32 {
        return self.his.items[n];
    }

    /// Upper bound on the value of a node with this key; children are already interned.
    fn computeHi(self: *const Normalizer, key: []const u32) u32 {
        const all: u32 = 0xFFFFFFFF;
        const p = key[1..];
        return switch (@as(Tag, @enumFromInt(key[0]))) {
            .konst => p[0],
            .variable => all,
            .lin => blk: {
                if (p.len != 3) break :blk all;
                const c = p[0];
                const h = self.hi(p[1]);
                break :blk switch (p[2]) {
                    // c + [0, h]
                    1 => if (@addWithOverflow(c, h)[1] == 0) c + h else all,
                    // c - [0, h]
                    all => if (c >= h) c else all,
                    else => all,
                };
            },
            .ac => switch (@as(ast.BinOp, @enumFromInt(p[0]))) {
                .and_op => blk: {
                    var m: u32 = all;
                    for (p[1..]) |k| m = @min(m, self.hi(k));
                    break :blk m;
                },
                .or_op, .xor => blk: {
                    var m: u32 = 0;
                    for (p[1..]) |k| m |= self.hi(k);
                    break :blk smear(m);
                },
                else => all,
            },
            .shift => blk: {
                // Constant amounts (each taken mod 32) shift the bound down; others only lower it.
                var sum: u32 = 0;
                for (p[2..]) |amt| if (self.constValue(amt)) |v| {
                    sum += v & 31;
                };
                const base = self.hi(p[1]);
                const shifted: u32 = if (sum >= 32) 0 else base >> @intCast(sum);
                break :blk switch (@as(ast.BinOp, @enumFromInt(p[0]))) {
                    .lshr => shifted,
                    .ashr => if (base <= 0x7FFFFFFF) shifted else all,
                    else => all,
                };
            },
            .bin, .zero => 1,
            .un => 32,
            .sel => @max(self.hi(p[1]), self.hi(p[2])),
        };
    }

    fn tagOf(self: *const Normalizer, n: Nf) Tag {
        return @enumFromInt(self.keys.items[n][0]);
    }

    fn payload(self: *const Normalizer, n: Nf) []const u32 {
        return self.keys.items[n][1..];
    }

    fn konst(self: *Normalizer, c: u32) !Nf {
        return self.intern(&.{ @intFromEnum(Tag.konst), c });
    }

    fn constValue(self: *const Normalizer, n: Nf) ?u32 {
        return if (self.tagOf(n) == .konst) self.payload(n)[0] else null;
    }

    // ---- linear combinations --------------------------------------------------------------

    const Lin = struct {
        c: u32 = 0,
        terms: std.ArrayListUnmanaged(Term) = .{},

        fn deinit(l: *Lin, gpa: std.mem.Allocator) void {
            l.terms.deinit(gpa);
        }
    };

    /// Adds `k * n` to `acc`, expanding `n` if it is itself linear.
    fn addScaled(self: *Normalizer, acc: *Lin, n: Nf, k: u32) !void {
        switch (self.tagOf(n)) {
            .konst => acc.c +%= k *% self.payload(n)[0],
            .lin => {
                const p = self.payload(n);
                acc.c +%= k *% p[0];
                var i: usize = 1;
                while (i < p.len) : (i += 2) try acc.terms.append(self.gpa, .{ .atom = p[i], .coeff = k *% p[i + 1] });
            },
            else => try acc.terms.append(self.gpa, .{ .atom = n, .coeff = k }),
        }
    }

    fn finishLin(self: *Normalizer, acc: *Lin) !Nf {
        defer acc.deinit(self.gpa);
        const terms = acc.terms.items;
        std.sort.pdq(Term, terms, {}, struct {
            fn f(_: void, a: Term, b: Term) bool {
                return a.atom < b.atom;
            }
        }.f);
        // Merge equal atoms and drop zero coefficients.
        var n: usize = 0;
        for (terms) |t| {
            if (n > 0 and terms[n - 1].atom == t.atom) {
                terms[n - 1].coeff +%= t.coeff;
                if (terms[n - 1].coeff == 0) n -= 1;
            } else if (t.coeff != 0) {
                terms[n] = t;
                n += 1;
            }
        }
        if (n == 0) return self.konst(acc.c);
        // k * a with k = 2^t * u only sees the low 32 - t bits of a.
        if (self.low_depth < 4) {
            var changed = false;
            for (terms[0..n]) |*t| {
                const tz = @ctz(t.coeff);
                if (tz == 0) continue;
                const a2 = try self.lowBits(t.atom, 32 - tz);
                if (a2 != t.atom) {
                    t.atom = a2;
                    changed = true;
                }
            }
            if (changed) {
                var again = Lin{ .c = acc.c };
                errdefer again.deinit(self.gpa);
                for (terms[0..n]) |t| try self.addScaled(&again, t.atom, t.coeff);
                self.low_depth += 1;
                defer self.low_depth -= 1;
                return self.finishLin(&again);
            }
        }
        if (n == 1 and acc.c == 0 and terms[0].coeff == 1) return terms[0].atom;
        var key = try std.ArrayListUnmanaged(u32).initCapacity(self.gpa, 2 + 2 * n);
        defer key.deinit(self.gpa);
        key.appendAssumeCapacity(@intFromEnum(Tag.lin));
        key.appendAssumeCapacity(acc.c);
        for (terms[0..n]) |t| {
            key.appendAssumeCapacity(t.atom);
            key.appendAssumeCapacity(t.coeff);
        }
        return self.intern(key.items);
    }

    /// k_a * a + k_b * b + c
    fn linear2(self: *Normalizer, a: Nf, ka: u32, b: Nf, kb: u32, c: u32) !Nf {
        var acc = Lin{ .c = c };
        errdefer acc.deinit(self.gpa);
        try self.addScaled(&acc, a, ka);
        try self.addScaled(&acc, b, kb);
        return self.finishLin(&acc);
    }

    /// A node equal to n modulo 2^bits (1 <= bits <= 31): masks and constants that only touch
    /// higher bits are dropped. Low bits of a sum, product or left shift only depend on the low
    /// bits of the operands, and those of `and` / `or` / `xor` bit by bit.
    fn lowBits(self: *Normalizer, n: Nf, bits: u32) error{OutOfMemory}!Nf {
        if (self.tagOf(n) != .lin and self.tagOf(n) != .ac and self.tagOf(n) != .shift and self.tagOf(n) != .sel) return n;
        if (self.minTz(n) >= bits) return self.konst(0);
        const key = @as(u64, n) * 32 + bits;
        if (self.low_memo.get(key)) |r| return r;
        const m: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
        self.low_depth += 1;
        defer self.low_depth -= 1;
        var r = n;
        if (self.low_depth <= 8) switch (self.tagOf(n)) {
            .lin => {
                const p = self.payload(n);
                var acc = Lin{ .c = p[0] & m };
                errdefer acc.deinit(self.gpa);
                var i: usize = 1;
                while (i < p.len) : (i += 2) {
                    const atom = self.payload(n)[i];
                    const k = self.payload(n)[i + 1] & m;
                    if (k == 0) continue;
                    try self.addScaled(&acc, try self.lowBits(atom, bits - @ctz(k)), k);
                }
                r = try self.finishLin(&acc);
            },
            .ac => {
                const p = self.payload(n);
                const op: ast.BinOp = @enumFromInt(p[0]);
                const kids = try self.gpa.dupe(u32, p[1..]);
                defer self.gpa.free(kids);
                // Mod 2 a product is the and of its factors' low bits; mod 4 a square a*a is a and 1
                // (an odd square is 1 mod 8, an even one 0 mod 4).
                if (op == .mul and bits == 1) {
                    var r1 = try self.lowBits(kids[0], 1);
                    for (kids[1..]) |kid| r1 = try self.ac(.and_op, r1, try self.lowBits(kid, 1));
                    try self.low_memo.put(self.gpa, key, r1);
                    return r1;
                }
                if (op == .mul and bits == 2 and kids.len == 2 and kids[0] == kids[1]) {
                    const r2 = try self.ac(.and_op, kids[0], try self.konst(1));
                    try self.low_memo.put(self.gpa, key, r2);
                    return r2;
                }
                var acc: ?Nf = null;
                for (kids) |kid| {
                    var v = kid;
                    if (self.constValue(kid)) |c| {
                        const c2 = if (op == .and_op) c | ~m else c & m;
                        if ((op == .and_op and c2 == 0xFFFFFFFF) or (op != .and_op and op != .mul and c2 == 0)) continue;
                        v = try self.konst(c2);
                    } else v = try self.lowBits(kid, bits);
                    acc = if (acc) |a| switch (op) {
                        .xor => try self.xorOf(a, v),
                        else => try self.ac(op, a, v),
                    } else v;
                }
                r = acc orelse try self.konst(if (op == .and_op) 0xFFFFFFFF else 0);
            },
            .sel => {
                const p = self.payload(n);
                const c = p[0];
                const t = p[1];
                const f = p[2];
                const t2 = try self.lowBits(t, bits);
                const f2 = try self.lowBits(f, bits);
                if (t2 != t or f2 != f) r = try self.select(c, t2, f2);
            },
            .shift => {
                const p = self.payload(n);
                if (p[0] == @intFromEnum(ast.BinOp.shl)) {
                    const amts = try self.gpa.dupe(u32, p[2..]);
                    defer self.gpa.free(amts);
                    var v = try self.lowBits(p[1], bits);
                    if (v != p[1]) {
                        for (amts) |s| v = try self.shift(.shl, v, s);
                        r = v;
                    }
                }
            },
            else => {},
        };
        try self.low_memo.put(self.gpa, key, r);
        return r;
    }

    fn scale(self: *Normalizer, a: Nf, k: u32) !Nf {
        return self.affine(a, k, 0);
    }

    /// k * a + c
    fn affine(self: *Normalizer, a: Nf, k: u32, c: u32) !Nf {
        var acc = Lin{ .c = c };
        errdefer acc.deinit(self.gpa);
        try self.addScaled(&acc, a, k);
        return self.finishLin(&acc);
    }

    fn notOf(self: *Normalizer, a: Nf) !Nf {
        return self.affine(a, 0xFFFFFFFF, 0xFFFFFFFF);
    }

    /// If `n` is `k * atom` (no constant, one term), returns it.
    fn scaledAtom(self: *const Normalizer, n: Nf) ?Term {
        if (self.tagOf(n) != .lin) return null;
        const p = self.payload(n);
        if (p.len != 3 or p[0] != 0) return null;
        return .{ .atom = p[1], .coeff = p[2] };
    }

    /// True if `n` has the linear form `S - 1`, i.e. is `not(-S)`.
    fn isNot(self: *const Normalizer, n: Nf) bool {
        return self.tagOf(n) == .lin and self.payload(n)[0] == 0xFFFFFFFF;
    }

    // ---- associative-commutative ops ------------------------------------------------------

    fn ac(self: *Normalizer, op: ast.BinOp, a: Nf, b: Nf) error{OutOfMemory}!Nf {
        var kids = std.ArrayListUnmanaged(Nf){};
        defer kids.deinit(self.gpa);
        var k_const: u32 = switch (op) {
            .and_op => 0xFFFFFFFF,
            .or_op => 0,
            .mul => 1,
            else => unreachable,
        };
        var scalar: u32 = 1; // mul only: product of the coefficients pulled out of `k * atom` operands

        for ([_]Nf{ a, b }) |operand| {
            var n = operand;
            if (op == .mul) {
                if (self.scaledAtom(n)) |t| {
                    scalar *%= t.coeff;
                    n = t.atom;
                }
            }
            if (self.constValue(n)) |c| {
                switch (op) {
                    .and_op => k_const &= c,
                    .or_op => k_const |= c,
                    .mul => k_const *%= c,
                    else => unreachable,
                }
                continue;
            }
            if (self.tagOf(n) == .ac and self.payload(n)[0] == @intFromEnum(op)) {
                try kids.appendSlice(self.gpa, self.payload(n)[1..]);
            } else {
                try kids.append(self.gpa, n);
            }
        }

        if (op == .mul) {
            // mul by a constant is linear.
            const k = scalar *% k_const;
            if (kids.items.len == 0) return self.konst(k);
            // f * (b shl s) with s also a factor: the shift moves onto s, as in `shift`.
            for (kids.items, 0..) |kid, i| {
                const q = self.payload(kid);
                if (self.tagOf(kid) != .shift or q.len != 3 or q[0] != @intFromEnum(ast.BinOp.shl) or q[1] == q[2]) continue;
                const j = std.mem.indexOfScalar(u32, kids.items, q[2]) orelse continue;
                if (j == i) continue;
                const shifted = q[1];
                kids.items[j] = try self.shiftChain(.shl, q[2], q[2]);
                kids.items[i] = shifted;
                var acc = try self.konst(k);
                for (kids.items) |kid2| acc = try self.ac(.mul, acc, kid2);
                return acc;
            }
            // Each factor only matters modulo 2^(32 - t), t the trailing zeros the others always have.
            if (kids.items.len >= 2 and self.low_depth < 4) {
                var changed = false;
                for (kids.items, 0..) |kid, i| {
                    var t: u32 = 0;
                    for (kids.items, 0..) |other, j| if (j != i) {
                        t = @min(32, t + self.minTz(other));
                    };
                    if (t >= 32) return self.konst(0);
                    if (t == 0) continue;
                    const kid2 = try self.lowBits(kid, 32 - t);
                    if (kid2 != kid) {
                        kids.items[i] = kid2;
                        changed = true;
                    }
                }
                if (changed) {
                    self.low_depth += 1;
                    defer self.low_depth -= 1;
                    var acc = try self.konst(k);
                    for (kids.items) |kid| acc = try self.ac(.mul, acc, kid);
                    return acc;
                }
            }
            // f * (c + sum k_i a_i) = c*f + sum k_i (f * a_i), unless f is one of the a_i (the square
            // rules look at such products whole).
            if (kids.items.len == 2) for ([_]usize{ 0, 1 }) |li| {
                const l = kids.items[li];
                const f = kids.items[1 - li];
                if (self.tagOf(l) != .lin or self.tagOf(f) == .lin or self.payload(l).len > 7) continue;
                if (std.mem.indexOfScalar(u32, self.payload(l)[1..], f) != null) continue;
                const q = try self.gpa.dupe(u32, self.payload(l));
                defer self.gpa.free(q);
                var acc = Lin{};
                errdefer acc.deinit(self.gpa);
                try self.addScaled(&acc, f, k *% q[0]);
                var i: usize = 1;
                while (i < q.len) : (i += 2) try self.addScaled(&acc, try self.ac(.mul, f, q[i]), k *% q[i + 1]);
                return self.finishLin(&acc);
            };
            // A single factor is the factor itself: `y mul 8` must be 8·y, the same linear form
            // as `y shl 3` or `(y add y) shl 2`, not 8·mul(y).
            const core = if (kids.items.len == 1) kids.items[0] else try self.acNode(op, kids.items);
            return if (k == 1) core else self.scale(core, k);
        }

        std.sort.pdq(Nf, kids.items, {}, std.sort.asc(Nf));
        var n: usize = 0;
        for (kids.items) |kid| {
            if (n > 0 and kids.items[n - 1] == kid) {
                // and/or are idempotent
            } else {
                kids.items[n] = kid;
                n += 1;
            }
        }
        kids.items.len = n;

        if (op == .and_op) {
            // a mul a is 0, 1 or 4 mod 8: bit 1 is never set.
            for (kids.items) |kid| {
                const q = self.payload(kid);
                if (self.tagOf(kid) == .ac and q[0] == @intFromEnum(ast.BinOp.mul) and q.len == 3 and q[1] == q[2] and k_const != 0xFFFFFFFF) k_const &= ~@as(u32, 2);
            }
            // A mask that covers every bit some other operand can have does nothing.
            const covered = struct {
                fn f(nm: *const Normalizer, ks: []const Nf, mask: u32, skip: ?usize) bool {
                    for (ks, 0..) |kid, i| {
                        if (skip != null and skip.? == i) continue;
                        if (smear(nm.hi(kid)) & ~mask == 0) return true;
                    }
                    return false;
                }
            }.f;
            if (k_const != 0xFFFFFFFF and k_const != 0 and covered(self, kids.items, k_const, null)) k_const = 0xFFFFFFFF;
            var w: usize = 0;
            for (kids.items, 0..) |kid, i| {
                const q = self.payload(kid);
                var drop = false;
                if (self.tagOf(kid) == .ac and q[0] == @intFromEnum(ast.BinOp.or_op)) {
                    for (q[1..]) |kk| if (self.constValue(kk)) |m| {
                        if (covered(self, kids.items, m, i)) drop = true;
                    };
                }
                if (!drop) {
                    kids.items[w] = kid;
                    w += 1;
                }
            }
            kids.items.len = w;
        }

        switch (op) {
            .and_op => {
                if (k_const == 0) return self.konst(0);
                if (k_const != 0xFFFFFFFF) try kids.append(self.gpa, try self.konst(k_const));
                if (kids.items.len == 0) return self.konst(0xFFFFFFFF);
            },
            .or_op => {
                if (k_const == 0xFFFFFFFF) return self.konst(0xFFFFFFFF);
                if (k_const != 0) try kids.append(self.gpa, try self.konst(k_const));
                if (kids.items.len == 0) return self.konst(0);
            },
            else => unreachable,
        }
        if (kids.items.len == 1) return kids.items[0];
        if (op == .and_op) if (try self.andZeroEquivalence(kids.items)) |r| return r;
        if (op == .and_op and self.budget > 0) if (try self.andZeroFacts(kids.items)) |r| return r;
        // De Morgan, one way: and(1 - b1, 1 - b2, ...) = 1 - or(b1, b2, ...) for 0/1 values b_i.
        if (op == .and_op) {
            var all_neg = kids.items.len >= 2;
            for (kids.items) |kid| {
                const q = self.payload(kid);
                if (!(self.tagOf(kid) == .lin and q.len == 3 and q[0] == 1 and q[2] == 0xFFFFFFFF and self.hi(q[1]) <= 1)) all_neg = false;
            }
            if (all_neg) {
                var acc = self.payload(kids.items[0])[1];
                for (kids.items[1..]) |kid| acc = try self.ac(.or_op, acc, self.payload(kid)[1]);
                return self.affine(acc, 0xFFFFFFFF, 1);
            }
        }
        return self.acNode(op, kids.items);
    }

    /// Facts inside an `and` of 0/1 values: a part `zero(d)` means d = 0 in the other parts, and
    /// `[a != 0]` is implied (so dropped) by a part `zero(k*m + c)` with c != 0 and a a factor of m.
    fn andZeroFacts(self: *Normalizer, kids: []const Nf) error{OutOfMemory}!?Nf {
        if (kids.len > 16 or kids.len < 2) return null;
        for (kids) |kid| if (self.hi(kid) > 1) return null;
        var out: [16]Nf = undefined;
        for (kids, 0..) |eq, ei| {
            if (self.tagOf(eq) != .zero) continue;
            const d = self.payload(eq)[0];
            var changed = false;
            for (kids, 0..) |other, oi| {
                out[oi] = other;
                if (oi == ei) continue;
                // [a != 0] = 1 - zero(a), implied by m = -c/k != 0 when a divides m
                const q = self.payload(other);
                if (self.tagOf(other) == .lin and q.len == 3 and q[0] == 1 and q[2] == 0xFFFFFFFF and self.tagOf(q[1]) == .zero) {
                    const a = self.payload(q[1])[0];
                    const dp = self.payload(d);
                    if (self.tagOf(d) == .lin and dp.len == 3 and dp[0] != 0) {
                        const m = dp[1];
                        const mp = self.payload(m);
                        if (m == a or (self.tagOf(m) == .ac and mp[0] == @intFromEnum(ast.BinOp.mul) and std.mem.indexOfScalar(u32, mp[1..], a) != null)) {
                            out[oi] = try self.konst(1);
                            changed = true;
                            continue;
                        }
                    }
                }
                self.budget -|= 1;
                out[oi] = try self.subst(other, d, .is_zero);
                changed = changed or out[oi] != other;
            }
            if (!changed) continue;
            var acc = out[0];
            for (out[1..kids.len]) |o| acc = try self.ac(.and_op, acc, o);
            return acc;
        }
        return null;
    }

    /// In an `and` holding `zero(ka*a + kb*b)` with ka, kb odd: there a = 0 exactly when b = 0, so
    /// `zero(o)` and `1 - zero(o)` on the larger atom o become the same tests on the smaller one.
    fn andZeroEquivalence(self: *Normalizer, kids: []const Nf) error{OutOfMemory}!?Nf {
        if (kids.len > 16) return null;
        for (kids) |eq| {
            if (self.tagOf(eq) != .zero) continue;
            const d = self.payload(eq)[0];
            const p = self.payload(d);
            if (self.tagOf(d) != .lin or p.len != 5 or p[0] != 0 or p[2] & 1 == 0 or p[4] & 1 == 0) continue;
            const small = @min(p[1], p[3]);
            const large = @max(p[1], p[3]);
            const z_large = try self.zeroTest(large);
            const nz_large = try self.affine(z_large, 0xFFFFFFFF, 1);
            var out: [16]Nf = undefined;
            var changed = false;
            for (kids, 0..) |kid, i| {
                out[i] = kid;
                if (kid == z_large) {
                    out[i] = try self.zeroTest(small);
                } else if (kid == nz_large) {
                    out[i] = try self.affine(try self.zeroTest(small), 0xFFFFFFFF, 1);
                }
                // Only a real change, or this would rebuild the same `and` forever.
                changed = changed or out[i] != kid;
            }
            if (!changed) continue;
            var acc = out[0];
            for (out[1..kids.len]) |o| acc = try self.ac(.and_op, acc, o);
            return acc;
        }
        return null;
    }

    /// Writes `n` as `inner xor flip` when its linear form allows it (see `xorOf`).
    fn xorView(self: *Normalizer, n: Nf) !struct { inner: Nf, flip: u32 } {
        if (self.tagOf(n) != .lin) return .{ .inner = n, .flip = 0 };
        const p = self.payload(n);
        // n = S + c with S the terms.
        const flip: u32 = switch (p[0]) {
            0x80000000, 0xFFFFFFFF, 0x7FFFFFFF => p[0],
            else => return .{ .inner = n, .flip = 0 },
        };
        // S + 2^31 = S ^ 2^31;  S - 1 = ~(-S) = (-S) ^ -1;  S + 0x7FFFFFFF = (S - 1) + 2^31 = (-S) ^ 0x7FFFFFFF.
        const k: u32 = if (flip == 0x80000000) 1 else 0xFFFFFFFF;
        var acc = Lin{};
        errdefer acc.deinit(self.gpa);
        var i: usize = 1;
        while (i < p.len) : (i += 2) try acc.terms.append(self.gpa, .{ .atom = p[i], .coeff = k *% p[i + 1] });
        return .{ .inner = try self.finishLin(&acc), .flip = flip };
    }

    fn xorOf(self: *Normalizer, a: Nf, b: Nf) !Nf {
        var kids = std.ArrayListUnmanaged(Nf){};
        defer kids.deinit(self.gpa);
        var k: u32 = 0;
        for ([_]Nf{ a, b }) |operand| {
            const v = try self.xorView(operand);
            k ^= v.flip;
            if (self.tagOf(v.inner) == .ac and self.payload(v.inner)[0] == @intFromEnum(ast.BinOp.xor)) {
                try kids.appendSlice(self.gpa, self.payload(v.inner)[1..]);
            } else {
                try kids.append(self.gpa, v.inner);
            }
        }
        // Fold constants, and cancel pairs (a ^ a = 0).
        var n: usize = 0;
        for (kids.items) |kid| {
            if (self.constValue(kid)) |c| {
                k ^= c;
            } else {
                kids.items[n] = kid;
                n += 1;
            }
        }
        kids.items.len = n;
        std.sort.pdq(Nf, kids.items, {}, std.sort.asc(Nf));
        n = 0;
        for (kids.items) |kid| {
            if (n > 0 and kids.items[n - 1] == kid) {
                n -= 1;
            } else {
                kids.items[n] = kid;
                n += 1;
            }
        }
        kids.items.len = n;

        if (n == 0) return self.konst(k);
        // K ^ p = K - p when every bit p may have is set in K.
        if (n == 1 and smear(self.hi(kids.items[0])) & ~k == 0) return self.affine(kids.items[0], 0xFFFFFFFF, k);
        const core = if (n == 1) kids.items[0] else try self.acNode(.xor, kids.items);
        if (k & 0x7FFFFFFF == 0) return self.affine(core, 1, k); // k is 0 or 2^31
        // core ^ k = ~core ^ (k ^ -1) = -core - 1 + (k ^ -1), with k ^ -1 in {0, 2^31}
        if (k & 0x7FFFFFFF == 0x7FFFFFFF) return self.affine(core, 0xFFFFFFFF, 0xFFFFFFFF +% (k ^ 0xFFFFFFFF));
        try kids.append(self.gpa, try self.konst(k));
        return self.acNode(.xor, kids.items);
    }

    // ---- comparisons ----------------------------------------------------------------------

    /// 1 if d == 0 else 0.
    fn zeroTest(self: *Normalizer, d_raw: Nf) error{OutOfMemory}!Nf {
        if (self.constValue(d_raw)) |c| return self.konst(@intFromBool(c == 0));
        const d_in = try self.nonzeroKey(d_raw);
        if (self.constValue(d_in)) |c| return self.konst(@intFromBool(c == 0));
        if (self.tagOf(d_in) == .lin) {
            const p = self.payload(d_in);
            // c + sum k_i a_i: every term is a multiple of 2^t with t = min ctz(k_i); if c is not, it never cancels.
            var t: u32 = 32;
            var i: usize = 1;
            while (i < p.len) : (i += 2) t = @min(t, @min(32, @ctz(p[i + 1]) + self.minTz(p[i])));
            if (p[0] != 0 and @ctz(p[0]) < t) return self.konst(0);
            if (try self.countEquation(p)) |r| return r;
            // k*(t xor K2) + c == 0 (k odd): t xor K2 = -c/k, so t = (-c/k) xor K2.
            if (p.len == 3 and p[2] & 1 == 1 and self.tagOf(p[1]) == .ac) {
                const q = self.payload(p[1]);
                if (q[0] == @intFromEnum(ast.BinOp.xor) and q.len == 3) {
                    const v = (0 -% p[0]) *% inverseOdd(p[2]);
                    if (self.constValue(q[2])) |k2| return self.zeroTest(try self.affine(q[1], 1, 0 -% (v ^ k2)));
                    if (self.constValue(q[1])) |k2| return self.zeroTest(try self.affine(q[2], 1, 0 -% (v ^ k2)));
                }
            }
            // (a xor b) + 1 == 0  <=>  b == not a  <=>  a + b + 1 == 0
            if (p.len == 3 and ((p[0] == 1 and p[2] == 1) or (p[0] == 0xFFFFFFFF and p[2] == 0xFFFFFFFF)) and self.tagOf(p[1]) == .ac) {
                const q = self.payload(p[1]);
                if (q[0] == @intFromEnum(ast.BinOp.xor) and q.len == 3) return self.zeroTest(try self.linear2(q[1], 1, q[2], 1, 1));
            }
            // k * (a mul a) + c == 0 with k odd: a^2 = -c / k, which must be a square.
            if (p.len == 3 and p[2] & 1 == 1 and self.tagOf(p[1]) == .ac) {
                const q = self.payload(p[1]);
                const n = (0 -% p[0]) *% inverseOdd(p[2]);
                if (q[0] == @intFromEnum(ast.BinOp.mul) and q.len == 3) {
                    if (q[1] == q[2] and !isSquare(n)) return self.konst(0);
                    // a * (a lshr s) == n, a * (a ashr s) == n
                    for ([_][2]Nf{ .{ q[1], q[2] }, .{ q[2], q[1] } }) |pair| {
                        const w = self.payload(pair[1]);
                        if (self.tagOf(pair[1]) != .shift or w.len != 3 or w[1] != pair[0]) continue;
                        const sop: ast.BinOp = @enumFromInt(w[0]);
                        if (sop != .lshr and sop != .ashr) continue;
                        const sv = self.constValue(w[2]) orelse continue;
                        switch (solveMulShift(sop, @truncate(sv), n)) {
                            .none => return self.konst(0),
                            .one => |v| return self.zeroTest(try self.affine(pair[0], 1, 0 -% v)),
                            .unknown => {},
                        }
                    }
                    // a * (a + 2m) = n  <=>  (a + m)^2 = n + m^2
                    for ([_][2]Nf{ .{ q[1], q[2] }, .{ q[2], q[1] } }) |pair| {
                        const w = self.payload(pair[1]);
                        if (self.tagOf(pair[1]) == .lin and w.len == 3 and w[1] == pair[0] and w[2] == 1 and w[0] & 1 == 0) {
                            const half = w[0] >> 1;
                            // 2m may also be w[0] + 2^32, i.e. m = half + 2^31; both give the same m^2 mod 2^32.
                            if (!isSquare(n +% half *% half)) return self.konst(0);
                        }
                        // a * (2m - a) = n  <=>  (a - m)^2 = m^2 - n
                        if (self.tagOf(pair[1]) == .lin and w.len == 3 and w[1] == pair[0] and w[2] == 0xFFFFFFFF and w[0] & 1 == 0) {
                            const half = w[0] >> 1;
                            if (!isSquare(half *% half -% n)) return self.konst(0);
                        }
                    }
                }
            }
        }
        // u * d is zero iff d is, for odd u: scale so that the first coefficient is 1. With an
        // even first coefficient, at least pick d or -d canonically.
        var d = d_in;
        if (self.tagOf(d) == .lin) {
            const k0 = self.payload(d)[2];
            if (k0 & 1 == 1) {
                d = try self.scale(d, inverseOdd(k0));
            } else {
                d = @min(d, try self.scale(d, 0xFFFFFFFF));
            }
        }
        // d = a + c
        var a = d;
        var c: u32 = 0;
        if (self.tagOf(d) == .lin) {
            const p = self.payload(d);
            if (p.len == 3 and p[2] == 1) {
                a = p[1];
                c = p[0];
            }
        }
        if (a != d or self.tagOf(d) != .lin) {
            const h = self.hi(a);
            if (h <= 1) {
                // a in {0, 1}
                if (c == 0) return self.affine(a, 0xFFFFFFFF, 1);
                if (c == 0xFFFFFFFF) return a;
                return self.konst(0);
            }
            if (0 -% c > h) return self.konst(0); // a = -c is out of range
            if (self.tagOf(a) == .un) {
                const inner = self.payload(a)[1];
                switch (@as(ast.UnOp, @enumFromInt(self.payload(a)[0]))) {
                    .clz, .ctz => if (c == 0 -% @as(u32, 32)) return self.zeroTest(inner),
                    .popcount => {
                        if (c == 0) return self.zeroTest(inner);
                        if (c == 0 -% @as(u32, 32)) return self.zeroTest(try self.affine(inner, 1, 1));
                    },
                    else => {},
                }
            }
        }
        // select(c, t, K) == 0 with K != 0: c took the t branch and t == 0 (and symmetrically).
        if (self.tagOf(d) == .sel) {
            const q = self.payload(d);
            if (self.constValue(q[2])) |kf| if (kf != 0)
                return self.ac(.and_op, try self.affine(try self.zeroTest(q[0]), 0xFFFFFFFF, 1), try self.zeroTest(q[1]));
            if (self.constValue(q[1])) |kt| if (kt != 0)
                return self.ac(.and_op, try self.zeroTest(q[0]), try self.zeroTest(q[2]));
        }
        return self.intern(&.{ @intFromEnum(Tag.zero), d });
    }

    /// True when t <= a (unsigned) for every input (see the order rules above).
    fn atMost(self: *const Normalizer, t: Nf, a: Nf) bool {
        return self.atMostDepth(t, a, 4);
    }

    fn atMostDepth(self: *const Normalizer, t: Nf, a: Nf, depth: u8) bool {
        if (t == a) return true;
        if (depth == 0) return false;
        const p = self.payload(t);
        switch (self.tagOf(t)) {
            .shift => if (p[0] == @intFromEnum(ast.BinOp.lshr)) {
                if (self.atMostDepth(p[1], a, depth - 1)) return true;
                // (k*b) lshr s <= b when k <= 2^s: without wrap it is k*b / 2^s <= b; with wrap
                // k*b >= 2^32 forces b >= 2^(32-s), while the result is < 2^(32-s).
                if (p.len == 3) if (self.constValue(p[2])) |sv| if (self.scaledAtom(p[1])) |term| {
                    const sh: u5 = @truncate(sv);
                    if (term.coeff <= (@as(u64, 1) << sh) and self.atMostDepth(term.atom, a, depth - 1)) return true;
                };
            },
            .ac => if (p[0] == @intFromEnum(ast.BinOp.and_op)) {
                for (p[1..]) |kid| if (self.atMostDepth(kid, a, depth - 1)) return true;
            },
            .un => if (p[0] == @intFromEnum(ast.UnOp.popcount)) return self.atMostDepth(p[1], a, depth - 1),
            .lin => if (self.scaledAtom(t)) |term| {
                // k * (b lshr s) <= 2^s * (b lshr s) <= b when k <= 2^s (and so never wraps).
                const q = self.payload(term.atom);
                if (self.tagOf(term.atom) == .shift and q[0] == @intFromEnum(ast.BinOp.lshr) and q.len == 3) if (self.constValue(q[2])) |sv| {
                    const sh: u5 = @truncate(sv);
                    if (term.coeff <= (@as(u64, 1) << sh) and self.atMostDepth(q[1], a, depth - 1)) return true;
                };
            },
            else => {},
        }
        return false;
    }

    /// True when t <= a always and t < a whenever a != 0.
    fn strictlyBelow(self: *const Normalizer, t: Nf, a: Nf) bool {
        const p = self.payload(t);
        switch (self.tagOf(t)) {
            .shift => if (p[0] == @intFromEnum(ast.BinOp.lshr)) {
                // b lshr s with a constant s & 31 >= 1 and b <= a: < b <= a when b > 0, else 0 < a.
                if (self.atMost(p[1], a)) for (p[2..]) |amt| {
                    if (self.constValue(amt)) |sv| if (sv & 31 != 0) return true;
                };
                // (k*b) lshr s with k < 2^s.
                if (p.len == 3) if (self.constValue(p[2])) |sv| if (self.scaledAtom(p[1])) |term| {
                    const sh: u5 = @truncate(sv);
                    if (term.coeff < (@as(u64, 1) << sh) and self.atMost(term.atom, a)) return true;
                };
            },
            .lin => {
                if (self.scaledAtom(t)) |term| {
                    // k * (b lshr s) with k < 2^s.
                    const q = self.payload(term.atom);
                    if (self.tagOf(term.atom) == .shift and q[0] == @intFromEnum(ast.BinOp.lshr) and q.len == 3) if (self.constValue(q[2])) |sv| {
                        const sh: u5 = @truncate(sv);
                        if (term.coeff < (@as(u64, 1) << sh) and self.atMost(q[1], a)) return true;
                    };
                }
                // a - popcount(a)
                if (p.len == 5 and p[0] == 0) for ([_]usize{ 1, 3 }) |i| {
                    const j: usize = 4 - i;
                    const pc = self.payload(p[j]);
                    if (p[i] == a and p[i + 1] == 1 and p[j + 1] == 0xFFFFFFFF and self.tagOf(p[j]) == .un and pc[0] == @intFromEnum(ast.UnOp.popcount) and pc[1] == a) return true;
                };
            },
            else => {},
        }
        return false;
    }

    /// A lower bound on the number of trailing zero bits of n, for every input.
    fn minTz(self: *const Normalizer, n: Nf) u32 {
        return self.minTzDepth(n, 6);
    }

    fn minTzDepth(self: *const Normalizer, n: Nf, depth: u8) u32 {
        if (depth == 0) return 0;
        const p = self.payload(n);
        return switch (self.tagOf(n)) {
            .konst => if (p[0] == 0) 32 else @ctz(p[0]),
            .lin => blk: {
                var m: u32 = if (p[0] == 0) 32 else @ctz(p[0]);
                var i: usize = 1;
                while (i < p.len) : (i += 2) m = @min(m, @min(32, self.minTzDepth(p[i], depth - 1) + @ctz(p[i + 1])));
                break :blk m;
            },
            .ac => blk: {
                const op: ast.BinOp = @enumFromInt(p[0]);
                var m: u32 = switch (op) {
                    .and_op => 0,
                    .mul => 0,
                    else => 32,
                };
                for (p[1..]) |kid| {
                    const k = self.minTzDepth(kid, depth - 1);
                    m = switch (op) {
                        .and_op => @max(m, k),
                        .mul => @min(32, m + k),
                        else => @min(m, k), // or, xor
                    };
                }
                // a * (k a + c) with k, c odd: if a is odd, k a + c is even. Either way one factor is.
                if (op == .mul and p.len == 3 and m == 0 and (self.oddAffineOf(p[1], p[2]) or self.oddAffineOf(p[2], p[1]))) m = 1;
                break :blk m;
            },
            // shl only adds zero bits at the bottom.
            // a shl a is even: an odd a moves by a & 31 >= 1.
            .shift => if (p[0] == @intFromEnum(ast.BinOp.shl)) @max(self.minTzDepth(p[1], depth - 1), @intFromBool(p.len == 3 and p[1] == p[2])) else 0,
            .sel => @min(self.minTzDepth(p[1], depth - 1), self.minTzDepth(p[2], depth - 1)),
            else => 0,
        };
    }

    /// b when n is `b lshr ctz(b)` or `b shl clz(b)`: only zero bits are shifted out.
    fn zeroShiftBase(self: *const Normalizer, n: Nf) ?Nf {
        const p = self.payload(n);
        if (self.tagOf(n) != .shift or p.len != 3 or self.tagOf(p[2]) != .un) return null;
        const q = self.payload(p[2]);
        if (q[1] != p[1]) return null;
        if (p[0] == @intFromEnum(ast.BinOp.lshr) and q[0] == @intFromEnum(ast.UnOp.ctz)) return p[1];
        if (p[0] == @intFromEnum(ast.BinOp.shl) and q[0] == @intFromEnum(ast.UnOp.clz)) return p[1];
        return null;
    }

    /// True when n is `2^j shl s` or `2^j lshr s` (one set bit, shifted).
    fn isPow2Shl(self: *const Normalizer, n: Nf) bool {
        const p = self.payload(n);
        if (self.tagOf(n) != .shift or (p[0] != @intFromEnum(ast.BinOp.shl) and p[0] != @intFromEnum(ast.BinOp.lshr))) return false;
        const kb = self.constValue(p[1]) orelse return false;
        return kb != 0 and kb & (kb - 1) == 0;
    }

    /// n = c + k*b with b in {0, 1} (not a constant).
    fn boolAffine(self: *const Normalizer, n: Nf) ?struct { b: Nf, k: u32, c: u32 } {
        if (self.constValue(n) != null) return null;
        if (self.hi(n) <= 1 and self.tagOf(n) != .lin) return .{ .b = n, .k = 1, .c = 0 };
        const p = self.payload(n);
        if (self.tagOf(n) == .lin and p.len == 3 and self.hi(p[1]) <= 1 and self.constValue(p[1]) == null) return .{ .b = p[1], .k = p[2], .c = p[0] };
        return null;
    }

    /// True when n is odd for every input.
    fn knownOdd(self: *const Normalizer, n: Nf) bool {
        const p = self.payload(n);
        return switch (self.tagOf(n)) {
            .konst => p[0] & 1 == 1,
            .ac => switch (@as(ast.BinOp, @enumFromInt(p[0]))) {
                .or_op => for (p[1..]) |kid| {
                    if (self.knownOdd(kid)) break true;
                } else false,
                .mul, .and_op => for (p[1..]) |kid| {
                    if (!self.knownOdd(kid)) break false;
                } else true,
                else => false,
            },
            .sel => self.knownOdd(p[1]) and self.knownOdd(p[2]),
            .lin => p[0] & 1 == 1 and self.minTz(n) == 0 and blk: {
                // c odd and every term even
                var i: usize = 1;
                while (i < p.len) : (i += 2) if (@min(32, @ctz(p[i + 1]) + self.minTz(p[i])) == 0) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    /// True when w = k*a + c with k and c odd, or w = a xor K with K odd: w and a differ in parity.
    fn oddAffineOf(self: *const Normalizer, w: Nf, a: Nf) bool {
        const p = self.payload(w);
        if (self.tagOf(w) == .lin and p.len == 3 and p[1] == a and p[0] & 1 == 1 and p[2] & 1 == 1) return true;
        // a xor K with K odd flips the low bit of a.
        if (self.tagOf(w) == .ac and p[0] == @intFromEnum(ast.BinOp.xor) and p.len == 3) {
            if (p[1] == a) if (self.constValue(p[2])) |kk| return kk & 1 == 1;
            if (p[2] == a) if (self.constValue(p[1])) |kk| return kk & 1 == 1;
        }
        return false;
    }

    const MulShiftSolution = union(enum) { none, one: u32, unknown };

    /// Solves a * (a op s) == n for a, op lshr or ashr (see the rules above).
    fn solveMulShift(op: ast.BinOp, s: u5, n: u32) MulShiftSolution {
        if (s == 0) return .unknown;
        var found: ?u32 = null;
        var count: usize = 0;
        const add = struct {
            fn f(fo: *?u32, c: *usize, a: u32) void {
                if (fo.* == null or fo.*.? != a) c.* += 1;
                fo.* = a;
            }
        }.f;
        const hbits: u6 = 32 - @as(u6, s);
        if (s >= 16) {
            const span: u32 = @as(u32, 1) << @intCast(hbits);
            var hh: u32 = 0;
            while (hh < span) : (hh += 1) {
                // a lshr s ranges over [0, 2^(32-s)); a ashr s over [-2^(31-s), 2^(31-s)).
                const h: u32 = if (op == .ashr and hh >= span / 2) hh -% span else hh;
                const rhs = n -% ((h << s) *% h);
                if (h == 0) {
                    if (rhs == 0) return .unknown; // every l < 2^s works
                    continue;
                }
                const g: u5 = @intCast(@ctz(h));
                if (rhs != 0 and @ctz(rhs) < g) continue;
                const modbits: u6 = 32 - @as(u6, g);
                const l0_full = (rhs >> g) *% inverseOdd(h >> g);
                const l0 = if (modbits >= 32) l0_full else l0_full & ((@as(u32, 1) << @intCast(modbits)) - 1);
                // Solutions are l0 + j * 2^(32-g); those below 2^s are the valid low parts.
                var l: u64 = l0;
                while (l < (@as(u64, 1) << s)) : (l += @as(u64, 1) << modbits) {
                    add(&found, &count, (h << s) +% @as(u32, @intCast(l)));
                    if (count > 1) return .unknown;
                }
            }
        } else if (s <= 8) {
            var budget: usize = 1 << 22;
            var stack: [64]struct { k: u6, h: u32 } = undefined;
            var l: u32 = 0;
            while (l < (@as(u32, 1) << s)) : (l += 1) {
                var sp: usize = 1;
                stack[0] = .{ .k = 0, .h = 0 };
                while (sp > 0) {
                    sp -= 1;
                    const node = stack[sp];
                    if (budget == 0) return .unknown;
                    budget -= 1;
                    if (node.k == 32) {
                        const h = node.h;
                        const in_range = if (op == .lshr) (h >> @intCast(hbits)) == 0 else blk: {
                            const top: i32 = @as(i32, @bitCast(h)) >> @intCast(hbits - 1);
                            break :blk top == 0 or top == -1;
                        };
                        if (in_range) {
                            add(&found, &count, (h << s) +% l);
                            if (count > 1) return .unknown;
                        }
                        continue;
                    }
                    for ([_]u32{ 0, 1 }) |bit| {
                        const h = node.h | (bit << @intCast(node.k));
                        const kk: u6 = node.k + 1;
                        const mask: u32 = if (kk == 32) 0xFFFFFFFF else (@as(u32, 1) << @intCast(kk)) - 1;
                        const v = ((h << s) *% h) +% (l *% h);
                        if ((v ^ n) & mask == 0) {
                            if (sp == stack.len) return .unknown;
                            stack[sp] = .{ .k = kk, .h = h };
                            sp += 1;
                        }
                    }
                }
            }
        } else return .unknown;
        if (count == 0) return .none;
        return .{ .one = found.? };
    }

    /// Whether some u32 z has z * z == n (mod 2^32).
    fn isSquare(n: u32) bool {
        if (n == 0) return true;
        const v = @ctz(n);
        if (v & 1 == 1) return false;
        const bits = 32 - v; // the odd part of z^2 is only known mod 2^bits
        const u = n >> @intCast(v);
        if (bits >= 3) return u & 7 == 1;
        if (bits == 2) return u & 3 == 1;
        return true;
    }

    /// `k a + j f(a) + c == 0` with f in {popcount, clz, ctz} (values 0..32) and k odd: tries the
    /// 33 possible values of a. Returns null when the shape does not match or several values fit.
    fn countEquation(self: *Normalizer, p: []const u32) !?Nf {
        if (p.len != 5) return null;
        for ([_]usize{ 1, 3 }) |i| {
            const j: usize = 4 - i;
            const a = p[i];
            const k = p[i + 1];
            const f = p[j];
            const jk = p[j + 1];
            if (k & 1 == 0 or self.tagOf(f) != .un or self.payload(f)[1] != a) continue;
            const op: ast.UnOp = @enumFromInt(self.payload(f)[0]);
            const inv = inverseOdd(k);
            var hit: ?u32 = null;
            var hits: usize = 0;
            for (0..33) |pv| {
                const v = (0 -% (p[0] +% jk *% @as(u32, @intCast(pv)))) *% inv;
                const fv: u32 = switch (op) {
                    .popcount => @popCount(v),
                    .clz => @clz(v),
                    .ctz => @ctz(v),
                    else => return null,
                };
                if (fv == pv) {
                    if (hit == null or hit.? != v) hits += 1;
                    hit = v;
                }
            }
            if (hits == 0) return try self.konst(0);
            if (hits == 1) return try self.zeroTest(try self.affine(a, 1, 0 -% hit.?));
            return null;
        }
        return null;
    }

    fn ult(self: *Normalizer, a: Nf, b: Nf) !Nf {
        if (a == b) return self.konst(0);
        // a lshr s <= a and a and c <= a, so a < either is false; a or c >= a, so it is never < a.
        const pb = self.payload(b);
        if (self.atMost(b, a)) return self.konst(0);
        // b in {0, 1}: a < b exactly when b == 1 and a == 0.
        if (self.constValue(b) == null and self.hi(b) <= 1) return self.ac(.and_op, b, try self.zeroTest(a));
        // a < b with a strictly below b unless b == 0: exactly b != 0.
        if (self.strictlyBelow(a, b)) return self.affine(try self.zeroTest(b), 0xFFFFFFFF, 1);
        const pa = self.payload(a);
        if (self.tagOf(a) == .ac and pa[0] == @intFromEnum(ast.BinOp.or_op) and std.mem.indexOfScalar(u32, pa[1..], b) != null) return self.konst(0);
        // b = a - t with t <= a: b is in [0, a].
        if (self.tagOf(b) == .lin and pb.len == 5 and pb[0] == 0) {
            for ([_]usize{ 1, 3 }) |i| {
                const j: usize = 4 - i;
                if (pb[i] == a and pb[i + 1] == 1 and pb[j + 1] == 0xFFFFFFFF and self.atMost(pb[j], a)) return self.konst(0);
            }
        }
        const ca = self.constValue(a);
        const cb = self.constValue(b);
        if (ca != null and cb != null) return self.konst(@intFromBool(ca.? < cb.?));
        // Comparisons against the top bit: one form, a lshr 31.
        if (ca != null and ca.? == 0x7FFFFFFF) return self.shift(.lshr, b, try self.konst(31));
        if (cb != null and cb.? == 0x80000000) return self.affine(try self.shift(.lshr, a, try self.konst(31)), 0xFFFFFFFF, 1);
        if (cb) |k| {
            if (k == 0) return self.konst(0);
            if (self.hi(a) < k) return self.konst(1);
            if (k == 1) return self.zeroTest(a);
            // a <= k, so a < k iff a != k
            if (self.hi(a) == k) return self.affine(try self.zeroTest(try self.affine(a, 1, 0 -% k)), 0xFFFFFFFF, 1);
        }
        if (ca) |k| {
            if (k == 0xFFFFFFFF or self.hi(b) <= k) return self.konst(0);
            if (k == 0) return self.affine(try self.zeroTest(b), 0xFFFFFFFF, 1);
            // b <= k + 1, so k < b iff b == k + 1
            if (self.hi(b) == k + 1) return self.zeroTest(try self.affine(b, 1, 0 -% (k + 1)));
        }
        return self.intern(&.{ @intFromEnum(Tag.bin), @intFromEnum(ast.BinOp.ult), a, b });
    }

    // ---- interval tests -------------------------------------------------------------------
    //
    // A 0/1 value built from `u ult K`, `K ult u`, `u == 0` and `u lshr 31` with u = t + c or
    // u = c - t, combined with and / or / 1 - b, is "t lies in a set of values". When that set is
    // one interval (cyclically), the test gets one form, however it was written.

    const Iv = struct { lo: u32, hi: u32 };
    const IvSet = struct {
        n: usize = 0,
        iv: [8]Iv = undefined,

        fn full() IvSet {
            var r = IvSet{ .n = 1 };
            r.iv[0] = .{ .lo = 0, .hi = 0xFFFFFFFF };
            return r;
        }
        fn push(r: *IvSet, lo: u32, hi_: u32) bool {
            if (r.n == r.iv.len) return false;
            r.iv[r.n] = .{ .lo = lo, .hi = hi_ };
            r.n += 1;
            return true;
        }
        /// Adds [lo, lo + len) taken mod 2^32 (1 <= len <= 2^32).
        fn pushCyclic(r: *IvSet, lo: u32, len: u64) bool {
            if (len >= 1 << 32) return r.push(0, 0xFFFFFFFF);
            const end = @as(u64, lo) + len - 1;
            if (end <= 0xFFFFFFFF) return r.push(lo, @intCast(end));
            return r.push(lo, 0xFFFFFFFF) and r.push(0, @intCast(end - (1 << 32)));
        }
        fn normalized(r: IvSet) IvSet {
            var v = r;
            std.sort.pdq(Iv, v.iv[0..v.n], {}, struct {
                fn f(_: void, a: Iv, b: Iv) bool {
                    return a.lo < b.lo;
                }
            }.f);
            var w: usize = 0;
            for (v.iv[0..v.n]) |x| {
                if (w > 0 and @as(u64, x.lo) <= @as(u64, v.iv[w - 1].hi) + 1) {
                    v.iv[w - 1].hi = @max(v.iv[w - 1].hi, x.hi);
                } else {
                    v.iv[w] = x;
                    w += 1;
                }
            }
            v.n = w;
            return v;
        }
        fn complement(r: IvSet) IvSet {
            const v = r.normalized();
            var out = IvSet{};
            var next: u64 = 0;
            for (v.iv[0..v.n]) |x| {
                if (x.lo > next) _ = out.push(@intCast(next), x.lo - 1);
                next = @as(u64, x.hi) + 1;
            }
            if (next <= 0xFFFFFFFF) _ = out.push(@intCast(next), 0xFFFFFFFF);
            return out;
        }
        fn unite(a: IvSet, b: IvSet) ?IvSet {
            var r = a.normalized();
            for (b.iv[0..b.n]) |x| if (!r.push(x.lo, x.hi)) {
                r = r.normalized();
                if (!r.push(x.lo, x.hi)) return null;
            };
            return r.normalized();
        }
    };
    const Pred = struct { atom: ?Nf, set: IvSet };

    /// n as t + c or c - t: { t, sign (1 or -1), c }. For `k*a + c` the term t is `k*a` or `(-k)*a`,
    /// whichever coefficient is at most 2^31, so `k*a` and `c - k*a` share it.
    fn affineView(self: *Normalizer, n: Nf) error{OutOfMemory}!?struct { t: Nf, s: u32, c: u32 } {
        switch (self.tagOf(n)) {
            .konst => return null,
            .lin => {
                const p = self.payload(n);
                if (p.len != 3) return null;
                const atom = p[1];
                const k = p[2];
                const c = p[0];
                if (k == 1 or k == 0xFFFFFFFF) return .{ .t = atom, .s = k, .c = c };
                if (k <= 0x80000000) return .{ .t = try self.scale(atom, k), .s = 1, .c = c };
                return .{ .t = try self.scale(atom, 0 -% k), .s = 0xFFFFFFFF, .c = c };
            },
            else => return .{ .t = n, .s = 1, .c = 0 },
        }
    }

    /// The t-values for which u = s*t + c lies in [lo, hi].
    fn predOfU(self: *Normalizer, u: Nf, lo: u32, hi_: u32) error{OutOfMemory}!?Pred {
        const v = (try self.affineView(u)) orelse return null;
        var set = IvSet{};
        const len = @as(u64, hi_) - lo + 1;
        const start = if (v.s == 1) lo -% v.c else v.c -% hi_;
        if (!set.pushCyclic(start, len)) return null;
        return .{ .atom = v.t, .set = set.normalized() };
    }

    fn predOf(self: *Normalizer, n: Nf, depth: u8) error{OutOfMemory}!?Pred {
        if (depth == 0) return null;
        const p = self.payload(n);
        switch (self.tagOf(n)) {
            .konst => return switch (p[0]) {
                0 => .{ .atom = null, .set = .{} },
                1 => .{ .atom = null, .set = IvSet.full() },
                else => null,
            },
            .bin => {
                if (p[0] != @intFromEnum(ast.BinOp.ult)) return null;
                if (self.constValue(p[2])) |k| return if (k == 0) null else try self.predOfU(p[1], 0, k - 1);
                if (self.constValue(p[1])) |k| return if (k == 0xFFFFFFFF) null else try self.predOfU(p[2], k + 1, 0xFFFFFFFF);
                return null;
            },
            .zero => return try self.predOfU(p[0], 0, 0),
            .shift => {
                if (p.len != 3 or p[0] != @intFromEnum(ast.BinOp.lshr)) return null;
                const k = self.constValue(p[2]) orelse return null;
                if (k != 31) return null;
                return try self.predOfU(p[1], 0x80000000, 0xFFFFFFFF);
            },
            .lin => {
                if (p.len != 3 or p[0] != 1 or p[2] != 0xFFFFFFFF) return null;
                const inner = (try self.predOf(p[1], depth - 1)) orelse return null;
                return .{ .atom = inner.atom, .set = inner.set.complement() };
            },
            .ac => {
                const op: ast.BinOp = @enumFromInt(p[0]);
                if (op != .and_op and op != .or_op) return null;
                var acc: ?Pred = null;
                const kids = try self.gpa.dupe(u32, p[1..]);
                defer self.gpa.free(kids);
                for (kids) |kid| {
                    var q = (try self.predOf(kid, depth - 1)) orelse return null;
                    if (op == .and_op) q.set = q.set.complement(); // and = not(or(not ...))
                    if (q.atom == null) {
                        if (acc) |*a| a.set = IvSet.unite(a.set, q.set) orelse return null else acc = q;
                        continue;
                    }
                    if (acc) |*a| {
                        if (a.atom != null and q.atom != null and a.atom.? != q.atom.?) {
                            // `a == 0` is `k*a == 0` for odd k: move a point at 0 onto the other's term.
                            if (self.zeroAligns(q, a.atom.?)) {
                                q.atom = a.atom;
                            } else if (self.zeroAligns(a.*, q.atom.?)) {
                                a.atom = q.atom;
                            } else return null;
                        }
                        a.atom = a.atom orelse q.atom;
                        a.set = IvSet.unite(a.set, q.set) orelse return null;
                    } else acc = q;
                }
                var r = acc orelse return null;
                if (op == .and_op) r.set = r.set.complement();
                return r;
            },
            else => return null,
        }
    }

    /// True when p only tells 0 from nonzero for its term a (the set is {0} or all but 0) and
    /// `other` is `k*a` with k odd, which is 0 exactly when a is.
    fn zeroAligns(self: *const Normalizer, p: Pred, other: Nf) bool {
        const s = p.set.normalized();
        const is_zero = s.n == 1 and s.iv[0].lo == 0 and s.iv[0].hi == 0;
        const non_zero = s.n == 1 and s.iv[0].lo == 1 and s.iv[0].hi == 0xFFFFFFFF;
        if (!is_zero and !non_zero) return false;
        if (self.tagOf(other) != .lin) return false;
        const q = self.payload(other);
        return q.len == 3 and q[0] == 0 and q[1] == p.atom.? and q[2] & 1 == 1;
    }

    /// One form for a 0/1 value that tests whether a single term lies in an interval.
    fn canonPred(self: *Normalizer, r: Nf) error{OutOfMemory}!Nf {
        if (self.hi(r) > 1 or self.constValue(r) != null) return r;
        const pr = (try self.predOf(r, 6)) orelse return r;
        const t = pr.atom orelse return r;
        const set = pr.set.normalized();
        if (set.n == 0) return self.konst(0);
        var lo: u32 = undefined;
        var len: u64 = undefined;
        if (set.n == 1) {
            lo = set.iv[0].lo;
            len = @as(u64, set.iv[0].hi) - lo + 1;
        } else if (set.n == 2 and set.iv[0].lo == 0 and set.iv[1].hi == 0xFFFFFFFF) {
            lo = set.iv[1].lo;
            len = (@as(u64, set.iv[0].hi) + 1) + ((1 << 32) - @as(u64, lo));
        } else return r;
        if (len >= 1 << 32) return self.konst(1);
        // An interval that wraps around to end at 0 is `[lo, -1] or t == 0`: branch facts about
        // t != 0 can then drop the second part.
        if (lo != 0 and (@as(u64, lo) + len) == (1 << 32) + 1)
            return self.ac(.or_op, try self.emitInterval(t, lo, len - 1), try self.zeroTest(t));
        // Likewise [1, len] is the negation of `[len + 1, -1] or t == 0`.
        if (lo == 1 and len < (1 << 32) - 1)
            return self.affine(try self.ac(.or_op, try self.emitInterval(t, @intCast(len + 1), (1 << 32) - len - 1), try self.zeroTest(t)), 0xFFFFFFFF, 1);
        return self.emitInterval(t, lo, len);
    }

    /// The canonical test for t in [lo, lo + len) mod 2^32, 1 <= len < 2^32.
    fn emitInterval(self: *Normalizer, t: Nf, lo: u32, len: u64) error{OutOfMemory}!Nf {
        const half: u64 = 1 << 31;
        if (len == 1) return self.zeroTest(try self.affine(t, 1, 0 -% lo));
        if (len == (1 << 32) - 1) return self.affine(try self.zeroTest(try self.affine(t, 1, 0 -% (lo +% 0xFFFFFFFF))), 0xFFFFFFFF, 1);
        if (len == half and (lo == 0 or lo == 0x80000000)) {
            const top = try self.shiftChain(.lshr, t, try self.konst(31));
            return if (lo == 0x80000000) top else self.affine(top, 0xFFFFFFFF, 1);
        }
        const lo2 = lo +% @as(u32, @truncate(len));
        const positive = len < half or (len == half and lo < lo2);
        if (positive) return self.intern(&.{ @intFromEnum(Tag.bin), @intFromEnum(ast.BinOp.ult), try self.affine(t, 1, 0 -% lo), try self.konst(@intCast(len)) });
        const neg = try self.intern(&.{ @intFromEnum(Tag.bin), @intFromEnum(ast.BinOp.ult), try self.affine(t, 1, 0 -% lo2), try self.konst(@intCast((1 << 32) - len)) });
        return self.affine(neg, 0xFFFFFFFF, 1);
    }

    fn slt(self: *Normalizer, a: Nf, b: Nf) !Nf {
        // 0 < u (signed): neither negative nor 0.
        if (self.constValue(a)) |ka| if (ka == 0 and self.constValue(b) == null)
            return self.affine(try self.ac(.or_op, try self.shift(.lshr, b, try self.konst(31)), try self.zeroTest(b)), 0xFFFFFFFF, 1);
        // a < 0 (signed) is the sign bit: one form for `a slt 0` and `a lshr 31`.
        if (self.constValue(b)) |kb| if (kb == 0) return self.shift(.lshr, a, try self.konst(31));
        // a < 1 is a < 0 or a == 0 (branch facts can then drop either part).
        if (self.constValue(b)) |kb| if (kb == 1) return self.ac(.or_op, try self.shift(.lshr, a, try self.konst(31)), try self.zeroTest(a));
        // b <= a (unsigned) and b >= 0: a < b (signed) exactly when a is negative.
        if (b != a and self.hi(b) <= 0x7FFFFFFF and self.atMost(b, a)) return self.slt(a, try self.konst(0));
        if (self.hi(a) <= 0x7FFFFFFF and self.hi(b) <= 0x7FFFFFFF) return self.ult(a, b);
        return self.ult(try self.affine(a, 1, 0x80000000), try self.affine(b, 1, 0x80000000));
    }

    fn acNode(self: *Normalizer, op: ast.BinOp, kids: []Nf) !Nf {
        std.sort.pdq(Nf, kids, {}, std.sort.asc(Nf));
        var key = try std.ArrayListUnmanaged(u32).initCapacity(self.gpa, 2 + kids.len);
        defer key.deinit(self.gpa);
        key.appendAssumeCapacity(@intFromEnum(Tag.ac));
        key.appendAssumeCapacity(@intFromEnum(op));
        key.appendSliceAssumeCapacity(kids);
        return self.intern(key.items);
    }

    // ---- shifts ---------------------------------------------------------------------------

    /// `base op amt` where amt is not a constant (or op is not shl); merges chains of `op`.
    fn shiftChain(self: *Normalizer, op: ast.BinOp, base: Nf, amt: Nf) !Nf {
        const n = try self.shiftChainRaw(op, base, amt);
        // Shifted right far enough that nothing can be left.
        if (op != .shl and self.hi(n) == 0) return self.konst(0);
        return n;
    }

    fn shiftChainRaw(self: *Normalizer, op: ast.BinOp, base: Nf, amt: Nf) !Nf {
        var key = std.ArrayListUnmanaged(u32){};
        defer key.deinit(self.gpa);
        try key.appendSlice(self.gpa, &.{ @intFromEnum(Tag.shift), @intFromEnum(op) });
        if (self.tagOf(base) == .shift and self.payload(base)[0] == @intFromEnum(op)) {
            try key.appendSlice(self.gpa, self.payload(base)[1..]);
        } else {
            try key.append(self.gpa, base);
        }
        try key.append(self.gpa, amt);
        std.sort.pdq(u32, key.items[3..], {}, std.sort.asc(u32));
        return self.intern(key.items);
    }

    fn shift(self: *Normalizer, op: ast.BinOp, a: Nf, s: Nf) !Nf {
        if (self.constValue(s)) |sv| {
            const k: u5 = @truncate(sv);
            if (k == 0) return a;
            if (self.constValue(a)) |av| return self.konst(switch (op) {
                .shl => av << k,
                .lshr => av >> k,
                .ashr => @bitCast(@as(i32, @bitCast(av)) >> k),
                else => unreachable,
            });
            if (op == .shl) return self.scale(a, @as(u32, 1) << k);
            // Top bit of a linear form whose constant only keeps or flips the top bit of the rest:
            // 0x7fffffff - u = u xor 0x7fffffff (same), w + 0x80000000 = w xor 0x80000000 and
            // -1 - w = not w (flipped). Each rewrite leaves a form with constant 0.
            if (op == .lshr and k == 31 and self.tagOf(a) == .lin) {
                const c = self.payload(a)[0];
                if (c == 0x7FFFFFFF) return self.shift(.lshr, try self.affine(a, 0xFFFFFFFF, 0x7FFFFFFF), try self.konst(31));
                if (c == 0x80000000) return self.affine(try self.shift(.lshr, try self.affine(a, 1, 0x80000000), try self.konst(31)), 0xFFFFFFFF, 1);
                if (c == 0xFFFFFFFF) return self.affine(try self.shift(.lshr, try self.affine(a, 0xFFFFFFFF, 0xFFFFFFFF), try self.konst(31)), 0xFFFFFFFF, 1);
            }
            // a ashr 31 is 0 or -1: the negated sign bit.
            if (op == .ashr and k == 31) return self.scale(try self.shift(.lshr, a, try self.konst(31)), 0xFFFFFFFF);
            return self.shiftChain(op, a, try self.konst(k));
        }
        if (self.constValue(a)) |av| if (av == 0) return self.konst(0);
        // The top bit survives a left shift only by a multiple of 32.
        if (op == .shl and self.constValue(a) != null and self.constValue(a).? == 0x80000000 and self.budget > 0)
            return self.select(try self.zeroTest(try self.ac(.and_op, s, try self.konst(31))), a, try self.konst(0));
        if (op != .shl) return self.shiftChain(op, a, s);
        // (s * f) shl s = f * (s shl s): the shift goes onto the factor that is its own amount.
        if (self.tagOf(a) == .ac and self.payload(a)[0] == @intFromEnum(ast.BinOp.mul) and std.mem.indexOfScalar(u32, self.payload(a)[1..], s) != null) {
            const kids = try self.gpa.dupe(u32, self.payload(a)[1..]);
            defer self.gpa.free(kids);
            var acc = try self.shiftChain(.shl, s, s);
            var used = false;
            for (kids) |kid| {
                if (kid == s and !used) {
                    used = true;
                    continue;
                }
                acc = try self.ac(.mul, acc, kid);
            }
            return acc;
        }

        // shl s multiplies by 2^(s & 31), so it distributes over a linear combination.
        var acc = Lin{};
        errdefer acc.deinit(self.gpa);
        switch (self.tagOf(a)) {
            .lin => {
                const p = self.payload(a);
                if (p[0] != 0) try acc.terms.append(self.gpa, .{ .atom = try self.shiftChain(op, try self.konst(p[0]), s), .coeff = 1 });
                var i: usize = 1;
                while (i < p.len) : (i += 2) {
                    const atom = self.payload(a)[i];
                    const coeff = self.payload(a)[i + 1];
                    try self.addScaled(&acc, try self.shift(op, atom, s), coeff);
                }
            },
            else => try acc.terms.append(self.gpa, .{ .atom = try self.shiftChain(op, a, s), .coeff = 1 }),
        }
        return self.finishLin(&acc);
    }

    // ---- select ---------------------------------------------------------------------------

    const Fact = enum {
        /// The node is 0.
        is_zero,
        /// The node is not 0.
        nonzero,
    };

    /// Rebuilds `n` under a fact about `target`. Only sound where the fact holds, i.e. inside the
    /// matching branch of a select on `target`.
    fn subst(self: *Normalizer, n: Nf, target: Nf, fact: Fact) error{OutOfMemory}!Nf {
        if (self.subst_depth == self.subst_memos.items.len) {
            const m = try self.gpa.create(std.AutoHashMapUnmanaged(Nf, Nf));
            m.* = .{};
            self.subst_memos.append(self.gpa, m) catch |err| {
                self.gpa.destroy(m);
                return err;
            };
        }
        const memo = self.subst_memos.items[self.subst_depth];
        memo.clearRetainingCapacity();
        self.subst_depth += 1;
        defer self.subst_depth -= 1;
        return self.substRec(n, target, fact, memo);
    }

    fn substRec(self: *Normalizer, n: Nf, target: Nf, fact: Fact, memo: *std.AutoHashMapUnmanaged(Nf, Nf)) error{OutOfMemory}!Nf {
        if (memo.get(n)) |r| return r;
        if (self.budget == 0) return n; // leaving n unchanged is valid under any fact
        self.budget -= 1;
        const p = self.payload(n);
        const result: Nf = blk: {
            switch (fact) {
                .is_zero => {
                    if (n == target) break :blk try self.konst(0);
                    const tp = self.payload(target);
                    // k*a == 0 with k = 2^t * u, t >= 1: a is a multiple of 2^(32-t).
                    if (self.scaledAtom(target)) |ta| if (ta.coeff & 1 == 0) {
                        const t: u5 = @intCast(@ctz(ta.coeff));
                        const mask: u32 = (@as(u32, 1) << t) - 1;
                        switch (self.tagOf(n)) {
                            .lin => {
                                var touched = false;
                                var i: usize = 1;
                                while (i < p.len) : (i += 2) touched = touched or p[i] == ta.atom;
                                if (touched) {
                                    var acc = try self.konst(p[0]);
                                    i = 1;
                                    while (i < p.len) : (i += 2) {
                                        const term = if (p[i] == ta.atom)
                                            try self.scale(ta.atom, p[i + 1] & mask)
                                        else
                                            try self.binary(.mul, try self.konst(p[i + 1]), try self.substRec(p[i], target, fact, memo));
                                        acc = try self.binary(.add, acc, term);
                                    }
                                    break :blk acc;
                                }
                            },
                            .ac => if (p[0] == @intFromEnum(ast.BinOp.mul)) {
                                var m: u32 = 0;
                                for (p[1..]) |kid| m += @intFromBool(kid == ta.atom);
                                if (m * (32 - @as(u32, t)) >= 32) break :blk try self.konst(0);
                            },
                            else => {},
                        }
                    };
                    switch (self.tagOf(target)) {
                        // a or b == 0: every operand is 0.
                        .ac => if (tp[0] == @intFromEnum(ast.BinOp.or_op) and std.mem.indexOfScalar(u32, tp[1..], n) != null) break :blk try self.konst(0),
                        // k*a + c == 0 with k odd: a = -c / k.
                        .lin => if (tp.len == 3 and tp[2] & 1 == 1 and n == tp[1]) break :blk try self.konst((0 -% tp[0]) *% inverseOdd(tp[2])),
                        // select(c, t, K) == 0 with K != 0: c took the t branch and t == 0;
                        // select(c, K, f) == 0: c == 0 and f == 0.
                        .sel => {
                            const kt = self.constValue(tp[1]);
                            const kf = self.constValue(tp[2]);
                            if (kf != null and kf.? != 0 and n == tp[1]) break :blk try self.konst(0);
                            if (kt != null and kt.? != 0 and (n == tp[2] or n == tp[0])) break :blk try self.konst(0);
                        },
                        else => {},
                    }
                },
                .nonzero => {
                    // A 0/1 value that is not 0 is 1.
                    if (n == target and self.hi(target) <= 1) break :blk try self.konst(1);
                    const tr = self.payload(target);
                    switch (self.tagOf(target)) {
                        // select(c, 0, f) != 0: c == 0.
                        .sel => if (self.constValue(tr[1])) |v| if (v == 0 and n == tr[0]) break :blk try self.konst(0),
                        // zero(k*a + c) != 0 with k odd: a = -c / k.
                        .zero => {
                            const d = self.payload(tr[0]);
                            if (self.tagOf(tr[0]) == .lin and d.len == 3 and d[2] & 1 == 1 and n == d[1]) break :blk try self.konst((0 -% d[0]) *% inverseOdd(d[2]));
                        },
                        // a ult 2: a is 0 or 1, so a mul a = a.
                        .bin => if (tr[0] == @intFromEnum(ast.BinOp.ult) and self.constValue(tr[2]) != null and self.constValue(tr[2]).? == 2) {
                            if (self.tagOf(n) == .ac and p[0] == @intFromEnum(ast.BinOp.mul) and p.len == 3 and p[1] == tr[1] and p[2] == tr[1]) break :blk tr[1];
                        },
                        else => {},
                    }
                    // Under a ult K: a == v is false for v >= K, and a ult K2 is true for K2 >= K.
                    const tq = self.payload(target);
                    if (self.tagOf(target) == .bin and tq[0] == @intFromEnum(ast.BinOp.ult)) if (self.constValue(tq[2])) |kk| {
                        if (self.tagOf(n) == .zero) {
                            const d = self.payload(p[0]);
                            if (self.tagOf(p[0]) == .lin and d.len == 3 and d[1] == tq[1] and d[2] == 1 and (0 -% d[0]) >= kk) break :blk try self.konst(0);
                        }
                        if (self.tagOf(n) == .bin and p[0] == @intFromEnum(ast.BinOp.ult) and p[1] == tq[1]) if (self.constValue(p[2])) |k2| {
                            if (k2 >= kk) break :blk try self.konst(1);
                        };
                        // a < 2^31: shifting left by one drops a 0 bit.
                        if (kk <= 0x80000000 and self.tagOf(n) == .un and p[0] == @intFromEnum(ast.UnOp.popcount)) {
                            const sh = self.payload(p[1]);
                            // a shl 1 normalizes to the linear form 2*a.
                            const doubled = if (self.scaledAtom(p[1])) |term| term.atom == tq[1] and term.coeff == 2 else false;
                            if (doubled or (self.tagOf(p[1]) == .shift and sh[0] == @intFromEnum(ast.BinOp.shl) and sh.len == 3 and sh[1] == tq[1] and self.constValue(sh[2]) != null and self.constValue(sh[2]).? & 31 == 1))
                                break :blk try self.unary(.popcount, tq[1]);
                        }
                    };
                    if (self.tagOf(n) == .zero and p[0] == target) break :blk try self.konst(0);
                    if (self.tagOf(n) == .sel and p[0] == target) break :blk try self.substRec(p[1], target, fact, memo);
                },
            }
            switch (self.tagOf(n)) {
                .konst, .variable => break :blk n,
                .lin => {
                    var acc = try self.konst(p[0]);
                    var i: usize = 1;
                    while (i < p.len) : (i += 2) {
                        const term = try self.binary(.mul, try self.konst(p[i + 1]), try self.substRec(p[i], target, fact, memo));
                        acc = try self.binary(.add, acc, term);
                    }
                    break :blk acc;
                },
                .ac => {
                    const op: ast.BinOp = @enumFromInt(p[0]);
                    var acc = try self.substRec(p[1], target, fact, memo);
                    for (p[2..]) |k| acc = try self.binary(op, acc, try self.substRec(k, target, fact, memo));
                    break :blk acc;
                },
                .shift => {
                    const op: ast.BinOp = @enumFromInt(p[0]);
                    var acc = try self.substRec(p[1], target, fact, memo);
                    for (p[2..]) |a| acc = try self.binary(op, acc, try self.substRec(a, target, fact, memo));
                    break :blk acc;
                },
                .bin => break :blk try self.binary(@enumFromInt(p[0]), try self.substRec(p[1], target, fact, memo), try self.substRec(p[2], target, fact, memo)),
                .zero => break :blk try self.zeroTest(try self.substRec(p[0], target, fact, memo)),
                .un => break :blk try self.unary(@enumFromInt(p[0]), try self.substRec(p[1], target, fact, memo)),
                .sel => break :blk try self.select(try self.substRec(p[0], target, fact, memo), try self.substRec(p[1], target, fact, memo), try self.substRec(p[2], target, fact, memo)),
            }
        };
        try memo.put(self.gpa, n, result);
        return result;
    }

    /// A node that is 0 for exactly the inputs where `n` is 0 (see the zero-ness rules above).
    /// Applied where only zero-ness matters: select conditions and `== 0` tests.
    fn nonzeroKey(self: *Normalizer, n_in: Nf) error{OutOfMemory}!Nf {
        var n = n_in;
        for (0..8) |_| {
            const next = try self.nonzeroStep(n);
            if (next == n) break;
            n = next;
        }
        return n;
    }

    fn nonzeroStep(self: *Normalizer, n: Nf) error{OutOfMemory}!Nf {
        const p = self.payload(n);
        switch (self.tagOf(n)) {
            .un => if (p[0] == @intFromEnum(ast.UnOp.popcount)) return p[1],
            .sel => {
                const kt = try self.nonzeroKey(p[1]);
                const kf = try self.nonzeroKey(p[2]);
                const t_nz = if (self.constValue(kt)) |v| v != 0 else false;
                const f_nz = if (self.constValue(kf)) |v| v != 0 else false;
                if (t_nz and f_nz) return self.konst(1);
                // Both branches 0 for the same inputs: so is the select.
                if (kt == kf) return kt;
                // select(c, 0, K != 0) is nonzero exactly when c == 0.
                if (f_nz and self.constValue(kt) != null and self.constValue(kt).? == 0) return self.zeroTest(p[0]);
                // Zero iff c == 0 and f == 0 when t is nonzero wherever c is (t a nonzero constant, or t = c).
                if (t_nz or kt == p[0]) return self.ac(.or_op, p[0], kf);
                // Only the zero-ness of each branch matters for the zero-ness of the select.
                if (kt != p[1] or kf != p[2]) return self.intern(&.{ @intFromEnum(Tag.sel), p[0], kt, kf });
            },
            .lin => if (p.len == 3 and p[0] != 0 and p[2] == 1 and self.hi(p[1]) < 0 -% p[0]) {
                // a + c with a in [0, hi(a)] never reaches 2^32: never 0.
                return self.konst(1);
            } else if (p.len == 3 and p[0] != 0 and p[2] & 1 == 1 and self.tagOf(p[1]) == .ac and self.payload(p[1])[0] == @intFromEnum(ast.BinOp.mul) and self.payload(p[1]).len == 3 and self.payload(p[1])[1] == self.payload(p[1])[2] and !isSquare((0 -% p[0]) *% inverseOdd(p[2]))) {
                // k*a^2 + c == 0 needs a^2 = -c/k, which is not a square.
                return self.konst(1);
            } else if (p.len == 3 and p[0] != 0 and @ctz(p[0]) < @min(32, @ctz(p[2]) + self.minTz(p[1]))) {
                // k*a has more trailing zero bits than c, so k*a + c keeps a set bit: never 0.
                return self.konst(1);
            } else if (p.len == 3 and p[0] == 0) {
                // k * a with k = 2^t * u, u odd: zero iff 2^t * a is.
                const k = p[2];
                const pow: u32 = k & (0 -% k);
                if (k != pow) return self.scale(p[1], pow);
                if (k == 1) return p[1];
            },
            .ac => {
                const op: ast.BinOp = @enumFromInt(p[0]);
                const kids = p[1..];
                if (op == .mul) {
                    // An odd factor never changes whether a product is 0.
                    var rest: [16]Nf = undefined;
                    var r: usize = 0;
                    for (kids) |kid| {
                        if (self.knownOdd(kid)) continue;
                        if (r == rest.len) break;
                        rest[r] = kid;
                        r += 1;
                    }
                    if (r < kids.len and r <= rest.len) {
                        if (r == 0) return self.konst(1);
                        if (r == 1) return rest[0];
                        return self.acNode(.mul, rest[0..r]);
                    }
                }
                if (kids.len == 2) switch (op) {
                    // a mul a: v2(a^2) = 2 v2(a) < 32 iff v2(a) < 16 iff a shl 16 != 0.
                    .mul => if (kids[0] == kids[1]) return self.scale(kids[0], 1 << 16),
                    // a xor b != 0 iff a != b (a constant operand is kept as a kid).
                    .xor => return self.linear2(kids[0], 1, kids[1], 0xFFFFFFFF, 0),
                    .or_op => for (kids) |kid| {
                        if (self.constValue(kid)) |v| if (v != 0) return self.konst(1);
                    },
                    // a and (2^m - 1) != 0 iff the low m bits of a are not all 0 iff a shl (32 - m) != 0.
                    .and_op => for (0..2) |i| {
                        const m = self.constValue(kids[i]) orelse continue;
                        if (m != 0 and m != 0xFFFFFFFF and m & (m +% 1) == 0) return self.scale(kids[1 - i], @as(u32, 1) << @intCast(32 - @popCount(m)));
                    },
                    else => {},
                };
            },
            .shift => if (p.len == 3) {
                const op: ast.BinOp = @enumFromInt(p[0]);
                const base = p[1];
                const amt = p[2];
                if (self.constValue(base)) |kb| {
                    // K lshr s != 0 iff (s & 31) <= bitlen(K) - 1;  K shl s != 0 iff (s & 31) <= 31 - ctz(K).
                    // K ashr s is never 0 for negative K, otherwise it is K lshr s.
                    if (kb == 0) return self.konst(0);
                    if (op == .ashr and kb & 0x80000000 != 0) return self.konst(1);
                    const top: u5 = if (op == .shl) @intCast(31 - @ctz(kb)) else @intCast(31 - @clz(kb));
                    if (top == 31) return self.konst(1); // (s & 31) <= 31 always
                    const want = try self.konst(@as(u32, 1) << top);
                    if (op != .lshr or want != base) return self.shiftChain(.lshr, want, amt);
                } else if (op == .ashr) {
                    // a ashr s is 0 iff a >= 0 and a < 2^s, which is exactly when a lshr s is 0
                    // (s < 32; a negative a keeps a set bit under both).
                    return self.shiftChain(.lshr, base, amt);
                } else if (op == .shl and base == amt) {
                    // a shl (a & 31) != 0 iff a != 0: the lowest set bit p of a lands at p + (a & 31) <= 31.
                    return base;
                }
            },
            else => {},
        }
        return n;
    }

    fn select(self: *Normalizer, c_in: Nf, t_in: Nf, f_in: Nf) error{OutOfMemory}!Nf {
        var c = c_in;
        var t = t_in;
        var f = f_in;
        // Only c != 0 matters: strip tests for zero and odd factors from the condition.
        while (true) {
            if (self.constValue(c)) |cv| return if (cv != 0) t else f;
            const p = self.payload(c);
            if (self.tagOf(c) == .zero) {
                // select(d == 0, t, f) = select(d, f, t)
                c = p[0];
                std.mem.swap(Nf, &t, &f);
            } else if (self.tagOf(c) == .lin and p.len == 3 and p[0] == 1 and p[2] == 0xFFFFFFFF and self.tagOf(p[1]) == .zero) {
                // 1 - (d == 0) is d != 0
                c = self.payload(p[1])[0];
            } else if (self.tagOf(c) == .lin and p[2] & 1 == 1 and p[2] != 1) {
                // u * d != 0 iff d != 0 for odd u
                c = try self.scale(c, inverseOdd(p[2]));
            } else {
                const key = try self.nonzeroKey(c);
                if (key == c) break;
                c = key;
            }
        }
        if (self.constValue(t)) |tv| if (self.constValue(f)) |fv| {
            if (tv == 1 and fv == 0) return self.affine(try self.zeroTest(c), 0xFFFFFFFF, 1);
            if (tv == 0 and fv == 1) return self.zeroTest(c);
        };
        // A select condition that is itself a select: split by cases on its condition.
        if (self.budget > 0 and self.tagOf(c) == .sel) {
            self.budget -= 1;
            const q = self.payload(c);
            const d = q[0];
            const u = q[1];
            const v = q[2];
            return self.select(d, try self.select(u, t, f), try self.select(v, t, f));
        }
        // One order for nested selects: the smallest condition outermost.
        if (self.budget > 0) {
            const tc: ?Nf = if (self.tagOf(t) == .sel) self.payload(t)[0] else null;
            const fc: ?Nf = if (self.tagOf(f) == .sel) self.payload(f)[0] else null;
            var d: ?Nf = null;
            if (tc) |v| if (v < c) {
                d = v;
            };
            if (fc) |v| if (v < c and (d == null or v < d.?)) {
                d = v;
            };
            if (d) |dd| {
                self.budget -= 1;
                const t1 = if (tc != null and tc.? == dd) self.payload(t)[1] else t;
                const t0 = if (tc != null and tc.? == dd) self.payload(t)[2] else t;
                const f1 = if (fc != null and fc.? == dd) self.payload(f)[1] else f;
                const f0 = if (fc != null and fc.? == dd) self.payload(f)[2] else f;
                return self.select(dd, try self.select(c, t1, f1), try self.select(c, t0, f0));
            }
        }
        // select(c, t, select(d, t, g)) = select(c or d, t, g)
        if (self.budget > 0 and self.tagOf(f) == .sel and self.payload(f)[1] == t) {
            self.budget -= 1;
            const q = self.payload(f);
            return self.select(try self.ac(.or_op, c, q[0]), t, q[2]);
        }
        if (self.budget == 0) return if (t == f) t else self.intern(&.{ @intFromEnum(Tag.sel), c, t, f });
        // In the false branch c is 0, in the true branch it is not.
        f = try self.subst(f, c, .is_zero);
        t = try self.subst(t, c, .nonzero);
        if (t == f) return t;
        // If t already equals f wherever c is 0, the select is just t; likewise f where c is not 0.
        if (try self.subst(t, c, .is_zero) == f) return t;
        if (try self.subst(f, c, .nonzero) == t) return f;
        // A conjunction of 0/1 values: one canonical `and` form.
        if (self.constValue(f) != null and self.constValue(f).? == 0 and self.constValue(t) == null and self.hi(t) <= 1)
            return self.ac(.and_op, try self.affine(try self.zeroTest(c), 0xFFFFFFFF, 1), t);
        if (self.constValue(t) != null and self.constValue(t).? == 0 and self.constValue(f) == null and self.hi(f) <= 1)
            return self.ac(.and_op, try self.zeroTest(c), f);
        if (self.constValue(f) != null and self.constValue(f).? == 1 and self.constValue(t) == null and self.hi(t) <= 1)
            return self.ac(.or_op, t, try self.zeroTest(c));
        if (self.constValue(t) != null and self.constValue(t).? == 1 and self.constValue(f) == null and self.hi(f) <= 1)
            return self.ac(.or_op, try self.affine(try self.zeroTest(c), 0xFFFFFFFF, 1), f);
        return self.intern(&.{ @intFromEnum(Tag.sel), c, t, f });
    }

    // ---- operators ------------------------------------------------------------------------

    fn unary(self: *Normalizer, op: ast.UnOp, a: Nf) error{OutOfMemory}!Nf {
        // op(select(c, t, f)) = select(c, op(t), op(f))
        if (self.tagOf(a) == .sel and self.budget > 0) {
            self.budget -= 1;
            const p = self.payload(a);
            return self.select(p[0], try self.unary(op, p[1]), try self.unary(op, p[2]));
        }
        return switch (op) {
            .neg => self.scale(a, 0xFFFFFFFF),
            .not => self.notOf(a),
            .clz, .ctz, .popcount => if (self.constValue(a)) |c|
                self.konst(switch (op) {
                    .clz => @clz(c),
                    .ctz => @ctz(c),
                    else => @popCount(c),
                })
            else if (op == .popcount and self.hi(a) <= 1)
                a
            else if (op == .popcount and self.zeroShiftBase(a) != null)
                self.unary(.popcount, self.zeroShiftBase(a).?)
            else if (op == .popcount and self.isPow2Shl(a))
                // popcount(2^j shl s) = [2^j shl s != 0]
                self.affine(try self.zeroTest(a), 0xFFFFFFFF, 1)
            else if (op == .popcount and self.isNot(a))
                // popcount(not t) = 32 - popcount(t)
                self.affine(try self.intern(&.{ @intFromEnum(Tag.un), @intFromEnum(op), try self.affine(a, 0xFFFFFFFF, 0xFFFFFFFF) }), 0xFFFFFFFF, 32)
            else
                self.intern(&.{ @intFromEnum(Tag.un), @intFromEnum(op), a }),
        };
    }

    fn binary(self: *Normalizer, op: ast.BinOp, l: Nf, r: Nf) error{OutOfMemory}!Nf {
        // op(select(c, t, f), r) = select(c, op(t, r), op(f, r)), and likewise on the right. With
        // selects on both sides, the one with the smaller condition goes outermost, so the result
        // does not depend on the operand order.
        const push = self.budget > 0;
        if (push) self.budget -= 1;
        const ls = push and self.tagOf(l) == .sel;
        const rs = push and self.tagOf(r) == .sel;
        if (ls and (!rs or self.payload(l)[0] <= self.payload(r)[0])) {
            const p = self.payload(l);
            return self.select(p[0], try self.binary(op, p[1], r), try self.binary(op, p[2], r));
        }
        if (rs) {
            const p = self.payload(r);
            return self.select(p[0], try self.binary(op, l, p[1]), try self.binary(op, l, p[2]));
        }
        // A 0/1 operand turns into a select, so the branches can use the fact b == 0 / b == 1.
        if (push) {
            switch (op) {
                .mul => {
                    if (self.constValue(r) == null and self.hi(r) <= 1) return self.select(r, l, try self.konst(0));
                    if (self.constValue(l) == null and self.hi(l) <= 1) return self.select(l, r, try self.konst(0));
                },
                .shl, .lshr, .ashr => if (self.constValue(r) == null and self.hi(r) <= 1)
                    return self.select(r, try self.shift(op, l, try self.konst(1)), l),
                .ult, .ule, .slt, .sle, .eq => {
                    if (self.boolAffine(r)) |ba| if (ba.b != l)
                        return self.select(ba.b, try self.binary(op, l, try self.konst(ba.c +% ba.k)), try self.binary(op, l, try self.konst(ba.c)));
                    if (self.boolAffine(l)) |ba| if (ba.b != r)
                        return self.select(ba.b, try self.binary(op, try self.konst(ba.c +% ba.k), r), try self.binary(op, try self.konst(ba.c), r));
                },
                .and_op, .or_op, .xor => {
                    if (self.constValue(r) == null and self.hi(r) <= 1)
                        return self.select(r, try self.binary(op, l, try self.konst(1)), try self.binary(op, l, try self.konst(0)));
                    if (self.constValue(l) == null and self.hi(l) <= 1)
                        return self.select(l, try self.binary(op, try self.konst(1), r), try self.binary(op, try self.konst(0), r));
                },
                else => {},
            }
        }
        return self.canonPred(try switch (op) {
            .add => self.linear2(l, 1, r, 1, 0),
            .sub => self.linear2(l, 1, r, 0xFFFFFFFF, 0),
            .mul, .and_op, .or_op => self.ac(op, l, r),
            .xor => self.xorOf(l, r),
            .shl, .lshr, .ashr => self.shift(op, l, r),
            .eq => self.zeroTest(try self.linear2(l, 1, r, 0xFFFFFFFF, 0)),
            .ult => self.ult(l, r),
            .slt => self.slt(l, r),
            // a <= b  <=>  !(b < a)
            .ule => self.affine(try self.ult(r, l), 0xFFFFFFFF, 1),
            .sle => self.affine(try self.slt(r, l), 0xFFFFFFFF, 1),
        });
    }

    // ---- entry point ----------------------------------------------------------------------

    pub fn normalize(self: *Normalizer, id: ast.ExprId, arena: *const ExpressionArena) !Nf {
        const n = try self.normalizeInner(id, arena);
        // Only the whole expression: `K + k*b` with b in {0, 1} is reported as select(b, K + k, K).
        if (self.tagOf(n) == .lin) {
            const p = self.payload(n);
            if (p.len == 3 and self.hi(p[1]) <= 1 and self.constValue(p[1]) == null) {
                self.budget = select_budget;
                return self.select(p[1], try self.konst(p[0] +% p[2]), try self.konst(p[0]));
            }
        }
        return n;
    }

    fn normalizeInner(self: *Normalizer, id: ast.ExprId, arena: *const ExpressionArena) !Nf {
        if (self.memo.get(id)) |n| return n;
        if (self.depth == 0) self.budget = select_budget;
        self.depth += 1;
        defer self.depth -= 1;
        const result: Nf = switch (arena.get(id)) {
            .variable => |v| try self.intern(&.{ @intFromEnum(Tag.variable), @intFromEnum(v) }),
            .constant => |c| try self.konst(c),
            .unary => |u| try self.unary(u.op, try self.normalizeInner(u.expr, arena)),
            .binary => |b| try self.binary(b.op, try self.normalizeInner(b.lhs, arena), try self.normalizeInner(b.rhs, arena)),
            .select => |s| try self.select(try self.normalizeInner(s.cond, arena), try self.normalizeInner(s.true_val, arena), try self.normalizeInner(s.false_val, arena)),
        };
        try self.memo.put(self.gpa, id, result);
        return result;
    }

    /// Reference semantics of a normal form (tests only).
    fn eval(self: *const Normalizer, n: Nf, x: u32, y: u32, z: u32) u32 {
        const p = self.payload(n);
        return switch (self.tagOf(n)) {
            .konst => p[0],
            .variable => switch (@as(ast.Var, @enumFromInt(p[0]))) {
                .x => x,
                .y => y,
                .z => z,
            },
            .lin => blk: {
                var acc = p[0];
                var i: usize = 1;
                while (i < p.len) : (i += 2) acc +%= p[i + 1] *% self.eval(p[i], x, y, z);
                break :blk acc;
            },
            .zero => @intFromBool(self.eval(p[0], x, y, z) == 0),
            .ac => blk: {
                const op: ast.BinOp = @enumFromInt(p[0]);
                var acc = self.eval(p[1], x, y, z);
                for (p[2..]) |k| {
                    const v = self.eval(k, x, y, z);
                    acc = switch (op) {
                        .and_op => acc & v,
                        .or_op => acc | v,
                        .xor => acc ^ v,
                        .mul => acc *% v,
                        else => unreachable,
                    };
                }
                break :blk acc;
            },
            .shift => blk: {
                var acc = self.eval(p[1], x, y, z);
                for (p[2..]) |a| {
                    const k: u5 = @truncate(self.eval(a, x, y, z));
                    acc = switch (@as(ast.BinOp, @enumFromInt(p[0]))) {
                        .shl => acc << k,
                        .lshr => acc >> k,
                        .ashr => @bitCast(@as(i32, @bitCast(acc)) >> k),
                        else => unreachable,
                    };
                }
                break :blk acc;
            },
            .bin => blk: {
                const l = self.eval(p[1], x, y, z);
                const r = self.eval(p[2], x, y, z);
                break :blk switch (@as(ast.BinOp, @enumFromInt(p[0]))) {
                    .ult => @intFromBool(l < r),
                    else => unreachable,
                };
            },
            .un => blk: {
                const a = self.eval(p[1], x, y, z);
                break :blk switch (@as(ast.UnOp, @enumFromInt(p[0]))) {
                    .clz => @clz(a),
                    .ctz => @ctz(a),
                    .popcount => @popCount(a),
                    else => unreachable,
                };
            },
            .sel => if (self.eval(p[0], x, y, z) != 0) self.eval(p[1], x, y, z) else self.eval(p[2], x, y, z),
        };
    }
};

// Tests: `zig test src/normalize.zig`

const eval_ref = @import("eval.zig");

const test_consts = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32, 33, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xFFFF };

/// The randomized tests allocate millions of small nodes; `scripts/check.sh` links libc so they
/// use malloc instead of the leak-checking test allocator, whose system calls dominate the run.
const test_alloc = if (@import("builtin").link_libc) std.heap.c_allocator else std.testing.allocator;

/// `SCONE_SHARD=i/n` runs slice i of n of each randomized test, with its own seed, so n
/// processes of one test binary share the work (`scripts/check.sh`). Unset: the whole test.
const Shard = struct {
    i: u64 = 0,
    n: u64 = 1,

    fn get() Shard {
        const v = std.posix.getenv("SCONE_SHARD") orelse return .{};
        const slash = std.mem.indexOfScalar(u8, v, '/') orelse return .{};
        const i = std.fmt.parseInt(u64, v[0..slash], 10) catch return .{};
        const n = std.fmt.parseInt(u64, v[slash + 1 ..], 10) catch return .{};
        if (n == 0 or i >= n) return .{};
        return .{ .i = i, .n = n };
    }
    fn seed(s: Shard, base: u64) u64 {
        return base +% s.i *% 0x9E3779B97F4A7C15;
    }
    fn count(s: Shard, total: usize) usize {
        return (total + @as(usize, @intCast(s.n)) - 1) / @as(usize, @intCast(s.n));
    }
};

fn randValue(rand: std.Random) u32 {
    return switch (rand.uintLessThan(u8, 4)) {
        0 => test_consts[rand.uintLessThan(usize, test_consts.len)],
        1 => rand.uintLessThan(u32, 64),
        else => rand.int(u32),
    };
}

fn randTree(rand: std.Random, arena: *ExpressionArena, depth: usize) !ast.ExprId {
    if (depth == 0 or rand.uintLessThan(u8, 5) == 0) {
        if (rand.boolean()) return arena.add(.{ .variable = @enumFromInt(rand.uintLessThan(u8, 3)) });
        return arena.add(.{ .constant = test_consts[rand.uintLessThan(usize, test_consts.len)] });
    }
    switch (rand.uintLessThan(u8, 6)) {
        0 => {
            const child = try randTree(rand, arena, depth - 1);
            return arena.add(.{ .unary = .{ .op = @enumFromInt(rand.uintLessThan(u8, 5)), .expr = child } });
        },
        1 => {
            const c = try randTree(rand, arena, depth - 1);
            const t = try randTree(rand, arena, depth - 1);
            const f = try randTree(rand, arena, depth - 1);
            return arena.add(.{ .select = .{ .cond = c, .true_val = t, .false_val = f } });
        },
        else => {
            // Bias towards the ops with the most rewrite rules.
            const op: ast.BinOp = if (rand.boolean())
                @enumFromInt(rand.uintLessThan(u8, 14))
            else
                ([_]ast.BinOp{ .add, .sub, .xor, .shl, .lshr, .ashr, .mul, .and_op, .or_op })[rand.uintLessThan(usize, 9)];
            const l = try randTree(rand, arena, depth - 1);
            const r = try randTree(rand, arena, depth - 1);
            return arena.add(.{ .binary = .{ .op = op, .lhs = l, .rhs = r } });
        },
    }
}

fn formatted(e: ast.ExprId, arena: *const ExpressionArena, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    @import("arena.zig").format_expr(e, arena, fbs.writer()) catch {};
    return fbs.getWritten();
}

test "normal forms of random trees agree with the reference evaluator" {
    const sh = Shard.get();
    var prng = std.Random.DefaultPrng.init(sh.seed(4242));
    const rand = prng.random();
    var arena = try ExpressionArena.init(test_alloc);
    defer arena.deinit();
    var norm = Normalizer.init(test_alloc);
    defer norm.deinit();
    for (0..sh.count(200_000)) |i| {
        if (i % 20_000 == 0) norm.reset();
        const e = try randTree(rand, &arena, 5);
        const n = try norm.normalize(e, &arena);
        for (0..32) |_| {
            const x = randValue(rand);
            const y = if (rand.uintLessThan(u8, 6) == 0) x else randValue(rand);
            const z = if (rand.uintLessThan(u8, 6) == 0) y else randValue(rand);
            const want = eval_ref.eval_point(e, &arena, x, y, z);
            const got = norm.eval(n, x, y, z);
            if (got > norm.hi(n)) {
                var buf: [1024]u8 = undefined;
                std.debug.print("UNSOUND bound for {s}: eval({}, {}, {}) = {} > hi {}\n", .{ formatted(e, &arena, &buf), x, y, z, got, norm.hi(n) });
                return error.Unsound;
            }
            if (want != got) {
                var buf: [1024]u8 = undefined;
                std.debug.print("UNSOUND normal form for {s}: eval({}, {}, {}) = {} but normal form gives {}\n", .{ formatted(e, &arena, &buf), x, y, z, want, got });
                return error.Unsound;
            }
        }
    }
}

test "random pairs with equal normal forms agree everywhere sampled" {
    // Pairs built from the same leaves collide in normal form far more often than random trees.
    const sh = Shard.get();
    var prng = std.Random.DefaultPrng.init(sh.seed(99));
    const rand = prng.random();
    var arena = try ExpressionArena.init(test_alloc);
    defer arena.deinit();
    var norm = Normalizer.init(test_alloc);
    defer norm.deinit();
    var by_nf = std.AutoHashMap(Nf, ast.ExprId).init(test_alloc);
    defer by_nf.deinit();
    var collisions: usize = 0;
    for (0..sh.count(300_000)) |_| {
        const e = try randTree(rand, &arena, 3);
        const n = try norm.normalize(e, &arena);
        const gop = try by_nf.getOrPut(n);
        if (!gop.found_existing) {
            gop.value_ptr.* = e;
            continue;
        }
        const other = gop.value_ptr.*;
        if (other == e) continue;
        collisions += 1;
        for (0..64) |_| {
            const x = randValue(rand);
            const y = randValue(rand);
            const z = randValue(rand);
            if (eval_ref.eval_point(e, &arena, x, y, z) != eval_ref.eval_point(other, &arena, x, y, z)) {
                var b1: [1024]u8 = undefined;
                var b2: [1024]u8 = undefined;
                std.debug.print("UNSOUND: {s} and {s} share a normal form but differ at ({}, {}, {})\n", .{ formatted(e, &arena, &b1), formatted(other, &arena, &b2), x, y, z });
                return error.Unsound;
            }
        }
    }
    try std.testing.expect(collisions > 10_000 / (2 * sh.n));
}

test "a * (a shift s) == n is solved exactly" {
    const shard = Shard.get();
    var prng = std.Random.DefaultPrng.init(shard.seed(11));
    const rand = prng.random();
    for (0..shard.count(4000)) |_| {
        const op: ast.BinOp = if (rand.boolean()) .lshr else .ashr;
        const s: u5 = ([_]u5{ 1, 2, 3, 5, 8, 16, 17, 20, 24, 31 })[rand.uintLessThan(usize, 10)];
        const a = switch (rand.uintLessThan(u8, 3)) {
            0 => rand.int(u32),
            1 => rand.uintLessThan(u32, 1000),
            else => 0 -% rand.uintLessThan(u32, 1000),
        };
        const sh: u32 = if (op == .lshr) a >> s else @bitCast(@as(i32, @bitCast(a)) >> s);
        const n = a *% sh;
        switch (Normalizer.solveMulShift(op, s, n)) {
            .none => return error.MissedSolution,
            .one => |v| try std.testing.expectEqual(a, v),
            .unknown => {},
        }
    }
    // Known impossible cases from the Z3 log.
    try std.testing.expect(Normalizer.solveMulShift(.lshr, 1, 1) == .none);
    try std.testing.expect(Normalizer.solveMulShift(.lshr, 16, 0x7FFFFFFF) == .none);
    try std.testing.expect(Normalizer.solveMulShift(.lshr, 16, 3) == .none);
}

test "squares mod 2^32" {
    var seen = std.AutoHashMap(u32, void).init(test_alloc);
    defer seen.deinit();
    // Every residue mod 2^12 that is a square of some z, from z in [0, 2^12).
    for (0..4096) |zz| try seen.put(@intCast((zz * zz) & 0xFFF), {});
    // isSquare on 32 bits must agree with the 12-bit picture for numbers with few trailing zeros.
    var prng = std.Random.DefaultPrng.init(3);
    for (0..100_000) |_| {
        const z = prng.random().int(u32);
        try std.testing.expect(Normalizer.isSquare(z *% z));
    }
    for (0..4096) |n| {
        const v: u32 = @intCast(n);
        if (v == 0 or @ctz(v) >= 9) continue; // the odd part is only determined mod 2^(12 - v)
        try std.testing.expectEqual(seen.contains(v), Normalizer.isSquare(v | 0x1000) or Normalizer.isSquare(v));
    }
}

test "nonzero keys are zero exactly where the value is" {
    const sh = Shard.get();
    var prng = std.Random.DefaultPrng.init(sh.seed(7));
    const rand = prng.random();
    var arena = try ExpressionArena.init(test_alloc);
    defer arena.deinit();
    var norm = Normalizer.init(test_alloc);
    defer norm.deinit();
    for (0..sh.count(200_000)) |i| {
        if (i % 20_000 == 0) norm.reset();
        const e = try randTree(rand, &arena, 4);
        norm.budget = select_budget;
        const n = try norm.normalize(e, &arena);
        const key = try norm.nonzeroKey(n);
        for (0..32) |_| {
            const x = randValue(rand);
            const y = if (rand.uintLessThan(u8, 6) == 0) x else randValue(rand);
            const z = randValue(rand);
            if ((norm.eval(n, x, y, z) == 0) != (norm.eval(key, x, y, z) == 0)) {
                var buf: [1024]u8 = undefined;
                std.debug.print("UNSOUND nonzero key for {s} at ({}, {}, {})\n", .{ formatted(e, &arena, &buf), x, y, z });
                return error.Unsound;
            }
        }
    }
    // Exhaustive over the shift amount for the constant-base rules and a shl a.
    for ([_]u32{ 1, 2, 3, 16, 31, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 6, 0x10000 }) |kb| {
        for ([_]ast.BinOp{ .shl, .lshr, .ashr }) |op| {
            const e = try arena.add(.{ .binary = .{ .op = op, .lhs = try arena.add(.{ .constant = kb }), .rhs = try arena.add(.{ .variable = .x }) } });
            const n = try norm.normalize(e, &arena);
            const key = try norm.nonzeroKey(n);
            for (0..64) |s| try std.testing.expectEqual(norm.eval(n, @intCast(s), 0, 0) == 0, norm.eval(key, @intCast(s), 0, 0) == 0);
        }
    }
}

test "conditions with the same zero-ness give the same select" {
    var arena = try ExpressionArena.init(test_alloc);
    defer arena.deinit();
    var norm = Normalizer.init(test_alloc);
    defer norm.deinit();
    const x = try arena.add(.{ .variable = .x });
    const y = try arena.add(.{ .variable = .y });
    const z = try arena.add(.{ .variable = .z });
    const k = struct {
        fn f(a: *ExpressionArena, c: u32) !ast.ExprId {
            return a.add(.{ .constant = c });
        }
    }.f;
    const bin = struct {
        fn f(a: *ExpressionArena, op: ast.BinOp, l: ast.ExprId, r: ast.ExprId) !ast.ExprId {
            return a.add(.{ .binary = .{ .op = op, .lhs = l, .rhs = r } });
        }
    }.f;
    const sel = struct {
        fn f(a: *ExpressionArena, c: ast.ExprId, t: ast.ExprId, e: ast.ExprId) !ast.ExprId {
            return a.add(.{ .select = .{ .cond = c, .true_val = t, .false_val = e } });
        }
    }.f;
    const t = try k(&arena, 0);
    const f = try k(&arena, 0x80000000);
    const same = struct {
        fn check(nm: *Normalizer, ar: *ExpressionArena, c1: ast.ExprId, c2: ast.ExprId, tt: ast.ExprId, ff: ast.ExprId) !void {
            try std.testing.expectEqual(try nm.normalize(try sel(ar, c1, tt, ff), ar), try nm.normalize(try sel(ar, c2, tt, ff), ar));
        }
    }.check;
    try same(&norm, &arena, x, try arena.add(.{ .unary = .{ .op = .popcount, .expr = x } }), t, f);
    try same(&norm, &arena, x, try bin(&arena, .shl, x, x), t, f);
    try same(&norm, &arena, try bin(&arena, .lshr, y, x), try bin(&arena, .ashr, y, x), t, z);
    try same(&norm, &arena, try bin(&arena, .sub, x, try k(&arena, 1)), try bin(&arena, .xor, x, try k(&arena, 1)), try k(&arena, 1), try k(&arena, 31));
    try same(&norm, &arena, try bin(&arena, .mul, x, x), try bin(&arena, .and_op, x, try k(&arena, 0xFFFF)), t, f);
    try same(&norm, &arena, try bin(&arena, .mul, z, z), try bin(&arena, .shl, z, try k(&arena, 16)), t, try k(&arena, 32));
    try same(&norm, &arena, try bin(&arena, .lshr, try k(&arena, 16), x), try bin(&arena, .lshr, try k(&arena, 31), x), t, z);
    try same(&norm, &arena, try bin(&arena, .lshr, try k(&arena, 0x7FFFFFFF), x), try bin(&arena, .shl, try k(&arena, 2), x), try k(&arena, 1), try k(&arena, 16));
    const un = struct {
        fn mk(a: *ExpressionArena, op: ast.UnOp, e: ast.ExprId) !ast.ExprId {
            return a.add(.{ .unary = .{ .op = op, .expr = e } });
        }
    }.mk;
    const nx = try norm.normalize(x, &arena);
    const ny = try norm.normalize(y, &arena);
    const nz = try norm.normalize(z, &arena);
    const zero = try norm.normalize(try k(&arena, 0), &arena);
    // select(1 shl x, x, x mul x) == x
    try std.testing.expectEqual(nx, try norm.normalize(try sel(&arena, try bin(&arena, .shl, try k(&arena, 1), x), x, try bin(&arena, .mul, x, x)), &arena));
    // select(popcount(x or 1), z, 0) == z;  select(1 add popcount(x), z, 0) == z
    try std.testing.expectEqual(nz, try norm.normalize(try sel(&arena, try un(&arena, .popcount, try bin(&arena, .or_op, x, try k(&arena, 1))), z, try k(&arena, 0)), &arena));
    try std.testing.expectEqual(nz, try norm.normalize(try sel(&arena, try bin(&arena, .add, try k(&arena, 1), try un(&arena, .popcount, x)), z, try k(&arena, 0)), &arena));
    // select(popcount(select(x, 1, 31)), x, 0) == x;  select(popcount(select(y, y, 1)), x, 0) == x
    try std.testing.expectEqual(nx, try norm.normalize(try sel(&arena, try un(&arena, .popcount, try sel(&arena, x, try k(&arena, 1), try k(&arena, 31))), x, try k(&arena, 0)), &arena));
    try std.testing.expectEqual(nx, try norm.normalize(try sel(&arena, try un(&arena, .popcount, try sel(&arena, y, y, try k(&arena, 1))), x, try k(&arena, 0)), &arena));
    // select(select(x, 31, y), y, x mul x) == y;  select(select(z, z, x), y, y lshr x) == y
    try std.testing.expectEqual(ny, try norm.normalize(try sel(&arena, try sel(&arena, x, try k(&arena, 31), y), y, try bin(&arena, .mul, x, x)), &arena));
    try std.testing.expectEqual(ny, try norm.normalize(try sel(&arena, try sel(&arena, z, z, x), y, try bin(&arena, .lshr, y, x)), &arena));
    // select(z sub 1, z, 1) == z
    try std.testing.expectEqual(nz, try norm.normalize(try sel(&arena, try bin(&arena, .sub, z, try k(&arena, 1)), z, try k(&arena, 1)), &arena));
    // z ult (z lshr (x add x)) == 0;  x ult (x and_op y) == 0;  (x or_op y) ult x == 0
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, z, try bin(&arena, .lshr, z, try bin(&arena, .add, x, x))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .and_op, x, y)), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, try bin(&arena, .or_op, x, y), x), &arena));
    // z ult (z sub popcount(z)) == 0;  z ult (z sub (x and_op z)) == 0
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, z, try bin(&arena, .sub, z, try un(&arena, .popcount, z))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, z, try bin(&arena, .sub, z, try bin(&arena, .and_op, x, z))), &arena));
    // x eq (0x80000000 sub popcount(x)) == 0;  z eq (1 sub popcount(z)) == 0
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, x, try bin(&arena, .sub, try k(&arena, 0x80000000), try un(&arena, .popcount, x))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, z, try bin(&arena, .sub, try k(&arena, 1), try un(&arena, .popcount, z))), &arena));
    // x ult ((x mul 3) lshr 2) == 0;  x ult (3 mul (x lshr 2)) == 0;  x ult (0xffff mul (x lshr 16)) == 0;  x ult ((x and y) lshr x) == 0
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .lshr, try bin(&arena, .mul, x, try k(&arena, 3)), try k(&arena, 2))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .mul, try k(&arena, 3), try bin(&arena, .lshr, x, try k(&arena, 2)))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .mul, try k(&arena, 0xFFFF), try bin(&arena, .lshr, x, try k(&arena, 16)))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .lshr, try bin(&arena, .and_op, x, y), x)), &arena));
    // ... but not when k > 2^s: x ult ((x mul 5) lshr 2) can be 1
    try std.testing.expect(zero != try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .lshr, try bin(&arena, .mul, x, try k(&arena, 5)), try k(&arena, 2))), &arena));
    // 2 eq (z mul z) == 0
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 2), try bin(&arena, .mul, z, z)), &arena));
    // select(popcount(select(y, x, 31)), x, 0) == x;  select(not(4 shl z), z, 1) == z
    try std.testing.expectEqual(nx, try norm.normalize(try sel(&arena, try un(&arena, .popcount, try sel(&arena, y, x, try k(&arena, 31))), x, try k(&arena, 0)), &arena));
    try std.testing.expectEqual(nz, try norm.normalize(try sel(&arena, try un(&arena, .not, try bin(&arena, .shl, try k(&arena, 4), z)), z, try k(&arena, 1)), &arena));
    // 1 eq (x mul (x add 1)) == 0;  0x7fffffff eq (x mul (x add 2)) == 0;  0x7fffffff sle (x mul (x add 2)) == 0
    const x1 = try bin(&arena, .mul, x, try bin(&arena, .add, x, try k(&arena, 1)));
    const x2 = try bin(&arena, .mul, x, try bin(&arena, .add, x, try k(&arena, 2)));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 1), x1), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 0x7FFFFFFF), x1), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 0x7FFFFFFF), x2), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .sle, try k(&arena, 0x7FFFFFFF), x2), &arena));
    // popcount(1 shl select(x, x, 1)) == 1;  popcount(4 shl y) == (4 shl y) != 0
    const one = try norm.normalize(try k(&arena, 1), &arena);
    try std.testing.expectEqual(one, try norm.normalize(try un(&arena, .popcount, try bin(&arena, .shl, try k(&arena, 1), try sel(&arena, x, x, try k(&arena, 1)))), &arena));
    try std.testing.expectEqual(one, try norm.normalize(try un(&arena, .popcount, try bin(&arena, .shl, try k(&arena, 1), try sel(&arena, x, try k(&arena, 4), y))), &arena));
    // x mul (x add 32) slt 0x7fffffff == 1
    try std.testing.expectEqual(one, try norm.normalize(try bin(&arena, .slt, try bin(&arena, .mul, x, try bin(&arena, .add, x, try k(&arena, 32))), try k(&arena, 0x7FFFFFFF)), &arena));
    // select(select(y, 0, 0xffff), y, x mul y) == x mul y;  z mul (x ashr (z ult 1)) == x mul z
    const xy = try norm.normalize(try bin(&arena, .mul, x, y), &arena);
    try std.testing.expectEqual(xy, try norm.normalize(try sel(&arena, try sel(&arena, y, try k(&arena, 0), try k(&arena, 0xFFFF)), y, try bin(&arena, .mul, x, y)), &arena));
    const xz = try norm.normalize(try bin(&arena, .mul, x, z), &arena);
    try std.testing.expectEqual(xz, try norm.normalize(try bin(&arena, .mul, z, try bin(&arena, .ashr, x, try bin(&arena, .ult, z, try k(&arena, 1)))), &arena));
    // 1 eq (z mul (z lshr 1)) == 0;  3 eq (x mul (x ult 3)) == 0;  popcount(0x80000000 lshr (select(x, 0, y))) == 1
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 1), try bin(&arena, .mul, z, try bin(&arena, .lshr, z, try k(&arena, 1)))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 3), try bin(&arena, .mul, x, try bin(&arena, .ult, x, try k(&arena, 3)))), &arena));
    try std.testing.expectEqual(one, try norm.normalize(try un(&arena, .popcount, try bin(&arena, .lshr, try k(&arena, 0x80000000), try sel(&arena, x, try k(&arena, 0), y))), &arena));
    // ... but 2 eq (x mul (x lshr 1)) holds at x = 2, so it must not fold to 0
    try std.testing.expect(zero != try norm.normalize(try bin(&arena, .eq, try k(&arena, 2), try bin(&arena, .mul, x, try bin(&arena, .lshr, x, try k(&arena, 1)))), &arena));
    // x mul select(x mul 32, 31, -1) == x mul 31;  x mul select(x mul 4, x, 8) == x mul x;  x mul select(x shl 8, 0xffff, 0x7fffffff) == x mul 0xffff
    const xx = try norm.normalize(try bin(&arena, .mul, x, x), &arena);
    const x31 = try norm.normalize(try bin(&arena, .mul, x, try k(&arena, 31)), &arena);
    try std.testing.expectEqual(x31, try norm.normalize(try bin(&arena, .mul, x, try sel(&arena, try bin(&arena, .mul, x, try k(&arena, 32)), try k(&arena, 31), try k(&arena, 0xFFFFFFFF))), &arena));
    try std.testing.expectEqual(xx, try norm.normalize(try bin(&arena, .mul, x, try sel(&arena, try bin(&arena, .mul, x, try k(&arena, 4)), x, try k(&arena, 8))), &arena));
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .mul, x, try k(&arena, 0xFFFF)), &arena), try norm.normalize(try bin(&arena, .mul, x, try sel(&arena, try bin(&arena, .shl, x, try k(&arena, 8)), try k(&arena, 0xFFFF), try k(&arena, 0x7FFFFFFF))), &arena));
    // ... but the coefficient only matters mod 2^t: x mul select(x mul 4, 3, 5) is not x mul 3
    try std.testing.expect(try norm.normalize(try bin(&arena, .mul, x, try k(&arena, 3)), &arena) != try norm.normalize(try bin(&arena, .mul, x, try sel(&arena, try bin(&arena, .mul, x, try k(&arena, 4)), try k(&arena, 3), try k(&arena, 5))), &arena));
    // select(select(x, 0, z), x, x mul x) == x mul x;  y mul (x or (y ult 1)) == x mul y
    try std.testing.expectEqual(xx, try norm.normalize(try sel(&arena, try sel(&arena, x, try k(&arena, 0), z), x, try bin(&arena, .mul, x, x)), &arena));
    try std.testing.expectEqual(xy, try norm.normalize(try bin(&arena, .mul, y, try bin(&arena, .or_op, x, try bin(&arena, .ult, y, try k(&arena, 1)))), &arena));
    // select(x ult 2, x, x mul x) == x mul x;  (x mul 31) or (x eq 31) == x mul 31
    try std.testing.expectEqual(xx, try norm.normalize(try sel(&arena, try bin(&arena, .ult, x, try k(&arena, 2)), x, try bin(&arena, .mul, x, x)), &arena));
    try std.testing.expectEqual(x31, try norm.normalize(try bin(&arena, .or_op, try bin(&arena, .mul, x, try k(&arena, 31)), try bin(&arena, .eq, x, try k(&arena, 31))), &arena));
    // x ule (x sub popcount(x)) == x eq 0;  x ule ((x mul 3) lshr 2) == x eq 0;  x ule ((x and y) lshr 1) == x eq 0
    const xz0 = try norm.normalize(try bin(&arena, .ult, x, try k(&arena, 1)), &arena);
    try std.testing.expectEqual(xz0, try norm.normalize(try bin(&arena, .ule, x, try bin(&arena, .sub, x, try un(&arena, .popcount, x))), &arena));
    try std.testing.expectEqual(xz0, try norm.normalize(try bin(&arena, .ule, x, try bin(&arena, .lshr, try bin(&arena, .mul, x, try k(&arena, 3)), try k(&arena, 2))), &arena));
    try std.testing.expectEqual(xz0, try norm.normalize(try bin(&arena, .ule, x, try bin(&arena, .lshr, try bin(&arena, .and_op, x, y), try k(&arena, 1))), &arena));
    // ... but (x mul 4) lshr 2 is x for small x: x ule ((x mul 4) lshr 2) is not x eq 0
    try std.testing.expect(xz0 != try norm.normalize(try bin(&arena, .ule, x, try bin(&arena, .lshr, try bin(&arena, .mul, x, try k(&arena, 4)), try k(&arena, 2))), &arena));
    // x slt ((x mul 0xffff) lshr 16) == x lshr 31
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .lshr, x, try k(&arena, 31)), &arena), try norm.normalize(try bin(&arena, .slt, x, try bin(&arena, .lshr, try bin(&arena, .mul, x, try k(&arena, 0xFFFF)), try k(&arena, 16))), &arena));
    // select(popcount(x mul 3), 0, 1) == x ult 1
    try std.testing.expectEqual(xz0, try norm.normalize(try sel(&arena, try un(&arena, .popcount, try bin(&arena, .mul, x, try k(&arena, 3))), try k(&arena, 0), try k(&arena, 1)), &arena));
    // popcount(y) and (x or 0x7fffffff) == popcount(y);  popcount(y lshr ctz(y)) == popcount(y);  popcount(y shl (y ult 0xffff)) == popcount(y)
    const pcy = try norm.normalize(try un(&arena, .popcount, y), &arena);
    try std.testing.expectEqual(pcy, try norm.normalize(try bin(&arena, .and_op, try un(&arena, .popcount, y), try bin(&arena, .or_op, x, try k(&arena, 0x7FFFFFFF))), &arena));
    try std.testing.expectEqual(pcy, try norm.normalize(try un(&arena, .popcount, try bin(&arena, .lshr, y, try un(&arena, .ctz, y))), &arena));
    try std.testing.expectEqual(pcy, try norm.normalize(try un(&arena, .popcount, try bin(&arena, .shl, y, try bin(&arena, .ult, y, try k(&arena, 0xFFFF)))), &arena));
    // ... but a 16 mask is not covering: popcount(y) and 16 stays
    try std.testing.expect(pcy != try norm.normalize(try bin(&arena, .and_op, try un(&arena, .popcount, y), try k(&arena, 16)), &arena));
    // x ult (16 eq (y mul z)) == 16 eq (y mul select(x, 0, z))
    const yz = try bin(&arena, .mul, y, z);
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .eq, try k(&arena, 16), yz)), &arena), try norm.normalize(try bin(&arena, .eq, try k(&arena, 16), try bin(&arena, .mul, y, try sel(&arena, x, try k(&arena, 0), z))), &arena));
    // x ult (8 eq (y mul z)) == 8 eq (y mul select(x, y, z))
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .eq, try k(&arena, 8), yz)), &arena), try norm.normalize(try bin(&arena, .eq, try k(&arena, 8), try bin(&arena, .mul, y, try sel(&arena, x, y, z))), &arena));
    // select(y, x, select(x, x, 2)) == select(popcount(select(y, 31, x)), x, 2)
    try std.testing.expectEqual(try norm.normalize(try sel(&arena, y, x, try sel(&arena, x, x, try k(&arena, 2))), &arena), try norm.normalize(try sel(&arena, try un(&arena, .popcount, try sel(&arena, y, try k(&arena, 31), x)), x, try k(&arena, 2)), &arena));
    // select(x, 0, 3) == select(x mul select(y, 1, 0x7fffffff), 0, 3);  select(x, 0, 2) == select(x mul (y or 1), 0, 2)
    try std.testing.expectEqual(try norm.normalize(try sel(&arena, x, try k(&arena, 0), try k(&arena, 3)), &arena), try norm.normalize(try sel(&arena, try bin(&arena, .mul, x, try sel(&arena, y, try k(&arena, 1), try k(&arena, 0x7FFFFFFF))), try k(&arena, 0), try k(&arena, 3)), &arena));
    try std.testing.expectEqual(try norm.normalize(try sel(&arena, x, try k(&arena, 0), try k(&arena, 2)), &arena), try norm.normalize(try sel(&arena, try bin(&arena, .mul, x, try bin(&arena, .or_op, y, try k(&arena, 1))), try k(&arena, 0), try k(&arena, 2)), &arena));
    // ... but an even factor does change it: select(x mul (y or 2), 0, 2) is not select(x, 0, 2)
    try std.testing.expect(try norm.normalize(try sel(&arena, x, try k(&arena, 0), try k(&arena, 2)), &arena) != try norm.normalize(try sel(&arena, try bin(&arena, .mul, x, try bin(&arena, .or_op, y, try k(&arena, 2))), try k(&arena, 0), try k(&arena, 2)), &arena));
    // popcount(3 eq (y mul z)) == 3 eq (y mul select(z, z, 2))
    try std.testing.expectEqual(try norm.normalize(try un(&arena, .popcount, try bin(&arena, .eq, try k(&arena, 3), yz)), &arena), try norm.normalize(try bin(&arena, .eq, try k(&arena, 3), try bin(&arena, .mul, y, try sel(&arena, z, z, try k(&arena, 2)))), &arena));
    // (y add (x mul 0xffff)) ult -1 == (y xor (x mul 0xffff)) ult -1
    const xf = try bin(&arena, .mul, x, try k(&arena, 0xFFFF));
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .ult, try bin(&arena, .add, y, xf), try k(&arena, 0xFFFFFFFF)), &arena), try norm.normalize(try bin(&arena, .ult, try bin(&arena, .xor, y, xf), try k(&arena, 0xFFFFFFFF)), &arena));
    // select(y, x, select(x, 2, x)) == select(popcount(select(x, y, 1)), x, 2)
    try std.testing.expectEqual(try norm.normalize(try sel(&arena, y, x, try sel(&arena, x, try k(&arena, 2), x)), &arena), try norm.normalize(try sel(&arena, try un(&arena, .popcount, try sel(&arena, x, y, try k(&arena, 1))), x, try k(&arena, 2)), &arena));
    // y mul select(x, x, 0x80000000 shl y) == x mul y
    try std.testing.expectEqual(xy, try norm.normalize(try bin(&arena, .mul, y, try sel(&arena, x, x, try bin(&arena, .shl, try k(&arena, 0x80000000), y))), &arena));
    // (z slt 0x7fffffff) lshr select(y, 2, 4) == 0;  32 slt (16 mul (y ashr 31)) == 0
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .lshr, try bin(&arena, .slt, z, try k(&arena, 0x7FFFFFFF)), try sel(&arena, y, try k(&arena, 2), try k(&arena, 4))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .slt, try k(&arena, 32), try bin(&arena, .mul, try k(&arena, 16), try bin(&arena, .ashr, y, try k(&arena, 31)))), &arena));
    // select(not(x mul x), z, 0x7fffffff) == z;  4 eq (y mul (32 sub y)) == 0;  31 eq (x mul (x xor 31)) == 0
    try std.testing.expectEqual(nz, try norm.normalize(try sel(&arena, try un(&arena, .not, try bin(&arena, .mul, x, x)), z, try k(&arena, 0x7FFFFFFF)), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 4), try bin(&arena, .mul, y, try bin(&arena, .sub, try k(&arena, 32), y))), &arena));
    try std.testing.expectEqual(zero, try norm.normalize(try bin(&arena, .eq, try k(&arena, 31), try bin(&arena, .mul, x, try bin(&arena, .xor, x, try k(&arena, 31)))), &arena));
    // ... but y mul (32 sub y) == 0 has solutions
    try std.testing.expect(zero != try norm.normalize(try bin(&arena, .eq, try k(&arena, 0), try bin(&arena, .mul, y, try bin(&arena, .sub, try k(&arena, 32), y))), &arena));
    // The top bit of z mul 0xffff, written many ways.
    const zf = try bin(&arena, .mul, z, try k(&arena, 0xFFFF));
    const top = try norm.normalize(try bin(&arena, .ult, try k(&arena, 0x7FFFFFFF), zf), &arena);
    const zsel = try bin(&arena, .mul, try k(&arena, 0xFFFF), try sel(&arena, z, z, try k(&arena, 8)));
    for ([_]ast.ExprId{
        try bin(&arena, .lshr, zf, try k(&arena, 31)),
        try bin(&arena, .lshr, zsel, try k(&arena, 65535)),
        try bin(&arena, .ule, try k(&arena, 0x80000000), zsel),
        try bin(&arena, .slt, zsel, try k(&arena, 0)),
        try bin(&arena, .slt, zsel, try k(&arena, 1)),
        try bin(&arena, .ult, try k(&arena, 0x7FFFFFFF), try bin(&arena, .sub, try k(&arena, 0x7FFFFFFF), zf)),
        try bin(&arena, .ule, try k(&arena, 0x80000000), try bin(&arena, .sub, try k(&arena, 0x7FFFFFFF), zf)),
    }) |e| try std.testing.expectEqual(top, try norm.normalize(e, &arena));
    // ... but x slt 1 is not the top bit of x (x = 0)
    try std.testing.expect(try norm.normalize(try bin(&arena, .slt, x, try k(&arena, 1)), &arena) != try norm.normalize(try bin(&arena, .lshr, x, try k(&arena, 31)), &arena));
    // (z mul 0xffff) sle 0 == (0xffff mul select(z, z, -1)) lshr 0x7fffffff;  0 sle (z mul 0xffff) == 0 slt (0xffff mul select(z, z, 0x7fffffff))
    try std.testing.expectEqual(
        try norm.normalize(try bin(&arena, .sle, zf, try k(&arena, 0)), &arena),
        try norm.normalize(try bin(&arena, .lshr, try bin(&arena, .mul, try k(&arena, 0xFFFF), try sel(&arena, z, z, try k(&arena, 0xFFFFFFFF))), try k(&arena, 0x7FFFFFFF)), &arena),
    );
    try std.testing.expectEqual(
        try norm.normalize(try bin(&arena, .sle, try k(&arena, 0), zf), &arena),
        try norm.normalize(try bin(&arena, .slt, try k(&arena, 0), try bin(&arena, .mul, try k(&arena, 0xFFFF), try sel(&arena, z, z, try k(&arena, 0x7FFFFFFF)))), &arena),
    );
    // (x mul 0xffff) ashr 31 == (0x7fffffff sub (x mul 0xffff)) ashr 0xffff
    const xff = try bin(&arena, .mul, x, try k(&arena, 0xFFFF));
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .ashr, xff, try k(&arena, 31)), &arena), try norm.normalize(try bin(&arena, .ashr, try bin(&arena, .sub, try k(&arena, 0x7FFFFFFF), xff), try k(&arena, 0xFFFF)), &arena));
    // -1 eq (z add (x mul 0xffff)) == -1 eq (z xor (x mul 0xffff))
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .eq, try k(&arena, 0xFFFFFFFF), try bin(&arena, .add, z, xff)), &arena), try norm.normalize(try bin(&arena, .eq, try k(&arena, 0xFFFFFFFF), try bin(&arena, .xor, z, xff)), &arena));
    // x eq (0xffff mul select(x, z, 1)) == (z mul 0xffff) eq select(z, x, 31)
    try std.testing.expectEqual(
        try norm.normalize(try bin(&arena, .eq, x, try bin(&arena, .mul, try k(&arena, 0xFFFF), try sel(&arena, x, z, try k(&arena, 1)))), &arena),
        try norm.normalize(try bin(&arena, .eq, try bin(&arena, .mul, z, try k(&arena, 0xFFFF)), try sel(&arena, z, x, try k(&arena, 31))), &arena),
    );
    // ... but with an even coefficient zero-ness differs: x eq (2 mul select(x, z, 1)) vs (z mul 2) eq select(z, x, 31)
    try std.testing.expect(
        try norm.normalize(try bin(&arena, .eq, x, try bin(&arena, .mul, try k(&arena, 2), try sel(&arena, x, z, try k(&arena, 1)))), &arena) !=
            try norm.normalize(try bin(&arena, .eq, try bin(&arena, .mul, z, try k(&arena, 2)), try sel(&arena, z, x, try k(&arena, 31))), &arena),
    );
    // 1 add (z eq 4) == select(z sub select(z, 4, 1), 1, 2);  4 sub (x eq 31) == select(x sub select(x, 31, 1), 4, 3)
    try std.testing.expectEqual(
        try norm.normalize(try bin(&arena, .add, try k(&arena, 1), try bin(&arena, .eq, z, try k(&arena, 4))), &arena),
        try norm.normalize(try sel(&arena, try bin(&arena, .sub, z, try sel(&arena, z, try k(&arena, 4), try k(&arena, 1))), try k(&arena, 1), try k(&arena, 2)), &arena),
    );
    try std.testing.expectEqual(
        try norm.normalize(try bin(&arena, .sub, try k(&arena, 4), try bin(&arena, .eq, x, try k(&arena, 31))), &arena),
        try norm.normalize(try sel(&arena, try bin(&arena, .sub, x, try sel(&arena, x, try k(&arena, 31), try k(&arena, 1))), try k(&arena, 4), try k(&arena, 3)), &arena),
    );
    // 0 slt (z mul 0xffff) == 1 sle (0xffff mul select(z, z, 0xffff));  == (0xffff mul select(z, z, 0xffff)) ule 0x7fffffff
    const pos = try norm.normalize(try bin(&arena, .slt, try k(&arena, 0), zf), &arena);
    const zsel2 = try bin(&arena, .mul, try k(&arena, 0xFFFF), try sel(&arena, z, z, try k(&arena, 0xFFFF)));
    try std.testing.expectEqual(pos, try norm.normalize(try bin(&arena, .sle, try k(&arena, 1), zsel2), &arena));
    try std.testing.expectEqual(pos, try norm.normalize(try bin(&arena, .ule, zsel2, try k(&arena, 0x7FFFFFFF)), &arena));
    try std.testing.expectEqual(pos, try norm.normalize(try bin(&arena, .slt, try k(&arena, 0xFFFFFFFF), zsel2), &arena));
    // 1 eq (2 xor (y mul z)) == 3 eq (y mul select(z, z, 2)) == 3 eq (y mul select(z, z, y))
    const three = try norm.normalize(try bin(&arena, .eq, try k(&arena, 1), try bin(&arena, .xor, try k(&arena, 2), yz)), &arena);
    try std.testing.expectEqual(three, try norm.normalize(try bin(&arena, .eq, try k(&arena, 3), try bin(&arena, .mul, y, try sel(&arena, z, z, try k(&arena, 2)))), &arena));
    try std.testing.expectEqual(three, try norm.normalize(try bin(&arena, .eq, try k(&arena, 3), try bin(&arena, .mul, y, try sel(&arena, z, z, y))), &arena));
    // x ult (x ult y) == popcount(select(y, x, 1)) ule 0
    try std.testing.expectEqual(
        try norm.normalize(try bin(&arena, .ult, x, try bin(&arena, .ult, x, y)), &arena),
        try norm.normalize(try bin(&arena, .ule, try un(&arena, .popcount, try sel(&arena, y, x, try k(&arena, 1))), try k(&arena, 0)), &arena),
    );
    // ... but 0 eq (y mul z) does not imply z != 0: select(z, 0 eq (y mul z), 0) is not 0 eq (y mul z)
    try std.testing.expect(
        try norm.normalize(try bin(&arena, .eq, try k(&arena, 0), yz), &arena) != try norm.normalize(try sel(&arena, z, try bin(&arena, .eq, try k(&arena, 0), yz), try k(&arena, 0)), &arena),
    );
    // ... but x mul (x add 2) == 3 has solutions (x = 1), so it must not fold
    try std.testing.expect(zero != try norm.normalize(try bin(&arena, .eq, try k(&arena, 3), x2), &arena));
    // 1 eq (z mul select(y, 2, x)) == 1 eq (z mul select(y, 16, x))
    try std.testing.expectEqual(
        try norm.normalize(try bin(&arena, .eq, try k(&arena, 1), try bin(&arena, .mul, z, try sel(&arena, y, try k(&arena, 2), x))), &arena),
        try norm.normalize(try bin(&arena, .eq, try k(&arena, 1), try bin(&arena, .mul, z, try sel(&arena, y, try k(&arena, 16), x))), &arena),
    );
}

test "the rewrites Z3 is slowest at are recognised" {
    var arena = try ExpressionArena.init(test_alloc);
    defer arena.deinit();
    var norm = Normalizer.init(test_alloc);
    defer norm.deinit();
    const x = try arena.add(.{ .variable = .x });
    const y = try arena.add(.{ .variable = .y });
    const z = try arena.add(.{ .variable = .z });
    const m1 = try arena.add(.{ .constant = 0xFFFFFFFF });
    const bin = struct {
        fn f(a: *ExpressionArena, op: ast.BinOp, l: ast.ExprId, r: ast.ExprId) !ast.ExprId {
            return a.add(.{ .binary = .{ .op = op, .lhs = l, .rhs = r } });
        }
    }.f;
    // (((y shl x) shl y) shl z) == (((y shl y) shl z) shl x)
    const a1 = try bin(&arena, .shl, try bin(&arena, .shl, try bin(&arena, .shl, y, x), y), z);
    const a2 = try bin(&arena, .shl, try bin(&arena, .shl, try bin(&arena, .shl, y, y), z), x);
    try std.testing.expectEqual(try norm.normalize(a1, &arena), try norm.normalize(a2, &arena));
    // ((z xor -1) sub (x shl y)) == (-1 xor (z add (x shl y)))
    const b1 = try bin(&arena, .sub, try bin(&arena, .xor, z, m1), try bin(&arena, .shl, x, y));
    const b2 = try bin(&arena, .xor, m1, try bin(&arena, .add, z, try bin(&arena, .shl, x, y)));
    try std.testing.expectEqual(try norm.normalize(b1, &arena), try norm.normalize(b2, &arena));
    // (-1 xor ((z sub x) shl y)) == (((x sub z) shl y) sub 1)
    const c1 = try bin(&arena, .xor, m1, try bin(&arena, .shl, try bin(&arena, .sub, z, x), y));
    const c2 = try bin(&arena, .sub, try bin(&arena, .shl, try bin(&arena, .sub, x, z), y), try arena.add(.{ .constant = 1 }));
    try std.testing.expectEqual(try norm.normalize(c1, &arena), try norm.normalize(c2, &arena));
    // ((x lshr z) lshr (x add y)) == ((x lshr (x add y)) lshr z)
    const xy = try bin(&arena, .add, x, y);
    const d1 = try bin(&arena, .lshr, try bin(&arena, .lshr, x, z), xy);
    const d2 = try bin(&arena, .lshr, try bin(&arena, .lshr, x, xy), z);
    try std.testing.expectEqual(try norm.normalize(d1, &arena), try norm.normalize(d2, &arena));
    const k = struct {
        fn f(a: *ExpressionArena, c: u32) !ast.ExprId {
            return a.add(.{ .constant = c });
        }
    }.f;
    const un = struct {
        fn f(a: *ExpressionArena, op: ast.UnOp, e: ast.ExprId) !ast.ExprId {
            return a.add(.{ .unary = .{ .op = op, .expr = e } });
        }
    }.f;
    // (0x7FFFFFFF sub (x mul 65535)) == (0x7FFFFFFF xor (x mul 65535))
    const xm = try bin(&arena, .mul, x, try k(&arena, 65535));
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .sub, try k(&arena, 0x7FFFFFFF), xm), &arena), try norm.normalize(try bin(&arena, .xor, try k(&arena, 0x7FFFFFFF), xm), &arena));
    // popcount(not(y)) == 32 sub popcount(y);  65535 xor popcount(z) == 65535 sub popcount(z)
    try std.testing.expectEqual(try norm.normalize(try un(&arena, .popcount, try un(&arena, .not, y)), &arena), try norm.normalize(try bin(&arena, .sub, try k(&arena, 32), try un(&arena, .popcount, y)), &arena));
    const pz = try un(&arena, .popcount, z);
    try std.testing.expectEqual(try norm.normalize(try bin(&arena, .xor, try k(&arena, 65535), pz), &arena), try norm.normalize(try bin(&arena, .sub, try k(&arena, 65535), pz), &arena));
    // x ult 1 == 32 ule ctz(x) == -1 ule not(x) == -1 ule (x sub 1) == 31 slt clz(x) == x eq 0
    const zero_x = try norm.normalize(try bin(&arena, .ult, x, try k(&arena, 1)), &arena);
    for ([_]ast.ExprId{
        try bin(&arena, .ule, try k(&arena, 32), try un(&arena, .ctz, x)),
        try bin(&arena, .ule, m1, try un(&arena, .not, x)),
        try bin(&arena, .ule, m1, try bin(&arena, .sub, x, try k(&arena, 1))),
        try bin(&arena, .slt, try k(&arena, 31), try un(&arena, .clz, x)),
        try bin(&arena, .eq, try k(&arena, 0), x),
    }) |e| try std.testing.expectEqual(zero_x, try norm.normalize(e, &arena));
    // Selects whose branches repeat the condition (Z3 times out on the multiplications).
    const sel = struct {
        fn f(a: *ExpressionArena, c: ast.ExprId, t: ast.ExprId, e: ast.ExprId) !ast.ExprId {
            return a.add(.{ .select = .{ .cond = c, .true_val = t, .false_val = e } });
        }
    }.f;
    const x_mul_y = try bin(&arena, .mul, x, y);
    // x mul select(x, y, x) == x mul y
    try std.testing.expectEqual(try norm.normalize(x_mul_y, &arena), try norm.normalize(try bin(&arena, .mul, x, try sel(&arena, x, y, x)), &arena));
    // select(x, x mul y, 0) == x mul y
    try std.testing.expectEqual(try norm.normalize(x_mul_y, &arena), try norm.normalize(try sel(&arena, x, x_mul_y, try k(&arena, 0)), &arena));
    // y mul select(x, y, x) == select(x, y mul y, 0)
    try std.testing.expectEqual(try norm.normalize(try sel(&arena, x, try bin(&arena, .mul, y, y), try k(&arena, 0)), &arena), try norm.normalize(try bin(&arena, .mul, y, try sel(&arena, x, y, x)), &arena));
    // x mul select(z, x, z) == select(z, x mul x, 0)
    try std.testing.expectEqual(try norm.normalize(try sel(&arena, z, try bin(&arena, .mul, x, x), try k(&arena, 0)), &arena), try norm.normalize(try bin(&arena, .mul, x, try sel(&arena, z, x, z)), &arena));
    // x mul select(y, 0, z) == select(y, 0, x mul z)
    try std.testing.expectEqual(try norm.normalize(try sel(&arena, y, try k(&arena, 0), try bin(&arena, .mul, x, z)), &arena), try norm.normalize(try bin(&arena, .mul, x, try sel(&arena, y, try k(&arena, 0), z)), &arena));
    // A select on a nonzero-test must not collapse: select(x, y, z) vs y.
    try std.testing.expect(try norm.normalize(try sel(&arena, x, y, z), &arena) != try norm.normalize(y, &arena));
    // Different functions must not collide: (x shl y) vs (x lshr y).
    try std.testing.expect(try norm.normalize(try bin(&arena, .shl, x, y), &arena) != try norm.normalize(try bin(&arena, .lshr, x, y), &arena));
}
