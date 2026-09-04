const std = @import("std");
const ast = @import("ast.zig");
const eval_mod = @import("eval.zig");
const database = @import("database.zig");
const telemetry = @import("telemetry.zig");
const config = @import("config.zig");
const builtin = @import("builtin");

pub const z3 = @cImport({
    @cInclude("z3.h");
});

pub const CE = struct {
    x: i32,
    y: i32,
    z: i32,
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

fn hash_expr_recursive(expr_id: ast.ExprId, arena: *const @import("arena.zig").ExpressionArena, hasher: *std.hash.Wyhash) void {
    const expr = arena.get(expr_id);
    const tag = @intFromEnum(expr);
    hasher.update(std.mem.asBytes(&tag));
    switch (expr) {
        .variable => |v| {
            const v_tag = @intFromEnum(v);
            hasher.update(std.mem.asBytes(&v_tag));
        },
        .constant => |c| {
            hasher.update(std.mem.asBytes(&c));
        },
        .unary => |u| {
            const op_tag = @intFromEnum(u.op);
            hasher.update(std.mem.asBytes(&op_tag));
            hash_expr_recursive(u.expr, arena, hasher);
        },
        .binary => |b| {
            const op_tag = @intFromEnum(b.op);
            hasher.update(std.mem.asBytes(&op_tag));
            hash_expr_recursive(b.lhs, arena, hasher);
            hash_expr_recursive(b.rhs, arena, hasher);
        },
        .select => |s| {
            hash_expr_recursive(s.cond, arena, hasher);
            hash_expr_recursive(s.true_val, arena, hasher);
            hash_expr_recursive(s.false_val, arena, hasher);
        }
    }
}

fn struct_hash(expr_id: ast.ExprId, arena: *const @import("arena.zig").ExpressionArena) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hash_expr_recursive(expr_id, arena, &hasher);
    return hasher.final();
}

fn get_cache_key(a: ast.ExprId, b: ast.ExprId, arena: *const @import("arena.zig").ExpressionArena) u64 {
    const ha = struct_hash(a, arena);
    const hb = struct_hash(b, arena);
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&ha));
    h.update(std.mem.asBytes(&hb));
    return h.final();
}

