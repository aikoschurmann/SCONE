const std = @import("std");
const ast = @import("ast.zig");
const eval_mod = @import("eval.zig");
const database = @import("database.zig");
const config = @import("config.zig");
const absint = @import("absint.zig");
const normalize = @import("normalize.zig");
const exhaustive = @import("exhaustive.zig");
const ExpressionArena = @import("arena.zig").ExpressionArena;

pub const z3 = @cImport({
    @cInclude("z3.h");
});

pub const CE = struct {
    x: u32,
    y: u32,
    z: u32,
};

fn mk_clz(ctx: z3.Z3_context, expr: z3.Z3_ast) z3.Z3_ast {
    const sort = z3.Z3_mk_bv_sort(ctx, 32);
    var res = z3.Z3_mk_unsigned_int64(ctx, 32, sort);
    const one_bit = z3.Z3_mk_unsigned_int64(ctx, 1, z3.Z3_mk_bv_sort(ctx, 1));

    for (0..32) |i| {
        const bit = z3.Z3_mk_extract(ctx, @intCast(i), @intCast(i), expr);
        const is_one = z3.Z3_mk_eq(ctx, bit, one_bit);
        const val = z3.Z3_mk_unsigned_int64(ctx, 31 - i, sort);
        res = z3.Z3_mk_ite(ctx, is_one, val, res);
    }
    return res;
}

fn mk_ctz(ctx: z3.Z3_context, expr: z3.Z3_ast) z3.Z3_ast {
    const sort = z3.Z3_mk_bv_sort(ctx, 32);
    var res = z3.Z3_mk_unsigned_int64(ctx, 32, sort);
    const one_bit = z3.Z3_mk_unsigned_int64(ctx, 1, z3.Z3_mk_bv_sort(ctx, 1));

    var i: i32 = 31;
    while (i >= 0) : (i -= 1) {
        const bit = z3.Z3_mk_extract(ctx, @intCast(i), @intCast(i), expr);
        const is_one = z3.Z3_mk_eq(ctx, bit, one_bit);
        const val = z3.Z3_mk_unsigned_int64(ctx, @intCast(i), sort);
        res = z3.Z3_mk_ite(ctx, is_one, val, res);
    }
    return res;
}

fn mk_popcount(ctx: z3.Z3_context, expr: z3.Z3_ast) z3.Z3_ast {
    const sort = z3.Z3_mk_bv_sort(ctx, 32);
    var sum = z3.Z3_mk_unsigned_int64(ctx, 0, sort);
    const one_bit = z3.Z3_mk_unsigned_int64(ctx, 1, z3.Z3_mk_bv_sort(ctx, 1));
    const one_32 = z3.Z3_mk_unsigned_int64(ctx, 1, sort);
    const zero_32 = z3.Z3_mk_unsigned_int64(ctx, 0, sort);

    for (0..32) |i| {
        const bit = z3.Z3_mk_extract(ctx, @intCast(i), @intCast(i), expr);
        const is_one = z3.Z3_mk_eq(ctx, bit, one_bit);
        const val = z3.Z3_mk_ite(ctx, is_one, one_32, zero_32);
        sum = z3.Z3_mk_bvadd(ctx, sum, val);
    }
    return sum;
}

pub const Z3Result = union(enum) {
    sat: CE,
    unsat: void,
    timeout: void,
};

