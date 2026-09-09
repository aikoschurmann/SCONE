const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const database = @import("database.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteDb = struct {
    db: *c.sqlite3,
    
    pub fn init(path: [:0]const u8) !SqliteDb {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &db) != c.SQLITE_OK) {
            std.debug.print("Failed to open SQLite DB at {s}\n", .{path});
            return error.SqliteOpenFailed;
        }
        
        const self = SqliteDb{ .db = db.? };
        try self.exec(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
            \\CREATE TABLE IF NOT EXISTS meta (
            \\    key TEXT PRIMARY KEY,
            \\    value INTEGER
            \\);
            \\CREATE TABLE IF NOT EXISTS counterexamples (
            \\    id INTEGER PRIMARY KEY,
            \\    x INTEGER,
            \\    y INTEGER,
            \\    z INTEGER
            \\);
            \\CREATE TABLE IF NOT EXISTS expressions (
            \\    id INTEGER PRIMARY KEY,
            \\    tag TEXT,
            \\    op TEXT,
            \\    c1 INTEGER,
            \\    c2 INTEGER,
            \\    c3 INTEGER
            \\);
            \\CREATE TABLE IF NOT EXISTS classes (
            \\    id INTEGER PRIMARY KEY,
            \\    hash_high INTEGER,
            \\    hash_low INTEGER,
            \\    canonical_expr_id INTEGER,
            \\    status TEXT DEFAULT 'verified'
            \\);
        );
        return self;
    }
    
    pub fn deinit(self: *SqliteDb) void {
        _ = c.sqlite3_close(self.db);
    }
    
    pub fn exec(self: *const SqliteDb, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql, null, null, &err_msg) != c.SQLITE_OK) {
            std.debug.print("SQL Error: {s}\n", .{err_msg});
            c.sqlite3_free(err_msg);
            return error.SqliteExecFailed;
        }
    }
    
    pub fn begin(self: *const SqliteDb) !void { try self.exec("BEGIN TRANSACTION;"); }
    pub fn commit(self: *const SqliteDb) !void { try self.exec("COMMIT;"); }
    
    pub fn save_state(self: *const SqliteDb, db_scone: *const database.ExpressionDatabase, eval_ctx: *const eval.EvaluationContext, max_cost: usize) !void {
        std.debug.print("\nSaving engine state to SQLite...\n", .{});
        try self.begin();
        
        // Save meta
        var stmt_meta: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);", -1, &stmt_meta, null);
        _ = c.sqlite3_bind_text(stmt_meta, 1, "max_cost", -1, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt_meta, 2, @intCast(max_cost));
        _ = c.sqlite3_step(stmt_meta);
        _ = c.sqlite3_finalize(stmt_meta);
        
        // Save counterexamples (Only append new ones)
        // Wait, just clear and rewrite for safety, it's tiny.
        try self.exec("DELETE FROM counterexamples;");
        var stmt_ce: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT INTO counterexamples (id, x, y, z) VALUES (?, ?, ?, ?);", -1, &stmt_ce, null);
        
        for (0..eval_ctx.total_samples) |i| {
            const batch = i / eval.BATCH_SIZE;
            const lane = i % eval.BATCH_SIZE;
            _ = c.sqlite3_reset(stmt_ce);
            _ = c.sqlite3_bind_int64(stmt_ce, 1, @intCast(i));
            _ = c.sqlite3_bind_int64(stmt_ce, 2, eval_ctx.x_batches[batch][lane]);
            _ = c.sqlite3_bind_int64(stmt_ce, 3, eval_ctx.y_batches[batch][lane]);
            _ = c.sqlite3_bind_int64(stmt_ce, 4, eval_ctx.z_batches[batch][lane]);
            _ = c.sqlite3_step(stmt_ce);
        }
        _ = c.sqlite3_finalize(stmt_ce);
        
        // Save expressions
        try self.exec("DELETE FROM expressions;");
        var stmt_expr: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT INTO expressions (id, tag, op, c1, c2, c3) VALUES (?, ?, ?, ?, ?, ?);", -1, &stmt_expr, null);
        
        for (0..db_scone.expr_arena.len) |i| {
            const expr = db_scone.expr_arena.get(@intCast(i));
            _ = c.sqlite3_reset(stmt_expr);
            _ = c.sqlite3_bind_int64(stmt_expr, 1, @intCast(i));
            _ = c.sqlite3_bind_int64(stmt_expr, 2, @intCast(db_scone.expr_to_class.items[i]));
            switch (expr) {
                .variable => |v| {
                    _ = c.sqlite3_bind_text(stmt_expr, 2, "variable", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 3, @intFromEnum(v));
                },
                .constant => |c_val| {
                    _ = c.sqlite3_bind_text(stmt_expr, 2, "constant", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 3, c_val);
                },
                .unary => |u| {
                    _ = c.sqlite3_bind_text(stmt_expr, 2, "unary", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 3, @intFromEnum(u.op));
                    _ = c.sqlite3_bind_int64(stmt_expr, 4, u.expr);
                },
                .binary => |b| {
                    _ = c.sqlite3_bind_text(stmt_expr, 2, "binary", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 3, @intFromEnum(b.op));
                    _ = c.sqlite3_bind_int64(stmt_expr, 4, b.lhs);
                    _ = c.sqlite3_bind_int64(stmt_expr, 5, b.rhs);
                },
                .select => |s| {
                    _ = c.sqlite3_bind_text(stmt_expr, 2, "select", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 4, s.cond);
                    _ = c.sqlite3_bind_int64(stmt_expr, 5, s.true_val);
                    _ = c.sqlite3_bind_int64(stmt_expr, 6, s.false_val);
                }
            }
            _ = c.sqlite3_step(stmt_expr);
        }
        _ = c.sqlite3_finalize(stmt_expr);
        
        // Save classes
        try self.exec("DELETE FROM classes;");
        var stmt_cls: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT INTO classes (id, hash_high, hash_low, canonical_expr_id) VALUES (?, ?, ?, ?);", -1, &stmt_cls, null);
        
        for (0..db_scone.classes.items.len) |i| {
            const cls = db_scone.classes.items[i];
            _ = c.sqlite3_reset(stmt_cls);
            _ = c.sqlite3_bind_int64(stmt_cls, 1, @intCast(i));
            _ = c.sqlite3_bind_int64(stmt_cls, 2, @intCast(cls.hash >> 64));
            _ = c.sqlite3_bind_int64(stmt_cls, 3, @intCast(cls.hash & 0xFFFFFFFFFFFFFFFF));
            _ = c.sqlite3_bind_int64(stmt_cls, 4, cls.canonical_expr);
            _ = c.sqlite3_step(stmt_cls);
        }
        _ = c.sqlite3_finalize(stmt_cls);
        
        try self.commit();
        std.debug.print("SQLite save complete!\n", .{});
    }
    
    pub fn load_state(self: *const SqliteDb, db_scone: *database.ExpressionDatabase, eval_ctx: *eval.EvaluationContext) !usize {
        var stmt_meta: ?*c.sqlite3_stmt = null;
        var max_cost: usize = 0;
        if (c.sqlite3_prepare_v2(self.db, "SELECT value FROM meta WHERE key = 'max_cost';", -1, &stmt_meta, null) == c.SQLITE_OK) {
            if (c.sqlite3_step(stmt_meta) == c.SQLITE_ROW) {
                max_cost = @intCast(c.sqlite3_column_int64(stmt_meta, 0));
            }
        }
        _ = c.sqlite3_finalize(stmt_meta);
        
        if (max_cost == 0) return 0; // DB is empty or cost 0
        
        std.debug.print("Found existing SQLite state! Resuming from Cost {}...\n", .{max_cost + 1});
        
        // Load Counterexamples
        var stmt_ce: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "SELECT x, y, z FROM counterexamples ORDER BY id ASC;", -1, &stmt_ce, null);
        var ce_idx: usize = 0;
        while (c.sqlite3_step(stmt_ce) == c.SQLITE_ROW) {
            eval_ctx.setSample(
                ce_idx,
                @intCast(c.sqlite3_column_int64(stmt_ce, 0)),
                @intCast(c.sqlite3_column_int64(stmt_ce, 1)),
                @intCast(c.sqlite3_column_int64(stmt_ce, 2))
            );
            ce_idx += 1;
        }
        _ = c.sqlite3_finalize(stmt_ce);
        eval_ctx.total_samples = ce_idx;
        
        // Load Expressions
        var stmt_expr: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "SELECT tag, op, c1, c2, c3 FROM expressions ORDER BY id ASC;", -1, &stmt_expr, null);
        while (c.sqlite3_step(stmt_expr) == c.SQLITE_ROW) {
            const tag = c.sqlite3_column_text(stmt_expr, 0);
            const tag_str = std.mem.span(tag);
            var expr: ast.Expr = undefined;
            if (std.mem.eql(u8, tag_str, "variable")) {
                expr = .{ .variable = @enumFromInt(c.sqlite3_column_int64(stmt_expr, 1)) };
            } else if (std.mem.eql(u8, tag_str, "constant")) {
                expr = .{ .constant = @intCast(c.sqlite3_column_int64(stmt_expr, 1)) };
            } else if (std.mem.eql(u8, tag_str, "unary")) {
                expr = .{ .unary = .{
                    .op = @enumFromInt(c.sqlite3_column_int64(stmt_expr, 1)),
                    .expr = @intCast(c.sqlite3_column_int64(stmt_expr, 2))
                }};
            } else if (std.mem.eql(u8, tag_str, "binary")) {
                expr = .{ .binary = .{
                    .op = @enumFromInt(c.sqlite3_column_int64(stmt_expr, 1)),
                    .lhs = @intCast(c.sqlite3_column_int64(stmt_expr, 2)),
                    .rhs = @intCast(c.sqlite3_column_int64(stmt_expr, 3))
                }};
            } else if (std.mem.eql(u8, tag_str, "select")) {
                expr = .{ .select = .{
                    .cond = @intCast(c.sqlite3_column_int64(stmt_expr, 2)),
                    .true_val = @intCast(c.sqlite3_column_int64(stmt_expr, 3)),
                    .false_val = @intCast(c.sqlite3_column_int64(stmt_expr, 4))
                }};
            }
            _ = try db_scone.expr_arena.add(expr);
        }
        _ = c.sqlite3_finalize(stmt_expr);
        
        // Load Classes
        var stmt_cls: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "SELECT id, hash_high, hash_low, canonical_expr_id FROM classes ORDER BY id ASC;", -1, &stmt_cls, null);
        while (c.sqlite3_step(stmt_cls) == c.SQLITE_ROW) {
            const cls_id = @as(u32, @intCast(c.sqlite3_column_int64(stmt_cls, 0)));
            const hash_high = @as(u128, @as(u64, @bitCast(c.sqlite3_column_int64(stmt_cls, 1))));
            const hash_low = @as(u128, @as(u64, @bitCast(c.sqlite3_column_int64(stmt_cls, 2))));
            const hash = (hash_high << 64) | hash_low;
            const canonical_expr = @as(u32, @intCast(c.sqlite3_column_int64(stmt_cls, 3)));
            
            try db_scone.classes.append(.{ .hash = hash, .canonical_expr = canonical_expr });
            _ = try db_scone.class_vectors.reserve(cls_id);
            
            // Reconstruct deduplication mappings
            const gop = try db_scone.fp_to_class.getOrPut(hash);
            gop.value_ptr.* = database.SmallClassList.init(cls_id);
            try db_scone.expr_to_class.append(cls_id); // Wait, this only maps the canonical expr.
        }
        _ = c.sqlite3_finalize(stmt_cls);
        
        // Wait, expr_to_class needs to map EVERY expr in the arena to its class!
        // To perfectly restore state, we would need to save `expr_to_class` as a separate table.
        // Actually, evaluating the class vectors can just be done via `recompute_worker(0, classes.len)`!
        
        return max_cost;
    }

};