pub fn to_z3(ctx: z3.Z3_context, expr_id: ast.ExprId, arena: *const @import("arena.zig").ExpressionArena, x: z3.Z3_ast, y: z3.Z3_ast, z: z3.Z3_ast) z3.Z3_ast {
    const expr = arena.get(expr_id);
    switch (expr) {
        .variable => |v| {
            return switch (v) {
                .x => x,
                .y => y,
                .z => z,
            };
        },
        .constant => |c| {
            const sort = z3.Z3_mk_bv_sort(ctx, 32);
            return z3.Z3_mk_unsigned_int64(ctx, @as(u64, c), sort);
        },
        .unary => |u| {
            const child = to_z3(ctx, u.expr, arena, x, y, z);
            switch (u.op) {
                .neg => return z3.Z3_mk_bvneg(ctx, child),
                .not => return z3.Z3_mk_bvnot(ctx, child),
                .clz => return mk_clz(ctx, child),
                .ctz => return mk_ctz(ctx, child),
                .popcount => return mk_popcount(ctx, child),
            }
        },
        .binary => |b| {
            const l = to_z3(ctx, b.lhs, arena, x, y, z);
            const r = to_z3(ctx, b.rhs, arena, x, y, z);
            
            const sort = z3.Z3_mk_bv_sort(ctx, 32);
            const mask31 = z3.Z3_mk_unsigned_int64(ctx, 31, sort);
            const r_masked = z3.Z3_mk_bvand(ctx, r, mask31);

            switch (b.op) {
                .add => return z3.Z3_mk_bvadd(ctx, l, r),
                .sub => return z3.Z3_mk_bvsub(ctx, l, r),
                .mul => return z3.Z3_mk_bvmul(ctx, l, r),
                .and_op => return z3.Z3_mk_bvand(ctx, l, r),
                .or_op => return z3.Z3_mk_bvor(ctx, l, r),
                .xor => return z3.Z3_mk_bvxor(ctx, l, r),
                .shl => return z3.Z3_mk_bvshl(ctx, l, r_masked),
                .lshr => return z3.Z3_mk_bvlshr(ctx, l, r_masked),
                .ashr => return z3.Z3_mk_bvashr(ctx, l, r_masked),
                
                .ult => {
                    const cmp = z3.Z3_mk_bvult(ctx, l, r);
                    const one = z3.Z3_mk_unsigned_int64(ctx, 1, sort);
                    const zero = z3.Z3_mk_unsigned_int64(ctx, 0, sort);
                    return z3.Z3_mk_ite(ctx, cmp, one, zero);
                },
                .ule => {
                    const cmp = z3.Z3_mk_bvule(ctx, l, r);
                    const one = z3.Z3_mk_unsigned_int64(ctx, 1, sort);
                    const zero = z3.Z3_mk_unsigned_int64(ctx, 0, sort);
                    return z3.Z3_mk_ite(ctx, cmp, one, zero);
                },
                .slt => {
                    const cmp = z3.Z3_mk_bvslt(ctx, l, r);
                    const one = z3.Z3_mk_unsigned_int64(ctx, 1, sort);
                    const zero = z3.Z3_mk_unsigned_int64(ctx, 0, sort);
                    return z3.Z3_mk_ite(ctx, cmp, one, zero);
                },
                .sle => {
                    const cmp = z3.Z3_mk_bvsle(ctx, l, r);
                    const one = z3.Z3_mk_unsigned_int64(ctx, 1, sort);
                    const zero = z3.Z3_mk_unsigned_int64(ctx, 0, sort);
                    return z3.Z3_mk_ite(ctx, cmp, one, zero);
                },
                .eq => {
                    const cmp = z3.Z3_mk_eq(ctx, l, r);
                    const one = z3.Z3_mk_unsigned_int64(ctx, 1, sort);
                    const zero = z3.Z3_mk_unsigned_int64(ctx, 0, sort);
                    return z3.Z3_mk_ite(ctx, cmp, one, zero);
                },
            }
        },
        .select => |s| {
            const c = to_z3(ctx, s.cond, arena, x, y, z);
            const t = to_z3(ctx, s.true_val, arena, x, y, z);
            const f = to_z3(ctx, s.false_val, arena, x, y, z);
            
            const sort = z3.Z3_mk_bv_sort(ctx, 32);
            const zero = z3.Z3_mk_unsigned_int64(ctx, 0, sort);
            const cmp = z3.Z3_mk_eq(ctx, c, zero);
            return z3.Z3_mk_ite(ctx, cmp, f, t);
        }
    }
}

pub const Z3Result = union(enum) {
    sat: CE,
    unsat: void,
    timeout: void,
};