/// Per-thread Z3 state. Creating a context is expensive compared with most of the checks we run,
/// so each thread keeps one context and memoizes the translation of every expression it has seen
/// (canonical sub-expressions are shared by thousands of class members). A context without
/// reference counting keeps every AST alive, so it is recycled every `recycle_after` checks.
const Z3Worker = struct {
    /// Every check's bit-blasted terms stay in the context's AST table, and growing that table
    /// (chashtable::expand_table) took about half the solver time at 4096. 256 verified cost 2
    /// ~27% faster; 64 was no better.
    const recycle_after = 256;
    /// Translating members is not counted as a check, so bound the AST cache as well.
    const max_cached_asts = 200_000;

    cfg: z3.Z3_config,
    ctx: z3.Z3_context,
    sort: z3.Z3_sort,
    x: z3.Z3_ast,
    y: z3.Z3_ast,
    z: z3.Z3_ast,
    zero: z3.Z3_ast,
    one: z3.Z3_ast,
    mask31: z3.Z3_ast,
    cache: std.AutoHashMap(ast.ExprId, z3.Z3_ast),
    checks: usize = 0,
    /// Algebraic normal forms; independent of the Z3 context, so it survives recycling.
    norm: normalize.Normalizer,

    fn init(allocator: std.mem.Allocator) Z3Worker {
        const cfg = z3.Z3_mk_config();
        const ctx = z3.Z3_mk_context(cfg);
        const sort = z3.Z3_mk_bv_sort(ctx, 32);
        return .{
            .cfg = cfg,
            .ctx = ctx,
            .sort = sort,
            .x = z3.Z3_mk_const(ctx, z3.Z3_mk_string_symbol(ctx, "x"), sort),
            .y = z3.Z3_mk_const(ctx, z3.Z3_mk_string_symbol(ctx, "y"), sort),
            .z = z3.Z3_mk_const(ctx, z3.Z3_mk_string_symbol(ctx, "z"), sort),
            .zero = z3.Z3_mk_unsigned_int64(ctx, 0, sort),
            .one = z3.Z3_mk_unsigned_int64(ctx, 1, sort),
            .mask31 = z3.Z3_mk_unsigned_int64(ctx, 31, sort),
            .cache = std.AutoHashMap(ast.ExprId, z3.Z3_ast).init(allocator),
            // Many small, short-lived allocations: page_allocator would make each one a syscall.
            .norm = normalize.Normalizer.init(std.heap.c_allocator),
        };
    }

    fn deinit(self: *Z3Worker) void {
        self.norm.deinit();
        self.deinit_z3();
    }

    fn deinit_z3(self: *Z3Worker) void {
        self.cache.deinit();
        z3.Z3_del_context(self.ctx);
        z3.Z3_del_config(self.cfg);
    }

    fn recycle_if_needed(self: *Z3Worker) void {
        if (self.checks < recycle_after and self.cache.count() < max_cached_asts) return;
        const allocator = self.cache.allocator;
        const norm = self.norm;
        self.deinit_z3();
        self.* = init(allocator);
        self.norm.deinit();
        self.norm = norm;
    }

    fn bool_to_bv(self: *Z3Worker, cond: z3.Z3_ast) z3.Z3_ast {
        return z3.Z3_mk_ite(self.ctx, cond, self.one, self.zero);
    }

    fn translate(self: *Z3Worker, expr_id: ast.ExprId, arena: *const ExpressionArena) z3.Z3_ast {
        if (self.cache.get(expr_id)) |cached| return cached;
        const ctx = self.ctx;
        const result = switch (arena.get(expr_id)) {
            .variable => |v| switch (v) {
                .x => self.x,
                .y => self.y,
                .z => self.z,
            },
            .constant => |c| z3.Z3_mk_unsigned_int64(ctx, @as(u64, c), self.sort),
            .unary => |u| blk: {
                const child = self.translate(u.expr, arena);
                break :blk switch (u.op) {
                    .neg => z3.Z3_mk_bvneg(ctx, child),
                    .not => z3.Z3_mk_bvnot(ctx, child),
                    .clz => mk_clz(ctx, child),
                    .ctz => mk_ctz(ctx, child),
                    .popcount => mk_popcount(ctx, child),
                };
            },
            .binary => |b| blk: {
                const l = self.translate(b.lhs, arena);
                const r = self.translate(b.rhs, arena);
                break :blk switch (b.op) {
                    .add => z3.Z3_mk_bvadd(ctx, l, r),
                    .sub => z3.Z3_mk_bvsub(ctx, l, r),
                    .mul => z3.Z3_mk_bvmul(ctx, l, r),
                    .and_op => z3.Z3_mk_bvand(ctx, l, r),
                    .or_op => z3.Z3_mk_bvor(ctx, l, r),
                    .xor => z3.Z3_mk_bvxor(ctx, l, r),
                    .shl => z3.Z3_mk_bvshl(ctx, l, z3.Z3_mk_bvand(ctx, r, self.mask31)),
                    .lshr => z3.Z3_mk_bvlshr(ctx, l, z3.Z3_mk_bvand(ctx, r, self.mask31)),
                    .ashr => z3.Z3_mk_bvashr(ctx, l, z3.Z3_mk_bvand(ctx, r, self.mask31)),
                    .ult => self.bool_to_bv(z3.Z3_mk_bvult(ctx, l, r)),
                    .ule => self.bool_to_bv(z3.Z3_mk_bvule(ctx, l, r)),
                    .slt => self.bool_to_bv(z3.Z3_mk_bvslt(ctx, l, r)),
                    .sle => self.bool_to_bv(z3.Z3_mk_bvsle(ctx, l, r)),
                    .eq => self.bool_to_bv(z3.Z3_mk_eq(ctx, l, r)),
                };
            },
            .select => |s| blk: {
                const c = self.translate(s.cond, arena);
                const t = self.translate(s.true_val, arena);
                const f = self.translate(s.false_val, arena);
                break :blk z3.Z3_mk_ite(ctx, z3.Z3_mk_eq(ctx, c, self.zero), f, t);
            },
        };
        self.cache.put(expr_id, result) catch {};
        return result;
    }

    fn model_value(self: *Z3Worker, model: z3.Z3_model, v: z3.Z3_ast) u32 {
        var out: z3.Z3_ast = undefined;
        var val: u64 = 0;
        if (z3.Z3_model_eval(self.ctx, model, v, true, &out) and z3.Z3_get_numeral_uint64(self.ctx, out, &val)) {
            return @truncate(val);
        }
        return 0;
    }

    /// True when Z3's rewriter alone reduces `base == member` to true. This costs microseconds
    /// instead of a solver call, and settles a large share of the members of a level.
    fn trivially_equal(self: *Z3Worker, base: ast.ExprId, member: ast.ExprId, arena: *const ExpressionArena) bool {
        self.recycle_if_needed();
        const eq = z3.Z3_mk_eq(self.ctx, self.translate(base, arena), self.translate(member, arena));
        return z3.Z3_is_eq_ast(self.ctx, z3.Z3_simplify(self.ctx, eq), z3.Z3_mk_true(self.ctx));
    }

    /// Asks Z3 whether any of `members` differs from `base` on some input.
    fn check(self: *Z3Worker, allocator: std.mem.Allocator, base: ast.ExprId, members: []const ast.ExprId, arena: *const ExpressionArena, timeout_ms: u32) Z3Result {
        self.recycle_if_needed();
        self.checks += 1;
        const ctx = self.ctx;

        const base_z3 = self.translate(base, arena);
        const conds = allocator.alloc(z3.Z3_ast, members.len) catch return .timeout;
        defer allocator.free(conds);
        for (members, conds) |m, *cond| {
            cond.* = z3.Z3_mk_not(ctx, z3.Z3_mk_eq(ctx, base_z3, self.translate(m, arena)));
        }

        const solver = z3.Z3_mk_solver_for_logic(ctx, z3.Z3_mk_string_symbol(ctx, "QF_BV"));
        z3.Z3_solver_inc_ref(ctx, solver);
        defer z3.Z3_solver_dec_ref(ctx, solver);

        const params = z3.Z3_mk_params(ctx);
        z3.Z3_params_inc_ref(ctx, params);
        defer z3.Z3_params_dec_ref(ctx, params);
        z3.Z3_params_set_uint(ctx, params, z3.Z3_mk_string_symbol(ctx, "timeout"), timeout_ms);
        z3.Z3_solver_set_params(ctx, solver, params);

        const goal = if (conds.len == 1) conds[0] else z3.Z3_mk_or(ctx, @intCast(conds.len), conds.ptr);
        z3.Z3_solver_assert(ctx, solver, goal);

        const result = z3.Z3_solver_check(ctx, solver);
        if (result == z3.Z3_L_FALSE) return .unsat;
        if (result != z3.Z3_L_TRUE) return .timeout;

        const model = z3.Z3_solver_get_model(ctx, solver);
        if (model == null) return .timeout;
        z3.Z3_model_inc_ref(ctx, model);
        defer z3.Z3_model_dec_ref(ctx, model);
        return .{ .sat = .{ .x = self.model_value(model, self.x), .y = self.model_value(model, self.y), .z = self.model_value(model, self.z) } };
    }
};

