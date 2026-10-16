//! Replays logged Z3 pairs through the normalizer: `scripts/check.sh replay <pairs.tsv>`.
//! Input lines are `weight<TAB>base<TAB>member`; output lines are prefixed `settled` or `open`.

const std = @import("std");
const ast = @import("ast.zig");
const ExpressionArena = @import("arena.zig").ExpressionArena;
const Normalizer = @import("normalize.zig").Normalizer;
const exhaustive = @import("exhaustive.zig");
const P = struct {
    s: []const u8,
    i: usize = 0,
    arena: *ExpressionArena,
    fn tok(self: *P) []const u8 {
        while (self.i < self.s.len and self.s[self.i] == ' ') self.i += 1;
        const start = self.i;
        if (self.i < self.s.len and (self.s[self.i] == '(' or self.s[self.i] == ')' or self.s[self.i] == ',')) {
            self.i += 1;
            return self.s[start..self.i];
        }
        while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_')) self.i += 1;
        return self.s[start..self.i];
    }
    fn expr(self: *P) anyerror!ast.ExprId {
        const t = self.tok();
        if (std.mem.eql(u8, t, "(")) {
            const l = try self.expr();
            const op = std.meta.stringToEnum(ast.BinOp, self.tok()) orelse return error.Bad;
            const r = try self.expr();
            _ = self.tok();
            return self.arena.add(.{ .binary = .{ .op = op, .lhs = l, .rhs = r } });
        }
        if (std.mem.eql(u8, t, "select")) {
            _ = self.tok();
            const c = try self.expr();
            _ = self.tok();
            const a = try self.expr();
            _ = self.tok();
            const b = try self.expr();
            _ = self.tok();
            return self.arena.add(.{ .select = .{ .cond = c, .true_val = a, .false_val = b } });
        }
        if (std.meta.stringToEnum(ast.UnOp, t)) |op| {
            _ = self.tok();
            const a = try self.expr();
            _ = self.tok();
            return self.arena.add(.{ .unary = .{ .op = op, .expr = a } });
        }
        if (std.meta.stringToEnum(ast.Var, t)) |v| return self.arena.add(.{ .variable = v });
        return self.arena.add(.{ .constant = try std.fmt.parseInt(u32, t, 10) });
    }
};
test "replay" {
    const path = std.posix.getenv("REPLAY_IN") orelse return;
    const out_path = std.posix.getenv("REPLAY_OUT") orelse return;
    const gpa = std.heap.c_allocator;
    const data = try std.fs.cwd().readFileAlloc(gpa, path, 1 << 30);
    var out = try std.fs.cwd().createFile(out_path, .{});
    defer out.close();
    var bw = std.io.bufferedWriter(out.writer());
    var arena = try ExpressionArena.init(gpa);
    var norm = Normalizer.init(gpa);
    const use_exhaustive = std.posix.getenv("REPLAY_EXHAUSTIVE") != null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const us = f.next().?;
        const b = f.next() orelse continue;
        const m = f.next() orelse continue;
        var pb = P{ .s = b, .arena = &arena };
        var pm = P{ .s = m, .arena = &arena };
        const eb = pb.expr() catch continue;
        const em = pm.expr() catch continue;
        n += 1;
        if (n % 5000 == 0) norm.reset();
        const settled = (try norm.normalize(eb, &arena)) == (try norm.normalize(em, &arena));
        const wr = bw.writer();
        if (settled) {
            try wr.print("settled\t{s}\t{s}\t{s}\n", .{ us, b, m });
            continue;
        }
        // REPLAY_EXHAUSTIVE=1: open single-variable pairs are decided on all 2^32 inputs; the
        // fifth column gives the time taken and, for unequal pairs, an input where they differ.
        if (use_exhaustive) if (exhaustive.singleVar(&arena, eb, em)) |v| {
            var timer = try std.time.Timer.start();
            const verdict = try exhaustive.compare(gpa, &arena, eb, em);
            const ms = timer.read() / std.time.ns_per_ms;
            switch (verdict) {
                .equal => try wr.print("exhaustive\t{s}\t{s}\t{s}\t{d} ms\n", .{ us, b, m, ms }),
                .differ => |val| try wr.print("differ\t{s}\t{s}\t{s}\t{d} ms, at {s} = 0x{x}\n", .{ us, b, m, ms, @tagName(v), val }),
                .skipped => try wr.print("open\t{s}\t{s}\t{s}\n", .{ us, b, m }),
            }
            continue;
        };
        try wr.print("open\t{s}\t{s}\t{s}\n", .{ us, b, m });
    }
    try bw.flush();
}