fn check_class_ctx(allocator: std.mem.Allocator, class_id: u32, head: []const u32, next: []const u32, arena: *const @import("arena.zig").ExpressionArena, proven_cache: *std.AutoHashMap(u64, void), ce_mutex: *std.Thread.Mutex) Z3Result {
    const z3_cfg = z3.Z3_mk_config();
    var timeout_buf: [32]u8 = undefined;
    const timeout_str = std.fmt.bufPrintZ(&timeout_buf, "{d}", .{config.active.z3_timeout_ms}) catch "1000";
    z3.Z3_set_param_value(z3_cfg, "timeout", timeout_str.ptr);
    const ctx = z3.Z3_mk_context(z3_cfg);
    defer {
        z3.Z3_del_context(ctx);
        z3.Z3_del_config(z3_cfg);
    }
    


    
    const solver = z3.Z3_mk_solver(ctx);
    z3.Z3_solver_inc_ref(ctx, solver);
    defer z3.Z3_solver_dec_ref(ctx, solver);
    
    const params = z3.Z3_mk_params(ctx);
    z3.Z3_params_inc_ref(ctx, params);
    defer z3.Z3_params_dec_ref(ctx, params);
    const sym_timeout = z3.Z3_mk_string_symbol(ctx, "timeout");
    z3.Z3_params_set_uint(ctx, params, sym_timeout, config.active.z3_timeout_ms);
    z3.Z3_solver_set_params(ctx, solver, params);

    const sort = z3.Z3_mk_bv_sort(ctx, 32);
    
    const sym_x = z3.Z3_mk_string_symbol(ctx, "x");
    const sym_y = z3.Z3_mk_string_symbol(ctx, "y");
    const sym_z = z3.Z3_mk_string_symbol(ctx, "z");
    
    const x = z3.Z3_mk_const(ctx, sym_x, sort);
    const y = z3.Z3_mk_const(ctx, sym_y, sort);
    const z = z3.Z3_mk_const(ctx, sym_z, sort);

    var curr: u32 = head[class_id];
    const base_expr = curr;
    const base_z3 = to_z3(ctx, base_expr, arena, x, y, z);
    
    curr = next[curr];
    if (curr == 0xFFFFFFFF) return .unsat; 
    
    var conds_list = std.ArrayList(z3.Z3_ast).init(allocator);
    var eval_list_arr = std.ArrayList(u32).init(allocator);
    
    while (curr != 0xFFFFFFFF) {
        const cache_key = get_cache_key(curr, base_expr, arena);
        ce_mutex.lock();
        const is_proven = proven_cache.contains(cache_key);
        ce_mutex.unlock();
        
        if (!is_proven) {
            const expr_z3 = to_z3(ctx, curr, arena, x, y, z);
            const neq = z3.Z3_mk_not(ctx, z3.Z3_mk_eq(ctx, base_z3, expr_z3));
            conds_list.append(neq) catch return .timeout;
            eval_list_arr.append(curr) catch return .timeout;
            
        }
        curr = next[curr];
    }
    
    if (conds_list.items.len == 0) return .unsat;
    
    if (conds_list.items.len > 1) {
        const batch_or = z3.Z3_mk_or(ctx, @as(u32, @intCast(conds_list.items.len)), conds_list.items.ptr);
        z3.Z3_solver_assert(ctx, solver, batch_or);
    } else {
        z3.Z3_solver_assert(ctx, solver, conds_list.items[0]);
    }
    
    const result = z3.Z3_solver_check(ctx, solver);
    if (result == z3.Z3_L_UNDEF) return .timeout;
    if (result == z3.Z3_L_TRUE) {
        const model = z3.Z3_solver_get_model(ctx, solver);
        if (model == null) return .timeout;
        z3.Z3_model_inc_ref(ctx, model);
        defer z3.Z3_model_dec_ref(ctx, model);
        
        var x_val: z3.Z3_ast = undefined;
        var y_val: z3.Z3_ast = undefined;
        var z_val: z3.Z3_ast = undefined;
        
        var cx: i32 = 0;
        var cy: i32 = 0;
        var cz: i32 = 0;

        if (z3.Z3_model_eval(ctx, model, x, true, &x_val) == true) {
            var val: u64 = 0;
            if (z3.Z3_get_numeral_uint64(ctx, x_val, &val)) {
                cx = @as(i32, @bitCast(@as(u32, @truncate(val))));
            }
        }
        if (z3.Z3_model_eval(ctx, model, y, true, &y_val) == true) {
            var val: u64 = 0;
            if (z3.Z3_get_numeral_uint64(ctx, y_val, &val)) {
                cy = @as(i32, @bitCast(@as(u32, @truncate(val))));
            }
        }
        if (z3.Z3_model_eval(ctx, model, z, true, &z_val) == true) {
            var val: u64 = 0;
            if (z3.Z3_get_numeral_uint64(ctx, z_val, &val)) {
                cz = @as(i32, @bitCast(@as(u32, @truncate(val))));
            }
        }
        
        return .{ .sat = CE{ .x = cx, .y = cy, .z = cz } };
    }
    
    // UNSAT means we PROVED all eval_list expressions are equivalent to base_expr!
    ce_mutex.lock();
    for (0..conds_list.items.len) |i| {
        const cache_key = get_cache_key(eval_list_arr.items[i], base_expr, arena);
        proven_cache.put(cache_key, {}) catch {};
    }
    ce_mutex.unlock();
    
    return .unsat;
}