/// Members per Z3 query. One query over a whole class is hopeless for classes with tens of
/// thousands of members (e.g. everything that folds to 0). Throughput was flat between 1 and 32.
const chunk_size = 32;

/// Timeout multipliers for a single member whose check still times out on its own.
const timeout_escalation = [_]u32{ 4, 16 };

/// A set of expressions proven equal to `base`. When `base` is the canonical expression of
/// `class_id` the group stays in that class; otherwise it was split off and becomes a new class.
const Group = struct {
    class_id: database.ClassId,
    base: ast.ExprId,
    members: []const ast.ExprId,
    unverified: bool,
};

const Task = struct {
    class_id: database.ClassId,
    members: []const ast.ExprId,
};

const max_shared_ces = 8192;

/// What one worker process is doing right now, for the live status file.
const Slot = struct {
    /// Index into `tasks` plus one; 0 while idle.
    task: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    queries: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ces: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    timeouts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};
const max_slots = 256;

/// Tasks are sorted by size, so each bucket is a contiguous range of `tasks`.
const Bucket = struct { min_size: usize, lo: usize = 0, hi: usize = 0, exprs: usize = 0 };
const bucket_sizes = [_]usize{ 1024, 256, 64, 16, 4, 2, 1 };

/// Live view of the workers, rewritten about once a second while verifying. The dashboard reads
/// it; nothing else depends on it.
const status_path = "scone_status.json";

/// Normal-form nodes a worker keeps before starting over (a few tens of bytes each).
const max_normal_forms = 2_000_000;

const Shared = struct {
    db: *const database.ExpressionDatabase,
    tasks: []const Task,
    /// Abstract value (range + known bits) of every class created before this level.
    class_av: []const absint.AV,
    next_task: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    exprs_done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total_exprs: usize,
    num_queries: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_simplified: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_absint: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_normalized: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_audited: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_audit_failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_audit_timeouts: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_ces: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_shared_ejections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_splits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_unverified: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_mismatches: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Timed-out queries settled by `needle_search` instead of halving and longer timeouts.
    num_needles: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    num_exhaustive: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_time: i64,
    /// Workers exit when this process goes away: on macOS a forked child outlives its parent, and
    /// an orphaned worker would keep Z3 running with nobody left to read its results.
    parent_pid: std.posix.pid_t,
    last_print: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    ce_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    num_shared_ces: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    shared_ces: [max_shared_ces]CE = undefined,

    num_slots: usize = 0,
    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    buckets: [bucket_sizes.len]Bucket = undefined,
    last_status: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
};

/// This process's slot; set once in each forked worker.
var my_slot: ?*Slot = null;

const WorkerOut = struct {
    arena: std.heap.ArenaAllocator,
    groups: std.ArrayList(Group),
    ces: std.ArrayList(CE),
};

const Valued = struct {
    value: u32,
    expr: ast.ExprId,

    fn lessThan(_: void, a: Valued, b: Valued) bool {
        return a.value < b.value or (a.value == b.value and a.expr < b.expr);
    }
};

/// Abstract value of an expression of the current level (or a split-off base): its children are
/// canonical expressions of earlier levels, whose class summaries are precomputed.
fn av_of(shared: *const Shared, id: ast.ExprId) absint.AV {
    const db = shared.db;
    const cls = db.expr_to_class.items;
    return switch (db.expr_arena.get(id)) {
        .variable => absint.AV.top,
        .constant => |c| absint.AV.constant(c),
        .unary => |u| absint.unary(u.op, shared.class_av[cls[u.expr]]),
        .binary => |b| absint.binary(b.op, shared.class_av[cls[b.lhs]], shared.class_av[cls[b.rhs]]),
        .select => |sel| absint.select(shared.class_av[cls[sel.cond]], shared.class_av[cls[sel.true_val]], shared.class_av[cls[sel.false_val]]),
    };
}

/// Opt-in analysis aid: with SCONE_QUERY_LOG=<prefix>, each worker process appends one line per
/// Z3 query (time, result, base, members) to <prefix>.<pid>.
var query_log: ?std.fs.File = null;
var query_log_checked = false;

fn log_query(arena: *const ExpressionArena, base: ast.ExprId, members: []const ast.ExprId, res: Z3Result, us: i64) void {
    if (!query_log_checked) {
        query_log_checked = true;
        if (std.posix.getenv("SCONE_QUERY_LOG")) |prefix| {
            var buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}.{}", .{ prefix, getpid() }) catch return;
            query_log = std.fs.cwd().createFile(path, .{ .truncate = false }) catch null;
        }
    }
    const f = query_log orelse return;
    var bw = std.io.bufferedWriter(f.writer());
    const wr = bw.writer();
    const fmt = @import("arena.zig").format_expr;
    wr.print("{}\t{s}\t{}\t", .{ us, @tagName(res), members.len }) catch return;
    fmt(base, arena, wr) catch return;
    for (members) |m| {
        wr.writeAll("\t") catch return;
        fmt(m, arena, wr) catch return;
    }
    wr.writeAll("\n") catch return;
    bw.flush() catch {};
}

fn query(shared: *Shared, w: *Z3Worker, allocator: std.mem.Allocator, base: ast.ExprId, members: []const ast.ExprId, timeout_ms: u32) Z3Result {
    exit_if_orphaned(shared);
    _ = shared.num_queries.fetchAdd(1, .monotonic);
    if (my_slot) |sl| _ = sl.queries.fetchAdd(1, .monotonic);
    const t0 = std.time.microTimestamp();
    const res = w.check(allocator, base, members, &shared.db.expr_arena, timeout_ms);
    if (query_log != null or !query_log_checked) log_query(&shared.db.expr_arena, base, members, res, std.time.microTimestamp() - t0);
    return res;
}

