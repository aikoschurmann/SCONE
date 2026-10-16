const sqlite_db = @import("sqlite_db.zig");
const database = @import("database.zig");
const std = @import("std");
const ast = @import("ast.zig");
const vector_arena = @import("vector_arena.zig");
const expr_arena = @import("arena.zig");

const config = @import("config.zig");

pub fn fill_leaf(ctx: *const EvaluationContext, expr: ast.Expr, out: []Vector64) void {
    switch (expr) {
        .variable => |v| {
            const src = switch (v) {
                .x => ctx.x_batches,
                .y => ctx.y_batches,
                .z => ctx.z_batches,
            };
            @memcpy(out, src[0..out.len]);
        },
        .constant => |c| @memset(out, @as(Vector64, @splat(c))),
        else => unreachable,
    }
}

pub fn combine_unary_into(op: ast.UnOp, child: []const Vector64, out: []Vector64) void {
    switch (op) {
        inline else => |comptime_op| {
            for (child, 0..) |cv, i| {
                out[i] = switch (comptime_op) {
                    .not => ~cv,
                    .neg => @as(Vector64, @splat(0)) -% cv,
                    .clz => @as(Vector64, @intCast(@clz(cv))),
                    .ctz => @as(Vector64, @intCast(@ctz(cv))),
                    .popcount => @as(Vector64, @intCast(@popCount(cv))),
                };
            }
        },
    }
}

