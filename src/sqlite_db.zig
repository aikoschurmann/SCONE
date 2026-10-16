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
            \\    class_id INTEGER,
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
        // Migrate databases created before expressions.class_id existed (fails harmlessly if present).
        _ = c.sqlite3_exec(self.db, "ALTER TABLE expressions ADD COLUMN class_id INTEGER;", null, null, null);
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

    pub fn begin(self: *const SqliteDb) !void {
        try self.exec("BEGIN TRANSACTION;");
    }
    pub fn commit(self: *const SqliteDb) !void {
        try self.exec("COMMIT;");
    }

    /// Clears saved expressions, classes and progress (counterexamples are kept: they remain useful inputs).
    pub fn reset_state(self: *const SqliteDb) !void {
        try self.exec("DELETE FROM expressions; DELETE FROM classes; DELETE FROM meta;");
    }

    /// Appends the expressions and classes created since the previous save and marks `max_cost`
    /// as fully verified, so a resumed run never re-proves a finished level. Splits only move
    /// expressions of the level being saved, so earlier rows never change, apart from the
    /// status of classes that timed out.
    pub fn save_level(self: *const SqliteDb, db_scone: *const database.ExpressionDatabase, expr_from: usize, class_from: usize, max_cost: usize) !void {
        try self.begin();

        var stmt_expr: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO expressions (id, class_id, tag, op, c1, c2, c3) VALUES (?, ?, ?, ?, ?, ?, ?);", -1, &stmt_expr, null);
        for (expr_from..db_scone.expr_arena.len) |i| {
            const expr = db_scone.expr_arena.get(@intCast(i));
            _ = c.sqlite3_reset(stmt_expr);
            _ = c.sqlite3_clear_bindings(stmt_expr);
            _ = c.sqlite3_bind_int64(stmt_expr, 1, @intCast(i));
            _ = c.sqlite3_bind_int64(stmt_expr, 2, @intCast(db_scone.expr_to_class.items[i]));
            switch (expr) {
                .variable => |v| {
                    _ = c.sqlite3_bind_text(stmt_expr, 3, "variable", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 4, @intFromEnum(v));
                },
                .constant => |c_val| {
                    _ = c.sqlite3_bind_text(stmt_expr, 3, "constant", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 4, c_val);
                },
                .unary => |u| {
                    _ = c.sqlite3_bind_text(stmt_expr, 3, "unary", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 4, @intFromEnum(u.op));
                    _ = c.sqlite3_bind_int64(stmt_expr, 5, u.expr);
                },
                .binary => |b| {
                    _ = c.sqlite3_bind_text(stmt_expr, 3, "binary", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 4, @intFromEnum(b.op));
                    _ = c.sqlite3_bind_int64(stmt_expr, 5, b.lhs);
                    _ = c.sqlite3_bind_int64(stmt_expr, 6, b.rhs);
                },
                .select => |sel| {
                    _ = c.sqlite3_bind_text(stmt_expr, 3, "select", -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_int64(stmt_expr, 5, sel.cond);
                    _ = c.sqlite3_bind_int64(stmt_expr, 6, sel.true_val);
                    _ = c.sqlite3_bind_int64(stmt_expr, 7, sel.false_val);
                },
            }
            _ = c.sqlite3_step(stmt_expr);
        }
        _ = c.sqlite3_finalize(stmt_expr);

        var stmt_cls: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO classes (id, hash_high, hash_low, canonical_expr_id, status) VALUES (?, ?, ?, ?, ?);", -1, &stmt_cls, null);
        for (class_from..db_scone.classes.items.len) |i| {
            const cls = db_scone.classes.items[i];
            _ = c.sqlite3_reset(stmt_cls);
            _ = c.sqlite3_bind_int64(stmt_cls, 1, @intCast(i));
            // hash_high is unused since fingerprints shrank to 64 bits; kept for schema compatibility.
            _ = c.sqlite3_bind_int64(stmt_cls, 2, 0);
            _ = c.sqlite3_bind_int64(stmt_cls, 3, @bitCast(cls.hash));
            _ = c.sqlite3_bind_int64(stmt_cls, 4, cls.canonical_expr);
            _ = c.sqlite3_bind_text(stmt_cls, 5, if (cls.unverified) "unverified" else "verified", -1, c.SQLITE_STATIC);
            _ = c.sqlite3_step(stmt_cls);
        }
        _ = c.sqlite3_finalize(stmt_cls);

        var stmt_status: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "UPDATE classes SET status = 'unverified' WHERE id = ?;", -1, &stmt_status, null);
        for (db_scone.classes.items[0..@min(class_from, db_scone.classes.items.len)], 0..) |cls, i| {
            if (!cls.unverified) continue;
            _ = c.sqlite3_reset(stmt_status);
            _ = c.sqlite3_bind_int64(stmt_status, 1, @intCast(i));
            _ = c.sqlite3_step(stmt_status);
        }
        _ = c.sqlite3_finalize(stmt_status);

        var stmt_meta: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('max_cost', ?);", -1, &stmt_meta, null);
        _ = c.sqlite3_bind_int64(stmt_meta, 1, @intCast(max_cost));
        _ = c.sqlite3_step(stmt_meta);
        _ = c.sqlite3_finalize(stmt_meta);

        try self.commit();
    }

    pub fn get_ce_count(self: *const SqliteDb) usize {
        var stmt: ?*c.sqlite3_stmt = null;
        var count: usize = 0;
        if (c.sqlite3_prepare_v2(self.db, "SELECT COUNT(*) FROM counterexamples;", -1, &stmt, null) == c.SQLITE_OK) {
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                count = @intCast(c.sqlite3_column_int64(stmt, 0));
            }
        }
        _ = c.sqlite3_finalize(stmt);
        return count;
    }

    /// Writes up to `max` stored counterexamples into the sample grid starting at `start_idx`.
    pub fn load_ces(self: *const SqliteDb, eval_ctx: anytype, start_idx: usize, max: usize) usize {
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "SELECT x, y, z FROM counterexamples ORDER BY id ASC;", -1, &stmt, null);
        var n: usize = 0;
        while (n < max and c.sqlite3_step(stmt) == c.SQLITE_ROW) : (n += 1) {
            eval_ctx.setSample(start_idx + n, decode_u32(c.sqlite3_column_int64(stmt, 0)), decode_u32(c.sqlite3_column_int64(stmt, 1)), decode_u32(c.sqlite3_column_int64(stmt, 2)));
        }
        _ = c.sqlite3_finalize(stmt);
        return n;
    }

    // Older rows may hold sign-extended i32 values; accept both encodings.
    fn decode_u32(v: i64) u32 {
        return @truncate(@as(u64, @bitCast(v)));
    }

    pub fn append_ces(self: *SqliteDb, ces: anytype) !void {
        try self.begin();
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT INTO counterexamples (x, y, z) VALUES (?, ?, ?);", -1, &stmt, null);
        for (ces) |ce| {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, ce.x);
            _ = c.sqlite3_bind_int64(stmt, 2, ce.y);
            _ = c.sqlite3_bind_int64(stmt, 3, ce.z);
            _ = c.sqlite3_step(stmt);
        }
        _ = c.sqlite3_finalize(stmt);
        try self.commit();
    }

    pub fn replace_ces(self: *SqliteDb, ce_indices: []const usize, eval_ctx: *const eval.EvaluationContext) !void {
        _ = c.sqlite3_exec(self.db, "DELETE FROM counterexamples;", null, null, null);
        try self.begin();
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "INSERT INTO counterexamples (id, x, y, z) VALUES (?, ?, ?, ?);", -1, &stmt, null);
        for (ce_indices, 0..) |idx, i| {
            const batch = idx / eval.BATCH_SIZE;
            const lane = idx % eval.BATCH_SIZE;
            const x: u32 = eval_ctx.x_batches[batch][lane];
            const y: u32 = eval_ctx.y_batches[batch][lane];
            const z: u32 = eval_ctx.z_batches[batch][lane];

            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, @intCast(i));
            _ = c.sqlite3_bind_int64(stmt, 2, x);
            _ = c.sqlite3_bind_int64(stmt, 3, y);
            _ = c.sqlite3_bind_int64(stmt, 4, z);
            _ = c.sqlite3_step(stmt);
        }
        _ = c.sqlite3_finalize(stmt);
        try self.commit();
    }

    pub fn load_state(self: *const SqliteDb, db_scone: *database.ExpressionDatabase) !usize {
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

        // Load Expressions
        var stmt_expr: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "SELECT tag, op, c1, c2, c3, class_id FROM expressions ORDER BY id ASC;", -1, &stmt_expr, null);
        while (c.sqlite3_step(stmt_expr) == c.SQLITE_ROW) {
            const tag = c.sqlite3_column_text(stmt_expr, 0);
            const tag_str = std.mem.span(tag);
            var expr: ast.Expr = undefined;
            if (std.mem.eql(u8, tag_str, "variable")) {
                expr = .{ .variable = @enumFromInt(c.sqlite3_column_int64(stmt_expr, 1)) };
            } else if (std.mem.eql(u8, tag_str, "constant")) {
                expr = .{ .constant = @intCast(c.sqlite3_column_int64(stmt_expr, 1)) };
            } else if (std.mem.eql(u8, tag_str, "unary")) {
                expr = .{ .unary = .{ .op = @enumFromInt(c.sqlite3_column_int64(stmt_expr, 1)), .expr = @intCast(c.sqlite3_column_int64(stmt_expr, 2)) } };
            } else if (std.mem.eql(u8, tag_str, "binary")) {
                expr = .{ .binary = .{ .op = @enumFromInt(c.sqlite3_column_int64(stmt_expr, 1)), .lhs = @intCast(c.sqlite3_column_int64(stmt_expr, 2)), .rhs = @intCast(c.sqlite3_column_int64(stmt_expr, 3)) } };
            } else if (std.mem.eql(u8, tag_str, "select")) {
                expr = .{ .select = .{ .cond = @intCast(c.sqlite3_column_int64(stmt_expr, 2)), .true_val = @intCast(c.sqlite3_column_int64(stmt_expr, 3)), .false_val = @intCast(c.sqlite3_column_int64(stmt_expr, 4)) } };
            }
            _ = try db_scone.expr_arena.add(expr);
            try db_scone.expr_to_class.append(@intCast(c.sqlite3_column_int64(stmt_expr, 5)));
        }
        _ = c.sqlite3_finalize(stmt_expr);

        // Load Classes
        var stmt_cls: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.db, "SELECT id, hash_high, hash_low, canonical_expr_id, status FROM classes ORDER BY id ASC;", -1, &stmt_cls, null);
        while (c.sqlite3_step(stmt_cls) == c.SQLITE_ROW) {
            const cls_id = @as(u32, @intCast(c.sqlite3_column_int64(stmt_cls, 0)));
            // Stored hashes are stale anyway (see below); the low word is enough as a placeholder.
            const hash: u64 = @bitCast(c.sqlite3_column_int64(stmt_cls, 2));
            const canonical_expr = @as(u32, @intCast(c.sqlite3_column_int64(stmt_cls, 3)));

            const status = c.sqlite3_column_text(stmt_cls, 4);
            const unverified = status != null and std.mem.eql(u8, std.mem.span(status), "unverified");

            try db_scone.classes.append(.{ .hash = hash, .canonical_expr = canonical_expr, .unverified = unverified });
            _ = try db_scone.class_vectors.reserve(cls_id);
        }
        _ = c.sqlite3_finalize(stmt_cls);

        // Class hashes are only valid for the grid they were computed on. The caller must
        // recompute class vectors and call Enumerator.rehash_classes() before enumerating.

        return max_cost;
    }
};