/// Debug aid (--audit-absint N, --audit-normalize N): Z3 re-checks a member that the abstract
/// interpreter or the normalizer claimed equal to the base.
fn audit(shared: *Shared, w: *Z3Worker, allocator: std.mem.Allocator, base: ast.ExprId, m: ast.ExprId, who: []const u8) void {
    const one = [_]ast.ExprId{m};
    const res = query(shared, w, allocator, base, &one, config.active.z3_timeout_ms * 8);
    _ = shared.num_audited.fetchAdd(1, .monotonic);
    switch (res) {
        .unsat => {},
        .timeout => _ = shared.num_audit_timeouts.fetchAdd(1, .monotonic),
        .sat => |ce| {
            _ = shared.num_audit_failures.fetchAdd(1, .monotonic);
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            @import("arena.zig").format_expr(base, &shared.db.expr_arena, fbs.writer()) catch {};
            fbs.writer().writeAll(" vs ") catch {};
            @import("arena.zig").format_expr(m, &shared.db.expr_arena, fbs.writer()) catch {};
            std.debug.print("\n[BUG] {s} claimed equal but Z3 disagrees at x={} y={} z={}: {s}\n", .{ who, ce.x, ce.y, ce.z, fbs.getWritten() });
        },
    }
}

/// Inputs where identities built from counts (popcount, clz, ctz: 0..32) or a single bit tend to
/// break: x + popcount(x) is 0 only at x = -28 and -29. Random samples almost never hit these,
/// and Z3 needs seconds to find them.
const needle_values = blk: {
    var v: [64 + 64 + 4 * 32 + 6]u32 = undefined;
    var n: usize = 0;
    for (0..64) |k| {
        v[n] = k;
        v[n + 1] = 0 -% @as(u32, k + 1);
        n += 2;
    }
    for (0..32) |k| {
        const b: u32 = @as(u32, 1) << k;
        v[n] = b;
        v[n + 1] = b -% 1;
        v[n + 2] = b +% 1;
        v[n + 3] = 0 -% b;
        n += 4;
    }
    for ([_]u32{ 0x55555555, 0xAAAAAAAA, 0x7FFFFFFF, 0x80000001, 0x33333333, 0xCCCCCCCC }) |c| {
        v[n] = c;
        n += 1;
    }
    break :blk v;
};
/// Values for the variables that are not being swept.
const needle_others = [_]u32{ 0, 1, 2, 31, 32, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF };

/// Looks for an input where some member differs from `base` by sweeping one variable over
/// `needle_values` with the other two over `needle_others` (about 40k points, milliseconds).
/// Any hit is a genuine counterexample under the reference semantics.
fn needle_search(arena: *const ExpressionArena, base: ast.ExprId, members: []const ast.ExprId) ?CE {
    for (0..3) |swept| {
        for (needle_values) |a| for (needle_others) |b| for (needle_others) |c| {
            const pt: CE = switch (swept) {
                0 => .{ .x = a, .y = b, .z = c },
                1 => .{ .x = b, .y = a, .z = c },
                else => .{ .x = b, .y = c, .z = a },
            };
            const want = eval_mod.eval_point(base, arena, pt.x, pt.y, pt.z);
            for (members) |m| {
                if (eval_mod.eval_point(m, arena, pt.x, pt.y, pt.z) != want) return pt;
            }
        };
    }
    return null;
}