pub const CollidingClass = struct {
    id: u32,
    size: usize,

    fn lessThan(context: void, a: CollidingClass, b: CollidingClass) bool {
        _ = context;
        return a.size > b.size; // sort descending
    }
};

fn verify_worker(
    start_idx: usize,
    end_idx: usize,
    top_slice: []const CollidingClass,
    head: []const u32,
    next: []const u32,
    arena: *const @import("arena.zig").ExpressionArena,
    progress: *std.atomic.Value(usize),
    mistakes_atomic: *std.atomic.Value(usize),
    timeouts_atomic: *std.atomic.Value(usize),
    total_classes: usize,
    start_time: i64,
    unique_ces: *std.AutoHashMap(CE, void),
    ce_mutex: *std.Thread.Mutex,
    stop_flag: *std.atomic.Value(bool),
    proven_cache: *std.AutoHashMap(u64, void),
) void {
    var idx = start_idx;
    while (idx < end_idx) : (idx += 1) {
        
        
        var arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_alloc.deinit();
        const res = check_class_ctx(arena_alloc.allocator(), top_slice[idx].id, head, next, arena, proven_cache, ce_mutex);
        
        switch (res) {
            .sat => |ce| {
                _ = mistakes_atomic.fetchAdd(1, .monotonic);
                ce_mutex.lock();
                unique_ces.put(ce, {}) catch {};
                const ucount = unique_ces.count();
                ce_mutex.unlock();
                if (ucount >= config.active.max_counterexamples_per_iter) {
                    stop_flag.store(true, .release);
                }
            },
            .timeout => {
                _ = timeouts_atomic.fetchAdd(1, .monotonic);
            },
            .unsat => {},
        }
        
        const curr_prog = progress.fetchAdd(1, .monotonic) + 1;
        if (curr_prog % 100 == 0 or curr_prog == total_classes or stop_flag.load(.acquire)) {
            const now = std.time.milliTimestamp();
            const elapsed_s = @as(f64, @floatFromInt(now - start_time)) / 1000.0;
            const speed = if (elapsed_s > 0) @as(f64, @floatFromInt(curr_prog)) / elapsed_s else 0;
            
            const current_mistakes = mistakes_atomic.load(.acquire);
            const current_timeouts = timeouts_atomic.load(.acquire);
            
            ce_mutex.lock();
            const current_unique = unique_ces.count();
            ce_mutex.unlock();
            
            std.debug.print("\rZ3 SAT Proofs: {}/{} classes | {d:.1} classes/s | raw CEs: {} | unique CEs: {} | timeouts: {}...", .{curr_prog, total_classes, speed, current_mistakes, current_unique, current_timeouts});
        }
    }
}