pub fn combine_binary_into(op: ast.BinOp, lhs: []const Vector64, rhs: []const Vector64, out: []Vector64) void {
    switch (op) {
        inline else => |comptime_op| {
            for (0..out.len) |i| {
                const l = lhs[i];
                const r = rhs[i];
                out[i] = switch (comptime_op) {
                    .add => l +% r,
                    .sub => l -% r,
                    .mul => l *% r,
                    .and_op => l & r,
                    .or_op => l | r,
                    .xor => l ^ r,
                    .shl => l << @as(@Vector(BATCH_SIZE, u5), @truncate(r)),
                    .lshr => l >> @as(@Vector(BATCH_SIZE, u5), @truncate(r)),
                    .ashr => @as(Vector64, @bitCast(@as(@Vector(BATCH_SIZE, i32), @bitCast(l)) >> @as(@Vector(BATCH_SIZE, u5), @truncate(r)))),
                    .eq => @select(u32, l == r, @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                    .ult => @select(u32, l < r, @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                    .ule => @select(u32, l <= r, @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                    .slt => @select(u32, @as(@Vector(BATCH_SIZE, i32), @bitCast(l)) < @as(@Vector(BATCH_SIZE, i32), @bitCast(r)), @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                    .sle => @select(u32, @as(@Vector(BATCH_SIZE, i32), @bitCast(l)) <= @as(@Vector(BATCH_SIZE, i32), @bitCast(r)), @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                };
            }
        },
    }
}

pub fn combine_select_into(cond: []const Vector64, t: []const Vector64, f: []const Vector64, out: []Vector64) void {
    for (0..out.len) |i| {
        const cv = cond[i] != @as(Vector64, @splat(0));
        out[i] = @select(u32, cv, t[i], f[i]);
    }
}

pub fn hash_vectors(vectors: []const Vector64) database.FingerprintHash {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vectors));
}

const ValuePool = std.BoundedArray(u32, config.base_edge_cases.len + 3 * config.search_constants.len + 64);

/// Edge cases plus every search constant and its neighbours. Comparisons against a constant
/// (x < 3, x == 16) are 0 on almost every uniform random input, so they need these values to be
/// told apart.
fn interesting_values() ValuePool {
    var pool = ValuePool.init(0) catch unreachable;
    const add = struct {
        fn f(p: *ValuePool, v: u32) void {
            if (std.mem.indexOfScalar(u32, p.slice(), v) == null) p.appendAssumeCapacity(v);
        }
    }.f;
    for (config.base_edge_cases) |v| add(&pool, v);
    for (config.search_constants) |c| {
        add(&pool, c -% 1);
        add(&pool, c);
        add(&pool, c +% 1);
    }
    // -1 .. -64: counts (popcount, clz, ctz) are 0..32, and identities mixing a value with its
    // count break at small negatives (x + popcount(x) is 0 only at x = -28 and -29).
    for (1..65) |k| add(&pool, 0 -% @as(u32, @intCast(k)));
    return pool;
}

/// Half of the values come from the pool, a quarter are small, and a quarter are uniform random.
fn sample_value(rand: std.Random, pool: []const u32) u32 {
    return switch (rand.uintLessThan(u8, 4)) {
        0, 1 => pool[rand.uintLessThan(usize, pool.len)],
        2 => rand.uintLessThan(u32, 64),
        else => rand.int(u32),
    };
}

/// Scalar evaluation at a single input; must match the vector semantics in combine_*_into.
pub fn eval_point(expr_id: ast.ExprId, expr_arena_ref: *const expr_arena.ExpressionArena, x: u32, y: u32, z: u32) u32 {
    return switch (expr_arena_ref.get(expr_id)) {
        .variable => |v| switch (v) {
            .x => x,
            .y => y,
            .z => z,
        },
        .constant => |c| c,
        .unary => |u| blk: {
            const a = eval_point(u.expr, expr_arena_ref, x, y, z);
            break :blk switch (u.op) {
                .not => ~a,
                .neg => 0 -% a,
                .clz => @clz(a),
                .ctz => @ctz(a),
                .popcount => @popCount(a),
            };
        },
        .binary => |b| blk: {
            const l = eval_point(b.lhs, expr_arena_ref, x, y, z);
            const r = eval_point(b.rhs, expr_arena_ref, x, y, z);
            const sh: u5 = @truncate(r);
            break :blk switch (b.op) {
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
        },
        .select => |s| if (eval_point(s.cond, expr_arena_ref, x, y, z) != 0)
            eval_point(s.true_val, expr_arena_ref, x, y, z)
        else
            eval_point(s.false_val, expr_arena_ref, x, y, z),
    };
}

pub const BATCH_SIZE = 64;
pub const Vector64 = @Vector(BATCH_SIZE, u32);

pub const EvaluationContext = struct {
    x_batches: []Vector64,
    y_batches: []Vector64,
    z_batches: []Vector64,
    num_batches: usize,
    total_samples: usize,
    allocator: std.mem.Allocator,

    pub fn setSample(ctx: *EvaluationContext, idx: usize, x: u32, y: u32, z: u32) void {
        const batch_idx = idx / BATCH_SIZE;
        const lane_idx = idx % BATCH_SIZE;
        ctx.x_batches[batch_idx][lane_idx] = x;
        ctx.y_batches[batch_idx][lane_idx] = y;
        ctx.z_batches[batch_idx][lane_idx] = z;
    }

    pub fn deinit(self: *EvaluationContext) void {
        self.allocator.free(self.x_batches);
        self.allocator.free(self.y_batches);
        self.allocator.free(self.z_batches);
    }

    pub fn init(allocator: std.mem.Allocator, sqlite: ?*const sqlite_db.SqliteDb) !EvaluationContext {
        // Calculate dynamic capacity based on file size + padding
        var ce_count: usize = 0;
        if (sqlite) |db| {
            ce_count = db.get_ce_count();
        }

        const total_samples = (if (config.active.use_cartesian_grid) config.num_edge_cases * config.num_edge_cases * config.num_edge_cases else 0) + ce_count + config.active.num_random_samples;
        const num_batches = (total_samples + BATCH_SIZE - 1) / BATCH_SIZE;

        var ctx = EvaluationContext{
            .allocator = allocator,
            .num_batches = num_batches,
            .total_samples = total_samples,
            .x_batches = try allocator.alloc(Vector64, num_batches),
            .y_batches = try allocator.alloc(Vector64, num_batches),
            .z_batches = try allocator.alloc(Vector64, num_batches),
        };
        @memset(ctx.x_batches, @as(Vector64, @splat(0)));
        @memset(ctx.y_batches, @as(Vector64, @splat(0)));
        @memset(ctx.z_batches, @as(Vector64, @splat(0)));

        var idx: usize = 0;

        // 1) The exhaustive edge-case grid (if enabled)
        if (config.active.use_cartesian_grid) {
            for (config.base_edge_cases) |x| {
                for (config.base_edge_cases) |y| {
                    for (config.base_edge_cases) |z| {
                        ctx.setSample(idx, x, y, z);
                        idx += 1;
                    }
                }
            }
        }

        // 2) Counterexamples found by Z3 while verifying earlier cost levels
        if (ce_count > 0) {
            const loaded = sqlite.?.load_ces(&ctx, idx, ce_count);
            idx += loaded;
            std.debug.print("Loaded {} counterexamples from Z3.\n", .{loaded});
        }
        // 3) Default samples: a mix of edge values and uniform random values (see sample_value).
        var prng = std.Random.DefaultPrng.init(0xC0FFEE_C0FFEE);
        const rand = prng.random();
        const pool = interesting_values();
        while (idx < total_samples) : (idx += 1) {
            if (config.active.uniform_random_samples) {
                ctx.setSample(idx, rand.int(u32), rand.int(u32), rand.int(u32));
                continue;
            }
            const x = sample_value(rand, pool.slice());
            var y = sample_value(rand, pool.slice());
            var z = sample_value(rand, pool.slice());
            // Aliased variables are needed to separate e.g. (x == y) from 0, or (x - y) from (x ^ y).
            switch (rand.uintLessThan(u8, 16)) {
                0 => y = x,
                1 => z = x,
                2 => z = y,
                else => {},
            }
            ctx.setSample(idx, x, y, z);
        }

        return ctx;
    }
};

pub fn eval_batch(ctx: *const EvaluationContext, expr: ast.Expr, expr_arena_ref: *const expr_arena.ExpressionArena, batch_idx: usize) Vector64 {
    switch (expr) {
        .variable => |v| {
            return switch (v) {
                .x => ctx.x_batches[batch_idx],
                .y => ctx.y_batches[batch_idx],
                .z => ctx.z_batches[batch_idx],
            };
        },
        .constant => |c| {
            return @splat(c);
        },
        .unary => |un| {
            const child_expr = expr_arena_ref.get(un.expr);
            const child_fp = eval_batch(ctx, child_expr, expr_arena_ref, batch_idx);
            return switch (un.op) {
                .not => ~child_fp,
                .neg => @as(Vector64, @splat(0)) -% child_fp,
                .clz => @as(Vector64, @intCast(@clz(child_fp))),
                .ctz => @as(Vector64, @intCast(@ctz(child_fp))),
                .popcount => @as(Vector64, @intCast(@popCount(child_fp))),
            };
        },
        .binary => |bin| {
            const lhs_expr = expr_arena_ref.get(bin.lhs);
            const rhs_expr = expr_arena_ref.get(bin.rhs);
            const lhs_fp = eval_batch(ctx, lhs_expr, expr_arena_ref, batch_idx);
            const rhs_fp = eval_batch(ctx, rhs_expr, expr_arena_ref, batch_idx);
            return switch (bin.op) {
                .add => lhs_fp +% rhs_fp,
                .sub => lhs_fp -% rhs_fp,
                .mul => lhs_fp *% rhs_fp,
                .and_op => lhs_fp & rhs_fp,
                .or_op => lhs_fp | rhs_fp,
                .xor => lhs_fp ^ rhs_fp,
                .shl => lhs_fp << @as(@Vector(BATCH_SIZE, u5), @truncate(rhs_fp)),
                .lshr => lhs_fp >> @as(@Vector(BATCH_SIZE, u5), @truncate(rhs_fp)),
                .ashr => @as(Vector64, @bitCast(@as(@Vector(BATCH_SIZE, i32), @bitCast(lhs_fp)) >> @as(@Vector(BATCH_SIZE, u5), @truncate(rhs_fp)))),
                .eq => @select(u32, lhs_fp == rhs_fp, @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                .ult => @select(u32, lhs_fp < rhs_fp, @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                .ule => @select(u32, lhs_fp <= rhs_fp, @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                .slt => @select(u32, @as(@Vector(BATCH_SIZE, i32), @bitCast(lhs_fp)) < @as(@Vector(BATCH_SIZE, i32), @bitCast(rhs_fp)), @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
                .sle => @select(u32, @as(@Vector(BATCH_SIZE, i32), @bitCast(lhs_fp)) <= @as(@Vector(BATCH_SIZE, i32), @bitCast(rhs_fp)), @as(Vector64, @splat(1)), @as(Vector64, @splat(0))),
            };
        },
        .select => |sel| {
            const cond_expr = expr_arena_ref.get(sel.cond);
            const t_expr = expr_arena_ref.get(sel.true_val);
            const f_expr = expr_arena_ref.get(sel.false_val);
            const cond_fp = eval_batch(ctx, cond_expr, expr_arena_ref, batch_idx);
            const t_fp = eval_batch(ctx, t_expr, expr_arena_ref, batch_idx);
            const f_fp = eval_batch(ctx, f_expr, expr_arena_ref, batch_idx);
            const condition_vector = cond_fp != @as(Vector64, @splat(0));
            return @select(u32, condition_vector, t_fp, f_fp);
        },
    }
}

pub fn eval_and_hash(ctx: *const EvaluationContext, expr: ast.Expr, expr_arena_ref: *const expr_arena.ExpressionArena) database.FingerprintHash {
    var hasher = std.hash.Wyhash.init(0);
    for (0..ctx.num_batches) |batch_idx| {
        const batch_res = eval_batch(ctx, expr, expr_arena_ref, batch_idx);
        hasher.update(std.mem.asBytes(&batch_res));
    }
    return hasher.final();
}