fn publish_ce(shared: *Shared, ce: CE) void {
    while (shared.ce_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer shared.ce_lock.store(false, .release);

    const count = shared.num_shared_ces.load(.monotonic);
    if (count < max_shared_ces) {
        for (shared.shared_ces[0..count]) |existing| {
            if (existing.x == ce.x and existing.y == ce.y and existing.z == ce.z) return;
        }
        shared.shared_ces[count] = ce;
        shared.num_shared_ces.store(count + 1, .release);
    }
}

const Pending = struct { base: ast.ExprId, members: []ast.ExprId };

fn eject_on_ce(
    shared: *Shared,
    allocator: std.mem.Allocator,
    arena: *const ExpressionArena,
    p_base: ast.ExprId,
    members: *[]ast.ExprId,
    settled: usize,
    ce: CE,
    stack: *std.ArrayList(Pending),
    ejected: *std.ArrayList(Valued),
) !bool {
    const base_val = eval_mod.eval_point(p_base, arena, ce.x, ce.y, ce.z);
    ejected.clearRetainingCapacity();
    var kept = settled;
    for (members.*[settled..]) |m| {
        const v = eval_mod.eval_point(m, arena, ce.x, ce.y, ce.z);
        if (v == base_val) {
            members.*[kept] = m;
            kept += 1;
        } else {
            try ejected.append(.{ .value = v, .expr = m });
        }
    }

    if (ejected.items.len == 0) return false;

    members.* = members.*[0..kept];

    std.sort.block(Valued, ejected.items, {}, Valued.lessThan);
    var i: usize = 0;
    while (i < ejected.items.len) {
        var j = i + 1;
        while (j < ejected.items.len and ejected.items[j].value == ejected.items[i].value) j += 1;
        // All ejected members come from the same level, so the lowest id is as cheap as any.
        const rest = try allocator.alloc(ast.ExprId, j - i - 1);
        for (ejected.items[i + 1 .. j], rest) |e, *r| r.* = e.expr;
        try stack.append(.{ .base = ejected.items[i].expr, .members = rest });
        _ = shared.num_splits.fetchAdd(1, .monotonic);
        // The new base is settled by definition; its members are counted when proven.
        _ = shared.exprs_done.fetchAdd(1, .monotonic);
        i = j;
    }
    return true;
}

/// Proves every member of `task` equal to the class's canonical expression, or splits the class.
/// Members are checked in chunks. A counterexample is evaluated on all members still waiting,
/// and those that disagree with the base are ejected and grouped by their value there; each such
/// group is then verified against its own base. This separates every distinct function hiding
/// in the class within one pass.
fn solve_task(shared: *Shared, w: *Z3Worker, out: *WorkerOut, task: Task) !void {
    const allocator = out.arena.allocator();
    const arena = &shared.db.expr_arena;
    const timeout_ms = config.active.z3_timeout_ms;

    var stack = std.ArrayList(Pending).init(allocator);
    defer stack.deinit();
    try stack.append(.{ .base = shared.db.classes.items[task.class_id].canonical_expr, .members = try allocator.dupe(ast.ExprId, task.members) });

    var ejected = std.ArrayList(Valued).init(allocator);
    defer ejected.deinit();

    while (stack.popOrNull()) |p| {
        // members[0..settled] are proven (or given up on); members[settled..len] are still waiting.
        var members = p.members;
        var settled: usize = 0;
        var unverified = false;
        var n: usize = chunk_size;

        // Pass 1: range / known-bit analysis. Settles everything that is provably the same
        // constant as the base (the bulk of the huge "folds to 0 / 1" classes) in nanoseconds.
        if (config.active.use_absint) {
            const base_av = av_of(shared, p.base);
            if (base_av.isConst()) {
                for (members, 0..) |m, i| {
                    const mav = av_of(shared, m);
                    if (!(mav.isConst() and mav.lo == base_av.lo)) continue;
                    std.mem.swap(ast.ExprId, &members[settled], &members[i]);
                    settled += 1;
                    const every = config.active.audit_absint;
                    if (every != 0 and m % every == 0) audit(shared, w, allocator, p.base, m, "absint");
                }
            }
        }
        const by_absint = settled;
        _ = shared.num_absint.fetchAdd(by_absint, .monotonic);

        // Pass 2: algebraic normal forms (linear arithmetic, AC ops, commuting shift chains).
        // Settles most of what would otherwise be slow solver calls, in microseconds.
        if (w.norm.size() > max_normal_forms) w.norm.reset();
        const base_nf = try w.norm.normalize(p.base, arena);
        for (members[by_absint..], by_absint..) |m, i| {
            if (try w.norm.normalize(m, arena) != base_nf) continue;
            std.mem.swap(ast.ExprId, &members[settled], &members[i]);
            settled += 1;
            const every = config.active.audit_normalize;
            if (every != 0 and m % every == 0) audit(shared, w, allocator, p.base, m, "normalizer");
        }
        const by_normal_form = settled;
        _ = shared.num_normalized.fetchAdd(by_normal_form - by_absint, .monotonic);

        // Pass 3: let Z3's rewriter try the rest before paying for a solver call.
        for (members[by_normal_form..], by_normal_form..) |m, i| {
            if (w.trivially_equal(p.base, m, arena)) {
                std.mem.swap(ast.ExprId, &members[settled], &members[i]);
                settled += 1;
            }
        }
        _ = shared.num_simplified.fetchAdd(settled - by_normal_form, .monotonic);
        _ = shared.exprs_done.fetchAdd(settled, .monotonic);

        // Pass 4: evaluate all counterexamples published so far by any worker before calling Z3.
        var ce_idx: usize = 0;
        const initial_ces = shared.num_shared_ces.load(.acquire);
        while (ce_idx < initial_ces and settled < members.len) : (ce_idx += 1) {
            const ce = shared.shared_ces[ce_idx];
            if (try eject_on_ce(shared, allocator, arena, p.base, &members, settled, ce, &stack, &ejected)) {
                _ = shared.num_shared_ejections.fetchAdd(1, .monotonic);
            }
        }

        while (settled < members.len) {
            // Check if any peer worker discovered and published new counterexamples in the meantime.
            const current_ces = shared.num_shared_ces.load(.acquire);
            if (ce_idx < current_ces) {
                var separated = false;
                while (ce_idx < current_ces and settled < members.len) : (ce_idx += 1) {
                    const ce = shared.shared_ces[ce_idx];
                    if (try eject_on_ce(shared, allocator, arena, p.base, &members, settled, ce, &stack, &ejected)) {
                        _ = shared.num_shared_ejections.fetchAdd(1, .monotonic);
                        separated = true;
                    }
                }
                if (separated) continue;
            }
            if (settled >= members.len) break;

            const chunk = members[settled..@min(settled + n, members.len)];
            var res = query(shared, w, allocator, p.base, chunk, timeout_ms);
            if (res == .timeout) {
                if (needle_search(arena, p.base, chunk)) |ce| {
                    _ = shared.num_needles.fetchAdd(1, .monotonic);
                    res = .{ .sat = ce };
                }
            }
            if (res == .timeout) {
                if (chunk.len > 1) {
                    n = chunk.len / 2;
                    continue;
                }
                // One variable: all 2^32 inputs decide it, instead of retrying Z3 with longer
                // timeouts that these members mostly exhaust anyway.
                if (exhaustive.singleVar(arena, p.base, chunk[0])) |v| {
                    switch (try exhaustive.compare(allocator, arena, p.base, chunk[0])) {
                        .equal => res = .unsat,
                        .differ => |val| res = .{ .sat = .{
                            .x = if (v == .x) val else 0,
                            .y = if (v == .y) val else 0,
                            .z = if (v == .z) val else 0,
                        } },
                        .skipped => {},
                    }
                    if (res != .timeout) _ = shared.num_exhaustive.fetchAdd(1, .monotonic);
                }
            }
            if (res == .timeout) {
                for (timeout_escalation) |mult| {
                    res = query(shared, w, allocator, p.base, chunk, timeout_ms *| mult);
                    if (res != .timeout) break;
                }
            }

            switch (res) {
                .unsat => {
                    settled += chunk.len;
                    _ = shared.exprs_done.fetchAdd(chunk.len, .monotonic);
                    n = chunk_size;
                },
                .timeout => {
                    // A single member Z3 cannot decide: keep it in the group but flag the group.
                    if (my_slot) |sl| _ = sl.timeouts.fetchAdd(1, .monotonic);
                    unverified = true;
                    settled += 1;
                    _ = shared.exprs_done.fetchAdd(1, .monotonic);
                    n = chunk_size;
                },
                .sat => |ce| {
                    if (my_slot) |sl| _ = sl.ces.fetchAdd(1, .monotonic);
                    publish_ce(shared, ce);
                    try out.ces.append(ce);
                    _ = shared.num_ces.fetchAdd(1, .monotonic);

                    const did_eject = try eject_on_ce(shared, allocator, arena, p.base, &members, settled, ce, &stack, &ejected);
                    if (!did_eject) {
                        // Z3 and eval_point disagree on the semantics; never loop on it.
                        _ = shared.num_mismatches.fetchAdd(1, .monotonic);
                        unverified = true;
                        _ = shared.exprs_done.fetchAdd(members.len - settled, .monotonic);
                        settled = members.len;
                        break;
                    }
                    ce_idx = shared.num_shared_ces.load(.acquire);
                    n = chunk_size;
                },
            }
            maybe_print_progress(shared);
        }

        if (unverified) _ = shared.num_unverified.fetchAdd(1, .monotonic);
        try out.groups.append(.{ .class_id = task.class_id, .base = p.base, .members = members, .unverified = unverified });
    }
}

fn maybe_print_progress(shared: *Shared) void {
    const now = std.time.milliTimestamp();
    maybe_write_status(shared, now);
    const last = shared.last_print.load(.monotonic);
    if (now - last < 500) return;
    if (shared.last_print.cmpxchgStrong(last, now, .monotonic, .monotonic) != null) return;
    print_progress(shared, false);
}

fn print_progress(shared: *Shared, final: bool) void {
    const elapsed_s = @as(f64, @floatFromInt(std.time.milliTimestamp() - shared.start_time)) / 1000.0;
    const exprs_done = shared.exprs_done.load(.monotonic);
    const speed = if (elapsed_s > 0) @as(f64, @floatFromInt(exprs_done)) / elapsed_s else 0;
    std.debug.print("\rZ3: {}/{} tasks, {}/{} exprs | {d:.0} exprs/s | by absint: {} | by normal form: {} | by rewriting: {} | shared CEs: {} | queries: {} | CEs: {} | new classes: {} | timeouts: {} | {d:.1}s{s}", .{
        shared.done.load(.monotonic),
        shared.tasks.len,
        exprs_done,
        shared.total_exprs,
        speed,
        shared.num_absint.load(.monotonic),
        shared.num_normalized.load(.monotonic),
        shared.num_simplified.load(.monotonic),
        shared.num_shared_ejections.load(.monotonic),
        shared.num_queries.load(.monotonic),
        shared.num_ces.load(.monotonic),
        shared.num_splits.load(.monotonic),
        shared.num_unverified.load(.monotonic),
        elapsed_s,
        if (final) "\n" else "   ",
    });
}

fn maybe_write_status(shared: *Shared, now: i64) void {
    const last = shared.last_status.load(.monotonic);
    if (now - last < 1000) return;
    if (shared.last_status.cmpxchgStrong(last, now, .monotonic, .monotonic) != null) return;
    write_status(shared, now) catch {};
}

fn write_status(shared: *Shared, now: i64) !void {
    const tmp = status_path ++ ".tmp";
    {
        const file = try std.fs.cwd().createFile(tmp, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const wr = bw.writer();
        const next = @min(shared.next_task.load(.monotonic), shared.tasks.len);
        try wr.print("{{\"pid\":{},\"now_ms\":{},\"next_task\":{},\"tasks\":{},\"buckets\":[", .{ shared.parent_pid, now, next, shared.tasks.len });
        for (shared.buckets, 0..) |b, i| {
            if (i > 0) try wr.writeAll(",");
            try wr.print("{{\"min_size\":{},\"tasks\":{},\"started\":{},\"exprs\":{}}}", .{ b.min_size, b.hi - b.lo, @min(b.hi, @max(b.lo, next)) - b.lo, b.exprs });
        }
        try wr.writeAll("],\"workers\":[");
        for (shared.slots[0..shared.num_slots], 0..) |*sl, i| {
            if (i > 0) try wr.writeAll(",");
            const t = sl.task.load(.monotonic);
            if (t == 0) {
                try wr.writeAll("null");
                continue;
            }
            const task = shared.tasks[t - 1];
            try wr.print("{{\"task\":{},\"class\":{},\"members\":{},\"age_ms\":{},\"queries\":{},\"ces\":{},\"timeouts\":{},\"expr\":\"", .{
                t - 1,                                 task.class_id,             task.members.len,
                now - sl.start_ms.load(.monotonic), sl.queries.load(.monotonic), sl.ces.load(.monotonic),
                sl.timeouts.load(.monotonic),
            });
            // Expressions print as identifiers, numbers and punctuation only: nothing to escape.
            try @import("arena.zig").format_expr(shared.db.classes.items[task.class_id].canonical_expr, &shared.db.expr_arena, wr);
            try wr.writeAll("\"}");
        }
        try wr.writeAll("]}\n");
        try bw.flush();
    }
    try std.fs.cwd().rename(tmp, status_path);
}

extern "c" fn getpid() std.posix.pid_t;
extern "c" fn getppid() std.posix.pid_t;

fn exit_if_orphaned(shared: *const Shared) void {
    if (getppid() != shared.parent_pid) std.c._exit(1);
}

fn verify_worker(shared: *Shared, out: *WorkerOut) void {
    var w = Z3Worker.init(std.heap.page_allocator);
    defer w.deinit();
    while (true) {
        const idx = shared.next_task.fetchAdd(1, .monotonic);
        if (idx >= shared.tasks.len) break;
        if (my_slot) |sl| {
            sl.start_ms.store(std.time.milliTimestamp(), .monotonic);
            sl.queries.store(0, .monotonic);
            sl.ces.store(0, .monotonic);
            sl.timeouts.store(0, .monotonic);
            sl.task.store(idx + 1, .monotonic);
        }
        solve_task(shared, &w, out, shared.tasks[idx]) catch @panic("oom");
        _ = shared.done.fetchAdd(1, .monotonic);
        maybe_print_progress(shared);
    }
}

const record_group: u32 = 1;
const record_ce: u32 = 2;

/// Body of a forked worker process: verifies tasks until none are left, streams the results to
/// `fd` and exits. Z3 serializes threads on a process-wide memory-accounting mutex (hit from
/// sat::solver::checkpoint and goal2sat), so threads in one process scale poorly; separate
/// processes do not share it. The child sees the parent's expression arena copy-on-write.
fn worker_process(shared: *Shared, fd: std.posix.fd_t, slot: usize) noreturn {
    if (slot < max_slots) my_slot = &shared.slots[slot];
    var out = WorkerOut{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .groups = std.ArrayList(Group).init(std.heap.page_allocator),
        .ces = std.ArrayList(CE).init(std.heap.page_allocator),
    };
    verify_worker(shared, &out);
    if (my_slot) |sl| sl.task.store(0, .monotonic);

    const file = std.fs.File{ .handle = fd };
    var bw = std.io.bufferedWriter(file.writer());
    write_results(bw.writer(), &out) catch std.c._exit(1);
    bw.flush() catch std.c._exit(1);
    std.c._exit(0);
}

fn write_results(wr: anytype, out: *const WorkerOut) !void {
    for (out.groups.items) |g| {
        for ([_]u32{ record_group, g.class_id, g.base, @intFromBool(g.unverified), @intCast(g.members.len) }) |v| try wr.writeInt(u32, v, .little);
        for (g.members) |m| try wr.writeInt(u32, m, .little);
    }
    for (out.ces.items) |ce| {
        for ([_]u32{ record_ce, ce.x, ce.y, ce.z }) |v| try wr.writeInt(u32, v, .little);
    }
}

fn read_results(bytes: []const u8, out: *WorkerOut) !void {
    const allocator = out.arena.allocator();
    var i: usize = 0;
    const next = struct {
        fn f(b: []const u8, pos: *usize) !u32 {
            if (pos.* + 4 > b.len) return error.TruncatedWorkerOutput;
            defer pos.* += 4;
            return std.mem.readInt(u32, b[pos.*..][0..4], .little);
        }
    }.f;
    while (i < bytes.len) {
        switch (try next(bytes, &i)) {
            record_group => {
                const class_id = try next(bytes, &i);
                const base = try next(bytes, &i);
                const unverified = try next(bytes, &i) != 0;
                const members = try allocator.alloc(ast.ExprId, try next(bytes, &i));
                for (members) |*m| m.* = try next(bytes, &i);
                try out.groups.append(.{ .class_id = class_id, .base = base, .members = members, .unverified = unverified });
            },
            record_ce => try out.ces.append(.{ .x = try next(bytes, &i), .y = try next(bytes, &i), .z = try next(bytes, &i) }),
            else => return error.CorruptWorkerOutput,
        }
    }
}

fn drain_pipe(fd: std.posix.fd_t, dst: *[]u8) void {
    const file = std.fs.File{ .handle = fd };
    defer file.close();
    dst.* = file.readToEndAlloc(std.heap.page_allocator, std.math.maxInt(usize)) catch &.{};
}

pub const LevelResult = struct {
    /// Distinct counterexamples found while verifying this level.
    ces: []CE,
    /// Canonical expressions of the classes split off during this level.
    new_canonicals: []ast.ExprId,
    classes_checked: usize,
    exprs_checked: usize,
    unverified_classes: usize,
};

/// Verifies the expressions added since `first_new_expr` (one cost level) against the canonical
/// expression of the class they were hashed into, splitting classes on counterexamples. Lower
/// levels are already exact, so nothing else needs to be checked again. On return, `db` holds
/// the split classes with placeholder hashes and no vectors; the caller must extend the sample
/// grid with `ces` and rebuild the class vectors before enumerating the next level.
pub fn verify_level(allocator: std.mem.Allocator, db: *database.ExpressionDatabase, first_new_expr: usize, num_threads: usize) !LevelResult {
    const gpa = std.heap.page_allocator;
    const num_classes = db.classes.items.len;
    const num_exprs = db.expr_arena.len;

    // Group this level's non-canonical expressions by class (counting sort).
    const offsets = try gpa.alloc(u32, num_classes + 1);
    defer gpa.free(offsets);
    @memset(offsets, 0);
    for (first_new_expr..num_exprs) |e| {
        const cid = db.expr_to_class.items[e];
        if (db.classes.items[cid].canonical_expr != e) offsets[cid + 1] += 1;
    }
    for (1..num_classes + 1) |i| offsets[i] += offsets[i - 1];
    const members = try gpa.alloc(ast.ExprId, offsets[num_classes]);
    defer gpa.free(members);
    const fill = try gpa.dupe(u32, offsets[0..num_classes]);
    defer gpa.free(fill);
    for (first_new_expr..num_exprs) |e| {
        const cid = db.expr_to_class.items[e];
        if (db.classes.items[cid].canonical_expr == e) continue;
        members[fill[cid]] = @intCast(e);
        fill[cid] += 1;
    }

    const max_task_size = 1024;
    var tasks = std.ArrayList(Task).init(gpa);
    defer tasks.deinit();
    for (0..num_classes) |cid| {
        const lo = offsets[cid];
        const hi = offsets[cid + 1];
        if (hi > lo) {
            var start = lo;
            while (start < hi) {
                const end = @min(start + max_task_size, hi);
                try tasks.append(.{ .class_id = @intCast(cid), .members = members[start..end] });
                start = end;
            }
        }
    }
    // Largest classes first so that one slow class does not finish last on a single thread.
    std.sort.block(Task, tasks.items, {}, struct {
        fn f(_: void, a: Task, b: Task) bool {
            return a.members.len > b.members.len;
        }
    }.f);

    std.debug.print("Z3: verifying {} new expressions across {} tasks in {} classes using {} worker processes...\n", .{ members.len, tasks.items.len, num_classes, num_threads });

    // Lives in shared memory so the worker processes can claim tasks and report progress.
    const shared_mem = try std.posix.mmap(null, @sizeOf(Shared), std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(shared_mem);
    const shared: *Shared = @ptrCast(@alignCast(shared_mem.ptr));
    // Class summaries for the abstract interpreter. Children always sit in classes with smaller
    // ids (lower cost level), so one ascending pass is enough.
    const class_av = try gpa.alloc(absint.AV, num_classes);
    defer gpa.free(class_av);
    @memset(class_av, absint.AV.top);
    shared.* = .{ .db = db, .tasks = tasks.items, .class_av = class_av, .total_exprs = members.len, .start_time = std.time.milliTimestamp(), .parent_pid = getpid() };
    for (db.classes.items, 0..) |cls, cid| {
        if (cls.canonical_expr < first_new_expr) class_av[cid] = av_of(shared, cls.canonical_expr);
    }
    const outs = try gpa.alloc(WorkerOut, num_threads);
    defer gpa.free(outs);
    for (outs) |*o| {
        o.arena = std.heap.ArenaAllocator.init(gpa);
        o.groups = std.ArrayList(Group).init(gpa);
        o.ces = std.ArrayList(CE).init(gpa);
    }
    defer for (outs) |*o| {
        o.groups.deinit();
        o.ces.deinit();
        o.arena.deinit();
    };

    const pids = try gpa.alloc(std.posix.pid_t, num_threads);
    defer gpa.free(pids);
    const readers = try gpa.alloc(std.Thread, num_threads);
    defer gpa.free(readers);
    const outputs = try gpa.alloc([]u8, num_threads);
    defer {
        for (outputs) |o| if (o.len > 0) gpa.free(o);
        gpa.free(outputs);
    }
    shared.num_slots = @min(num_threads, max_slots);
    {
        var lo: usize = 0;
        for (&shared.buckets, bucket_sizes) |*b, min_size| {
            var hi = lo;
            var exprs: usize = 0;
            while (hi < tasks.items.len and tasks.items[hi].members.len >= min_size) : (hi += 1) exprs += tasks.items[hi].members.len;
            b.* = .{ .min_size = min_size, .lo = lo, .hi = hi, .exprs = exprs };
            lo = hi;
        }
    }
    defer std.fs.cwd().deleteFile(status_path) catch {};
    for (pids, readers, outputs, 0..) |*pid, *reader, *output, slot| {
        const fds = try std.posix.pipe();
        pid.* = try std.posix.fork();
        if (pid.* == 0) {
            std.posix.close(fds[0]);
            worker_process(shared, fds[1], slot);
        }
        std.posix.close(fds[1]);
        // Drain concurrently: a child blocks on a full pipe until its output is read.
        reader.* = try std.Thread.spawn(.{}, drain_pipe, .{ fds[0], output });
    }
    var failed = false;
    for (pids, readers, outputs) |pid, reader, _| {
        reader.join();
        const status = std.posix.waitpid(pid, 0).status;
        if (!std.posix.W.IFEXITED(status) or std.posix.W.EXITSTATUS(status) != 0) failed = true;
    }
    print_progress(shared, true);
    if (failed) return error.VerifyWorkerFailed;
    for (outputs, outs) |output, *o| try read_results(output, o);

    if (shared.num_audited.load(.monotonic) > 0) {
        std.debug.print("Audit: {} proofs re-checked by Z3, {} failures, {} undecided\n", .{ shared.num_audited.load(.monotonic), shared.num_audit_failures.load(.monotonic), shared.num_audit_timeouts.load(.monotonic) });
    }
    if (shared.num_mismatches.load(.monotonic) > 0) {
        std.debug.print("[WARNING] {} counterexamples did not reproduce under eval_point (Z3/eval semantics differ).\n", .{shared.num_mismatches.load(.monotonic)});
    }

    // Collect all counterexamples found by any worker or published to shared memory.
    var unique = std.AutoArrayHashMap(CE, void).init(gpa);
    defer unique.deinit();
    for (outs) |*o| for (o.ces.items) |ce| try unique.put(ce, {});
    const shared_count = @min(shared.num_shared_ces.load(.monotonic), max_shared_ces);
    for (shared.shared_ces[0..shared_count]) |ce| try unique.put(ce, {});

    // Apply the splits. A class too big for one task is verified as several tasks, and each task
    // splits independently, so the same function can be split off more than once with different
    // base expressions. Split groups of one class that agree on every counterexample of this
    // level are therefore checked against each other with Z3 and merged when equal.
    var new_canonicals = std.ArrayList(ast.ExprId).init(allocator);
    var unverified: usize = 0;
    const SigKey = struct { class_id: database.ClassId, sig: u64 };
    // (original class, signature) -> new classes with that signature (almost always one).
    var by_sig = std.AutoHashMap(SigKey, std.ArrayListUnmanaged(database.ClassId)).init(gpa);
    defer {
        var it = by_sig.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        by_sig.deinit();
    }
    var extra_ces = std.ArrayList(CE).init(gpa);
    defer extra_ces.deinit();
    var z3w: ?Z3Worker = null;
    defer if (z3w) |*w| w.deinit();
    var num_merged: usize = 0;
    var merge_checks: usize = 0;
    const level_ces = unique.keys();
    for (outs) |*o| {
        for (o.groups.items) |g| {
            if (g.unverified) unverified += 1;
            if (g.base == db.classes.items[g.class_id].canonical_expr) {
                if (g.unverified) db.classes.items[g.class_id].unverified = true;
                continue;
            }

            var hasher = std.hash.Wyhash.init(0);
            for (level_ces) |ce| hasher.update(std.mem.asBytes(&eval_mod.eval_point(g.base, &db.expr_arena, ce.x, ce.y, ce.z)));
            const gop = try by_sig.getOrPut(.{ .class_id = g.class_id, .sig = hasher.final() });
            if (!gop.found_existing) gop.value_ptr.* = .{};

            var merged_cid: ?database.ClassId = null;
            for (gop.value_ptr.items) |cid| {
                const other = db.classes.items[cid].canonical_expr;
                if (other == g.base) {
                    merged_cid = cid;
                    break;
                }
                if (z3w == null) z3w = Z3Worker.init(gpa);
                merge_checks += 1;
                const one = [_]ast.ExprId{g.base};
                switch (z3w.?.check(allocator, other, &one, &db.expr_arena, config.active.z3_timeout_ms *| 4)) {
                    .unsat => {
                        merged_cid = cid;
                        break;
                    },
                    .sat => |ce| try extra_ces.append(ce),
                    .timeout => {}, // undecided: keeping them apart is always sound
                }
            }

            if (merged_cid) |cid| {
                num_merged += 1;
                db.expr_to_class.items[g.base] = cid;
                for (g.members) |m| db.expr_to_class.items[m] = cid;
                if (g.unverified) db.classes.items[cid].unverified = true;
                continue;
            }

            const new_id: database.ClassId = @intCast(db.classes.items.len);
            try db.classes.append(.{ .hash = 0, .canonical_expr = g.base, .unverified = g.unverified });
            db.expr_to_class.items[g.base] = new_id;
            for (g.members) |m| db.expr_to_class.items[m] = new_id;
            try new_canonicals.append(g.base);
            try gop.value_ptr.append(gpa, new_id);
        }
    }
    for (extra_ces.items) |ce| try unique.put(ce, {});
    if (shared.num_needles.load(.monotonic) > 0) {
        std.debug.print("Needle search settled {} Z3 timeouts with a counterexample.\n", .{shared.num_needles.load(.monotonic)});
    }
    if (shared.num_exhaustive.load(.monotonic) > 0) {
        std.debug.print("Exhaustive evaluation decided {} single-variable members Z3 timed out on.\n", .{shared.num_exhaustive.load(.monotonic)});
    }
    if (merge_checks > 0) {
        std.debug.print("Merged {} duplicate split classes ({} Z3 checks).\n", .{ num_merged, merge_checks });
    }

    return .{
        .ces = try allocator.dupe(CE, unique.keys()),
        .new_canonicals = try new_canonicals.toOwnedSlice(),
        .classes_checked = num_classes,
        .exprs_checked = members.len,
        .unverified_classes = unverified,
    };
}
