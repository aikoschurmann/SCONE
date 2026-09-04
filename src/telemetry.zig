const std = @import("std");

pub const Telemetry = struct {
    file: std.fs.File,

    pub fn init(filepath: []const u8) !Telemetry {
        const file = try std.fs.cwd().createFile(filepath, .{});
        return .{ .file = file };
    }

    pub fn deinit(self: *Telemetry) void {
        self.file.close();
    }

    pub fn logEvaluate(self: *Telemetry, iteration: usize, cost: usize, processed: usize, speed: f64, elapsed: f64) !void {
        try self.file.writer().print(
            "{{\"event\": \"evaluate\", \"iteration\": {d}, \"cost\": {d}, \"processed_exprs\": {d}, \"speed_exprs_per_sec\": {d:.1}, \"elapsed_s\": {d:.2}}}\n",
            .{ iteration, cost, processed, speed, elapsed }
        );
    }

    pub fn logMetrics(self: *Telemetry, iteration: usize, nodes: usize, total_classes: usize, perfect: usize, colliding: usize, exprs_in_col: usize, grid: usize) !void {
        try self.file.writer().print(
            "{{\"event\": \"metrics\", \"iteration\": {d}, \"total_ast_nodes\": {d}, \"total_classes\": {d}, \"perfect_classes\": {d}, \"colliding_classes\": {d}, \"exprs_in_collisions\": {d}, \"eval_grid_size\": {d}}}\n",
            .{ iteration, nodes, total_classes, perfect, colliding, exprs_in_col, grid }
        );
    }

    pub fn logVerify(self: *Telemetry, elapsed: f64, iteration: usize, verified: usize, mistakes: usize, timeouts: usize) !void {
        try self.file.writer().print(
            "{{\"event\": \"verify\", \"elapsed_s\": {d:.2}, \"iteration\": {d}, \"classes_verified\": {d}, \"mistakes_found\": {d}, \"timeouts\": {d}}}\n",
            .{ elapsed, iteration, verified, mistakes, timeouts }
        );
    }
};
