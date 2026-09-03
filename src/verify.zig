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

pub fn check_class(class_id: u32, head: []const u32, next: []const u32, arena: *const @import("arena.zig").ExpressionArena) ?CE {
    const z3_cfg = z3.Z3_mk_config();
    z3.Z3_set_param_value(z3_cfg, "timeout", "1000"); 
    const ctx = z3.Z3_mk_context(z3_cfg);
    defer {
        z3.Z3_del_context(ctx);
        z3.Z3_del_config(z3_cfg);
    }
    
    const t_simp = z3.Z3_mk_tactic(ctx, "simplify");
    const t_bb = z3.Z3_mk_tactic(ctx, "bit-blast");
    const t_aig = z3.Z3_mk_tactic(ctx, "aig");
    const t_sat = z3.Z3_mk_tactic(ctx, "sat");
    
    const t1 = z3.Z3_tactic_and_then(ctx, t_simp, t_bb);
    const t2 = z3.Z3_tactic_and_then(ctx, t1, t_aig);
    const t_final = z3.Z3_tactic_and_then(ctx, t2, t_sat);
    
    const solver = z3.Z3_mk_solver_from_tactic(ctx, t_final);
    z3.Z3_solver_inc_ref(ctx, solver);
    defer z3.Z3_solver_dec_ref(ctx, solver);

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