pub const VerifyResult = struct { mistakes: usize, timeouts: usize };
pub fn verify_classes(db: *database.ExpressionDatabase, iteration: usize, proven_cache: *std.AutoHashMap(u64, void), num_threads: usize) !VerifyResult {
    var timer = try std.time.Timer.start();
    
    
    
    // Use a buffered writer for MASSIVE IO speedup
    
    

    std.debug.print("Exporting collisions to Z3...\n", .{});
    
    // O(N) Linked-List Grouping to avoid O(N*C) 500-trillion loop
    const num_exprs = db.expr_arena.len;
    const num_classes = db.classes.items.len;
    
    var head = try std.heap.page_allocator.alloc(u32, num_classes);
    defer std.heap.page_allocator.free(head);
    @memset(head, 0xFFFFFFFF);
    
    var next = try std.heap.page_allocator.alloc(u32, num_exprs);
    defer std.heap.page_allocator.free(next);
    @memset(next, 0xFFFFFFFF);
    
    var class_sizes = try std.heap.page_allocator.alloc(u32, num_classes);
    defer std.heap.page_allocator.free(class_sizes);
    @memset(class_sizes, 0);

    for (db.expr_to_class.items, 0..) |cid, expr_id| {
        next[expr_id] = head[cid];
        head[cid] = @as(u32, @intCast(expr_id));
        class_sizes[cid] += 1;
    }
    
    


    
    var colliding_list = std.ArrayList(CollidingClass).init(std.heap.page_allocator);
    defer colliding_list.deinit();
    
    for (class_sizes, 0..) |sz, cid| {
        if (sz > 1) {
            try colliding_list.append(.{ .id = @as(u32, @intCast(cid)), .size = sz });
        }
    }
    
    // Sort descending by size
    std.sort.block(CollidingClass, colliding_list.items, {}, CollidingClass.lessThan);
    
    // Take the top 500k fattest classes (or less if not enough)
    const top_n = @min(colliding_list.items.len, config.active.max_classes_to_verify);
    const top_slice = colliding_list.items[0..top_n];
    
    // Randomly shuffle the top slice to ensure Z3 diversity and prevent timeout deadlocks
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
    const random = prng.random();
    random.shuffle(CollidingClass, top_slice);

    

    const ce_file = std.fs.cwd().openFile(config.active.counterexamples_file, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(config.active.counterexamples_file, .{}),
        else => return err,
    };
    defer ce_file.close();
    try ce_file.seekFromEnd(0);
    const ce_writer = ce_file.writer();

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = std.heap.page_allocator });
    defer pool.deinit();
    
    var wg = std.Thread.WaitGroup{};
    
    
    std.debug.print("Z3 SAT Solver: Spawning {} parallel threads across CPU cores...\n", .{num_threads});
    
    const chunk_size = (top_slice.len + num_threads - 1) / num_threads;
    
    var progress = std.atomic.Value(usize).init(0);
    var mistakes_atomic = std.atomic.Value(usize).init(0);
    var timeouts_atomic = std.atomic.Value(usize).init(0);
    const start_time = std.time.milliTimestamp();
    
    var unique_ces = std.AutoHashMap(CE, void).init(std.heap.page_allocator);
    defer unique_ces.deinit();
    var ce_mutex = std.Thread.Mutex{};
    var stop_flag = std.atomic.Value(bool).init(false);
    
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        const start_idx = t * chunk_size;
        const end_idx = @min(start_idx + chunk_size, top_slice.len);
        if (start_idx >= end_idx) continue;
        
        pool.spawnWg(&wg, verify_worker, .{ start_idx, end_idx, top_slice, head, next, &db.expr_arena, &progress, &mistakes_atomic, &timeouts_atomic, top_slice.len, start_time, &unique_ces, &ce_mutex, &stop_flag, proven_cache });
    }
    wg.wait();
    
    const timeouts = timeouts_atomic.load(.acquire);
    const mistakes = mistakes_atomic.load(.acquire);
    
    var unique_count: usize = 0;
    var ce_it = unique_ces.keyIterator();
    while (ce_it.next()) |ce| {
        try ce_writer.print("{},{},{}\n", .{ce.x, ce.y, ce.z});
        unique_count += 1;
        if (unique_count >= config.active.max_counterexamples_per_iter) break;
    }
    
    if (stop_flag.load(.acquire)) {
        std.debug.print("\n[Early Stop] Counterexample cap ({}) reached! Verification aborted early.\n", .{config.active.max_counterexamples_per_iter});
    }
    
    const elapsed_s = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    std.debug.print("\nZ3 Verification complete in {d:.2}s. Raw CEs: {}, Unique CEs added: {}\n", .{elapsed_s, mistakes, unique_count});
    
    // Log telemetry JSON
    var tel = try telemetry.Telemetry.init(config.active.telemetry_file);
    try tel.logVerify(elapsed_s, iteration, top_slice.len, mistakes, timeouts);
    tel.deinit();
    
    return .{ .mistakes = mistakes, .timeouts = timeouts };
}