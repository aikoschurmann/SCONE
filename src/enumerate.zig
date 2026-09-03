const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const config = @import("config.zig");

fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buffer: [capacity]T = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn push(self: *Self, item: T) bool {
            const current_tail = self.tail.load(.monotonic);
            const next_tail = (current_tail + 1) % capacity;
            if (next_tail == self.head.load(.acquire)) {
                return false; // full
            }
            self.buffer[current_tail] = item;
            self.tail.store(next_tail, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const current_head = self.head.load(.monotonic);
            if (current_head == self.tail.load(.acquire)) {
                return null; // empty
            }
            const item = self.buffer[current_head];
            self.head.store((current_head + 1) % capacity, .release);
            return item;
        }
    };
}

const Result = struct {
    expr: ast.Expr,
    hash: eval.FingerprintHash,
};

const JobType = enum { unop, binop, select };
const Job = struct {
    job_type: JobType,
    op: u8,
    c1: usize,
    c2: usize,
    c3: usize,
    lhs_start: usize,
    lhs_end: usize,
};
const QSize = 8192;
const Queue = RingBuffer(Result, QSize);

pub const Enumerator = struct {
    db: *eval.ExpressionDatabase,
    ctx: *const eval.EvaluationContext,
    exprs_by_cost: std.ArrayList(std.ArrayList(ast.ExprId)),
    allocator: std.mem.Allocator,
    total_evaluations: std.atomic.Value(usize),

    jobs: std.ArrayList(Job),
    job_counter: std.atomic.Value(usize),
    queues: []Queue,
    workers_done: []std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, db: *eval.ExpressionDatabase, ctx: *const eval.EvaluationContext) !Enumerator {
        return .{
            .db = db,
            .ctx = ctx,
            .exprs_by_cost = std.ArrayList(std.ArrayList(ast.ExprId)).init(allocator),
            .allocator = allocator,
            .total_evaluations = std.atomic.Value(usize).init(0),
            .jobs = std.ArrayList(Job).init(allocator),
            .job_counter = std.atomic.Value(usize).init(0),
            .queues = &[_]Queue{},
            .workers_done = &[_]std.atomic.Value(bool){},
        };
    }

    pub fn deinit(self: *Enumerator) void {
        for (self.exprs_by_cost.items) |list| {
            list.deinit();
        }
        self.exprs_by_cost.deinit();
        self.jobs.deinit();
        self.allocator.free(self.queues);
        self.allocator.free(self.workers_done);
    }

    pub fn setup_threads(self: *Enumerator, num_threads: usize) !void {
        self.queues = try self.allocator.alloc(Queue, num_threads);
        for (0..num_threads) |i| {
            self.queues[i] = Queue{};
        }
        self.workers_done = try self.allocator.alloc(std.atomic.Value(bool), num_threads);
        for (0..num_threads) |i| {
            self.workers_done[i] = std.atomic.Value(bool).init(false);
        }
    }

    fn register_expr(self: *Enumerator, cost_list: *std.ArrayList(ast.ExprId), expr: ast.Expr, hash: eval.FingerprintHash) !void {
        const gop = try self.db.fp_to_class.getOrPut(hash);
        const expr_id = try self.db.expr_arena.add(expr);
        if (!gop.found_existing) {
            const class_id = @as(eval.ClassId, @intCast(self.db.classes.items.len));

            try self.db.classes.append(.{
                .hash = hash,
                .canonical_expr = expr_id,
            });
            try self.db.expr_to_class.append(class_id);
            gop.value_ptr.* = eval.SmallClassList.init(class_id);
            try cost_list.append(expr_id);
        } else {
            try self.db.expr_to_class.append(gop.value_ptr.*.inline_val);
        }
    }

    pub fn seed_cost_0(self: *Enumerator) !void {
        var cost0 = std.ArrayList(ast.ExprId).init(self.allocator);

        for (0..3) |i| {
            const v = @as(ast.Var, @enumFromInt(i));
            const expr = ast.Expr{ .variable = v };
            const fp = eval.ExpressionDatabase.eval_and_hash(self.ctx, expr, &self.db.expr_arena);
            try self.register_expr(&cost0, expr, fp);
        }

        const constants = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xFFFF };
        for (constants) |c| {
            const expr = ast.Expr{ .constant = c };
            const fp = eval.ExpressionDatabase.eval_and_hash(self.ctx, expr, &self.db.expr_arena);
            try self.register_expr(&cost0, expr, fp);
        }

        try self.exprs_by_cost.append(cost0);
    }

    pub fn isCommutative(op: ast.BinOp) bool {
        return op == .add or op == .mul or op == .and_op or op == .or_op or op == .xor or op == .eq;
    }

    pub fn prepare_jobs_for_cost(self: *Enumerator, k: usize) !void {
        self.jobs.clearRetainingCapacity();
        self.job_counter.store(0, .release);

        const chunk_size = 512;

        if (false and k >= 1) {
            const c1 = k - 1;
            if (c1 < self.exprs_by_cost.items.len) {
                const len = self.exprs_by_cost.items[c1].items.len;
                var i: usize = 0;
                while (i < len) : (i += chunk_size) {
                    const end = @min(i + chunk_size, len);
                    inline for (@typeInfo(ast.UnOp).Enum.fields) |field| {
                        try self.jobs.append(.{
                            .job_type = .unop,
                            .op = field.value,
                            .c1 = c1,
                            .c2 = 0,
                            .c3 = 0,
                            .lhs_start = i,
                            .lhs_end = end,
                        });
                    }
                }
            }
        }

        if (k >= 1) {
            const target = k - 1;
            for (0..target + 1) |c1| {
                const c2 = target - c1;
                if (c1 >= self.exprs_by_cost.items.len or c2 >= self.exprs_by_cost.items.len) continue;

                const len = self.exprs_by_cost.items[c1].items.len;
                var i: usize = 0;
                while (i < len) : (i += chunk_size) {
                    const end = @min(i + chunk_size, len);
                    inline for (@typeInfo(ast.BinOp).Enum.fields) |field| {
                        const op = @as(ast.BinOp, @enumFromInt(field.value));
                        if (!(isCommutative(op) and c1 > c2)) {
                            try self.jobs.append(.{
                                .job_type = .binop,
                                .op = field.value,
                                .c1 = c1,
                                .c2 = c2,
                                .c3 = 0,
                                .lhs_start = i,
                                .lhs_end = end,
                            });
                        }
                    }
                }
            }
        }

        if (false and k >= 1) {
            const target = k - 1;
            for (0..target + 1) |c1| {
                for (0..target - c1 + 1) |c2| {
                    const c3 = target - c1 - c2;
                    if (c1 >= self.exprs_by_cost.items.len or c2 >= self.exprs_by_cost.items.len or c3 >= self.exprs_by_cost.items.len) continue;

                    const len = self.exprs_by_cost.items[c1].items.len;
                    var i: usize = 0;
                    while (i < len) : (i += chunk_size) {
                        const end = @min(i + chunk_size, len);
                        try self.jobs.append(.{
                            .job_type = .select,
                            .op = 0,
                            .c1 = c1,
                            .c2 = c2,
                            .c3 = c3,
                            .lhs_start = i,
                            .lhs_end = end,
                        });
                    }
                }
            }
        }
    }

    pub fn worker_loop(self: *Enumerator, worker_id: usize) void {
        const queue = &self.queues[worker_id];
        const status = &self.workers_done[worker_id];
        status.store(false, .release);

        while (true) {
            const job_idx = self.job_counter.fetchAdd(1, .monotonic);
            if (job_idx >= self.jobs.items.len) {
                break;
            }

            const job = self.jobs.items[job_idx];
            switch (job.job_type) {
                .unop => {
                    const op = @as(ast.UnOp, @enumFromInt(job.op));
                    const list = self.exprs_by_cost.items[job.c1].items;
                    for (job.lhs_start..job.lhs_end) |i| {
                        const e1 = list[i];
                        const expr = ast.Expr{ .unary = .{ .op = op, .expr = e1 } };
                        const fp = eval.ExpressionDatabase.eval_and_hash(self.ctx, expr, &self.db.expr_arena);
                        while (!queue.push(.{ .expr = expr, .hash = fp })) {
                            std.atomic.spinLoopHint();
                        }
                    }
                },
                .binop => {
                    const op = @as(ast.BinOp, @enumFromInt(job.op));
                    const lhs_list = self.exprs_by_cost.items[job.c1].items;
                    const rhs_list = self.exprs_by_cost.items[job.c2].items;
                    const is_comm = isCommutative(op);
                    const same_cost = job.c1 == job.c2;

                    for (job.lhs_start..job.lhs_end) |i| {
                        const e1 = lhs_list[i];
                        for (rhs_list) |e2| {
                            if (is_comm and same_cost and e1 > e2) continue;

                            const expr = ast.Expr{ .binary = .{ .op = op, .lhs = e1, .rhs = e2 } };
                            const fp = eval.ExpressionDatabase.eval_and_hash(self.ctx, expr, &self.db.expr_arena);
                            while (!queue.push(.{ .expr = expr, .hash = fp })) {
                                std.atomic.spinLoopHint();
                            }
                        }
                    }
                },
                .select => {
                    const cond_list = self.exprs_by_cost.items[job.c1].items;
                    const t_list = self.exprs_by_cost.items[job.c2].items;
                    const f_list = self.exprs_by_cost.items[job.c3].items;

                    for (job.lhs_start..job.lhs_end) |i| {
                        const cond = cond_list[i];
                        for (t_list) |t| {
                            for (f_list) |f| {
                                const expr = ast.Expr{ .select = .{ .cond = cond, .true_val = t, .false_val = f } };
                                const fp = eval.ExpressionDatabase.eval_and_hash(self.ctx, expr, &self.db.expr_arena);
                                while (!queue.push(.{ .expr = expr, .hash = fp })) {
                                    std.atomic.spinLoopHint();
                                }
                            }
                        }
                    }
                },
            }
        }
        status.store(true, .release);
    }

    pub fn orchestrate_cost(self: *Enumerator, k: usize, num_threads: usize) !void {
        try self.prepare_jobs_for_cost(k);
        var cost_list = std.ArrayList(ast.ExprId).init(self.allocator);
        self.job_counter.store(0, .release);

        var threads = try self.allocator.alloc(std.Thread, num_threads);
        defer self.allocator.free(threads);

        for (0..num_threads) |w| {
            threads[w] = try std.Thread.spawn(.{}, worker_loop, .{ self, w });
        }

        var active_workers = num_threads;
        var workers_finished = try self.allocator.alloc(bool, num_threads);
        defer self.allocator.free(workers_finished);
        @memset(workers_finished, false);
        for (0..num_threads) |w| {
            self.workers_done[w].store(false, .release);
        }

        var exprs_processed: usize = 0;
        const start_time = std.time.milliTimestamp();
        var last_print_time = start_time;

        while (active_workers > 0) {
            for (0..num_threads) |w| {
                if (workers_finished[w]) continue;

                while (self.queues[w].pop()) |res| {
                    try self.register_expr(&cost_list, res.expr, res.hash);
                    exprs_processed += 1;
                }

                if (self.workers_done[w].load(.acquire)) {
                    while (self.queues[w].pop()) |res| {
                        try self.register_expr(&cost_list, res.expr, res.hash);
                        exprs_processed += 1;
                    }
                    workers_finished[w] = true;
                    active_workers -= 1;
                }
            }
            
            const now = std.time.milliTimestamp();
            if (now - last_print_time > 500) {
                const elapsed_s = @as(f64, @floatFromInt(now - start_time)) / 1000.0;
                const speed = if (elapsed_s > 0) @as(f64, @floatFromInt(exprs_processed)) / elapsed_s else 0.0;
                std.debug.print("\rCost {d}: Processed {d} exprs ({d} unique) | {d:.1} expr/s | elapsed: {d:.1}s...   ", .{k, exprs_processed, self.db.classes.items.len, speed, elapsed_s});
                last_print_time = now;
            }
            
            std.atomic.spinLoopHint();
        }
        const final_now = std.time.milliTimestamp();
        const total_elapsed_s = @as(f64, @floatFromInt(final_now - start_time)) / 1000.0;
        const final_speed = if (total_elapsed_s > 0) @as(f64, @floatFromInt(exprs_processed)) / total_elapsed_s else 0.0;
        std.debug.print("\rCost {d}: Processed {d} exprs ({d} unique) | {d:.1} expr/s | elapsed: {d:.1}s - DONE.   \n", .{k, exprs_processed, self.db.classes.items.len, final_speed, total_elapsed_s});

        for (0..num_threads) |w| {
            threads[w].join();
        }

        try self.exprs_by_cost.append(cost_list);
    }
};
