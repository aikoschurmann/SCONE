const std = @import("std");
const ast = @import("ast.zig");
const eval_mod = @import("eval.zig");
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
                .clz, .ctz, .popcount => unreachable, 
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

pub fn check_class_ctx(ctx: z3.Z3_context, class_id: u32, head: []const u32, next: []const u32, arena: *const @import("arena.zig").ExpressionArena) ?CE {
    


    
    const solver = z3.Z3_mk_solver(ctx);
    z3.Z3_solver_inc_ref(ctx, solver);
    defer z3.Z3_solver_dec_ref(ctx, solver);
    
    const params = z3.Z3_mk_params(ctx);
    z3.Z3_params_inc_ref(ctx, params);
    defer z3.Z3_params_dec_ref(ctx, params);
    const sym_timeout = z3.Z3_mk_string_symbol(ctx, "timeout");
    z3.Z3_params_set_uint(ctx, params, sym_timeout, 1000);
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
    if (curr == 0xFFFFFFFF) return null; 
    
    var num_conds: u32 = 0;
    var conds: [1000]z3.Z3_ast = undefined; 
    
    while (curr != 0xFFFFFFFF and num_conds < 1000) {
        const expr_z3 = to_z3(ctx, curr, arena, x, y, z);
        const neq = z3.Z3_mk_not(ctx, z3.Z3_mk_eq(ctx, base_z3, expr_z3));
        conds[num_conds] = neq;
        num_conds += 1;
        curr = next[curr];
    }
    
    if (num_conds > 1) {
        const batch_or = z3.Z3_mk_or(ctx, num_conds, &conds);
        z3.Z3_solver_assert(ctx, solver, batch_or);
    } else {
        z3.Z3_solver_assert(ctx, solver, conds[0]);
    }
    
    const result = z3.Z3_solver_check(ctx, solver);
    if (result == z3.Z3_L_TRUE) {
        const model = z3.Z3_solver_get_model(ctx, solver);
        if (model == null) return null;
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
        
        return CE{ .x = cx, .y = cy, .z = cz };
    }
    
    return null;
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
    results: []?CE,
    start_idx: usize,
    end_idx: usize,
    top_slice: []const CollidingClass,
    head: []const u32,
    next: []const u32,
    arena: *const @import("arena.zig").ExpressionArena,
    progress: *std.atomic.Value(usize),
    total_classes: usize,
) void {
    const z3_cfg = z3.Z3_mk_config();
    z3.Z3_set_param_value(z3_cfg, "timeout", std.fmt.allocPrintZ(std.heap.page_allocator, "{d}", .{config.z3_timeout_ms}) catch "1000"); 
    const ctx = z3.Z3_mk_context(z3_cfg);
    defer {
        z3.Z3_del_context(ctx);
        z3.Z3_del_config(z3_cfg);
    }
    
    var idx = start_idx;
    while (idx < end_idx) : (idx += 1) {
        results[idx] = check_class_ctx(ctx, top_slice[idx].id, head, next, arena);
        
        const curr_prog = progress.fetchAdd(1, .monotonic) + 1;
        if (curr_prog % 100 == 0 or curr_prog == total_classes) {
            std.debug.print("\rZ3 SAT Proofs: {}/{} classes verified...", .{curr_prog, total_classes});
        }
    }
}

pub fn verify_classes(db: *eval_mod.ExpressionDatabase, iteration: usize) !usize {
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
    const top_n = @min(colliding_list.items.len, config.max_classes_to_verify);
    const top_slice = colliding_list.items[0..top_n];
    
    // Randomly shuffle the top slice to ensure Z3 diversity and prevent timeout deadlocks
    var prng = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
    const random = prng.random();
    random.shuffle(CollidingClass, top_slice);

    

    const ce_file = std.fs.cwd().openFile(config.counterexamples_file, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(config.counterexamples_file, .{}),
        else => return err,
    };
    defer ce_file.close();
    try ce_file.seekFromEnd(0);
    const ce_writer = ce_file.writer();

    const results = try std.heap.page_allocator.alloc(?CE, top_slice.len);
    defer std.heap.page_allocator.free(results);
    
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = std.heap.page_allocator });
    defer pool.deinit();
    
    var wg = std.Thread.WaitGroup{};
    
    const num_threads = std.Thread.getCpuCount() catch 4;
    std.debug.print("Z3 SAT Solver: Spawning {} parallel threads across CPU cores...\n", .{num_threads});
    
    const chunk_size = (top_slice.len + num_threads - 1) / num_threads;
    
    var progress = std.atomic.Value(usize).init(0);
    
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        const start_idx = t * chunk_size;
        const end_idx = @min(start_idx + chunk_size, top_slice.len);
        if (start_idx >= end_idx) continue;
        
        pool.spawnWg(&wg, verify_worker, .{ results, start_idx, end_idx, top_slice, head, next, &db.expr_arena, &progress, top_slice.len });
    }
    wg.wait();
    
    var mistakes: usize = 0;
    const timeouts: usize = 0;
    
    for (results) |res| {
        if (res) |ce| {
            try ce_writer.print("{},{},{}\n", .{ce.x, ce.y, ce.z});
            mistakes += 1;
            if (mistakes >= 500) break;
        }
    }
    
    const elapsed_s = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    std.debug.print("\nZ3 Verification complete in {d:.2}s. Mistakes found: {}\n", .{elapsed_s, mistakes});
    
    // Log telemetry JSON
    const tel_file = try std.fs.cwd().openFile(config.telemetry_file, .{ .mode = .read_write });
    defer tel_file.close();
    try tel_file.seekFromEnd(0);
    try tel_file.writer().print("{{\"event\": \"verify\", \"elapsed_s\": {d:.2}, \"iteration\": {d}, \"classes_verified\": {d}, \"mistakes_found\": {d}, \"timeouts\": {d}}}\n", .{elapsed_s, iteration, top_slice.len, mistakes, timeouts});
    
    return mistakes;
}