const std = @import("std");
const ast = @import("ast.zig");
const expr_arena = @import("arena.zig");

const config = @import("config.zig");

pub const BATCH_SIZE = 64;
pub const Vector64 = @Vector(BATCH_SIZE, u32);

pub const EvaluationContext = struct {
    x_batches: []Vector64,
    y_batches: []Vector64,
    z_batches: []Vector64,
    num_batches: usize,
    total_samples: usize,
    allocator: std.mem.Allocator,

    fn setSample(ctx: *EvaluationContext, idx: usize, x: u32, y: u32, z: u32) void {
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

    pub fn init(allocator: std.mem.Allocator) !EvaluationContext {
        // Calculate dynamic capacity based on file size + padding
        var ce_count: usize = 0;
        if (std.fs.cwd().openFile(config.counterexamples_file, .{})) |f| {
            var buf_reader = std.io.bufferedReader(f.reader());
            var stream = buf_reader.reader();
            var buf: [1024]u8 = undefined;
            while (stream.readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
                if (line.len > 0) ce_count += 1;
            }
            f.close();
        } else |_| {}
        
        const total_samples = config.edge_grid_samples + ce_count + config.num_random_samples;
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
        if (config.use_cartesian_grid) {
            for (config.base_edge_cases) |x| {
                for (config.base_edge_cases) |y| {
                    for (config.base_edge_cases) |z| {
                        ctx.setSample(idx, x, y, z);
                        idx += 1;
                    }
                }
            }
        }

        // 2) On top of that (not instead of it), fill the newly added
        //    capacity with random triples. This is purely additive: it
        //    catches expressions that agree everywhere on the structured
        //    edge grid but diverge on generic inputs, without weakening any
        //    of the existing boundary coverage.
        // Read counterexamples from CEGIS loop
        const ce_file = std.fs.cwd().openFile(config.counterexamples_file, .{}) catch null;
        ce_count = 0;
        if (ce_file) |f| {
            defer f.close();
            var buf_reader = std.io.bufferedReader(f.reader());
            var stream = buf_reader.reader();
            var buf: [1024]u8 = undefined;
            while (stream.readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
                if (line.len == 0) continue;
                var it = std.mem.split(u8, line, ",");
                const x_str = it.next() orelse continue;
                const y_str = it.next() orelse continue;
                const z_str = it.next() orelse continue;
                const x_val = std.fmt.parseInt(i64, std.mem.trim(u8, x_str, " \t"), 10) catch continue;
                const y_val = std.fmt.parseInt(i64, std.mem.trim(u8, y_str, " \t"), 10) catch continue;
                const z_val = std.fmt.parseInt(i64, std.mem.trim(u8, z_str, " \t"), 10) catch continue;
                const ux = @as(u32, @bitCast(@as(i32, @truncate(x_val))));
                const uy = @as(u32, @bitCast(@as(i32, @truncate(y_val))));
                const uz = @as(u32, @bitCast(@as(i32, @truncate(z_val))));
                ctx.setSample(idx, ux, uy, uz);
                ce_count += 1;
                idx += 1;
                if (idx >= total_samples) break;
            }
        }
        
        if (ce_count > 0) {
            std.debug.print("Loaded {} counterexamples from Z3.\n", .{ce_count});
        }
        var prng = std.Random.DefaultPrng.init(0xC0FFEE_C0FFEE);
        const rand = prng.random();
        while (idx < total_samples) : (idx += 1) {
            ctx.setSample(idx, rand.int(u32), rand.int(u32), rand.int(u32));
        }

        return ctx;
    }
};

pub const FingerprintHash = u64;

pub const EquivalenceClass = struct {
    hash: FingerprintHash,
    canonical_expr: ast.ExprId,
};


pub const ClassId = u32;

pub const SmallClassList = union(enum) {
    inline_val: ClassId,
    dynamic: std.ArrayList(ClassId),

    pub fn init(first_val: ClassId) SmallClassList {
        return .{ .inline_val = first_val };
    }

    pub fn append(self: *SmallClassList, allocator: std.mem.Allocator, val: ClassId) !void {
        switch (self.*) {
            .inline_val => |existing_val| {
                var list = try std.ArrayList(ClassId).initCapacity(allocator, 4);
                list.appendAssumeCapacity(existing_val);
                list.appendAssumeCapacity(val);
                self.* = .{ .dynamic = list };
            },
            .dynamic => |*list| {
                try list.append(val);
            },
        }
    }

    pub fn slice(self: *const SmallClassList) []const ClassId {
        switch (self.*) {
            .inline_val => |*val| return @as(*const [1]ClassId, @ptrCast(val))[0..],
            .dynamic => |*list| return list.items,
        }
    }

    pub fn deinit(self: *SmallClassList) void {
        if (self.* == .dynamic) {
            self.dynamic.deinit();
        }
    }
};

pub const ExpressionDatabase = struct {
    allocator: std.mem.Allocator,
    
    expr_arena: expr_arena.ExpressionArena,
    expr_to_class: std.ArrayList(ClassId),
    classes: std.ArrayList(EquivalenceClass),
    fp_to_class: std.AutoHashMap(FingerprintHash, SmallClassList),

    pub fn init(allocator: std.mem.Allocator) !ExpressionDatabase {
        return .{
            .allocator = allocator,
            .expr_arena = try expr_arena.ExpressionArena.init(allocator),
            .expr_to_class = std.ArrayList(ClassId).init(allocator),
            .classes = std.ArrayList(EquivalenceClass).init(allocator),
            .fp_to_class = std.AutoHashMap(FingerprintHash, SmallClassList).init(allocator),
        };
    }

    pub fn deinit(self: *ExpressionDatabase) void {
        var it = self.fp_to_class.valueIterator();
        while (it.next()) |list| {
            list.deinit();
        }
        self.fp_to_class.deinit();
        self.classes.deinit();
        self.expr_to_class.deinit();
        self.expr_arena.deinit();
    }



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

    pub fn eval_and_hash(ctx: *const EvaluationContext, expr: ast.Expr, expr_arena_ref: *const expr_arena.ExpressionArena) FingerprintHash {
        var hasher = std.hash.Wyhash.init(0);
        for (0..ctx.num_batches) |batch_idx| {
            const batch_res = eval_batch(ctx, expr, expr_arena_ref, batch_idx);
            const bytes = std.mem.asBytes(&batch_res);
            hasher.update(bytes);
        }
        return hasher.final();
    }
};



