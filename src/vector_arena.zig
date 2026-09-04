const std = @import("std");
const eval = @import("eval.zig");
const Vector64 = eval.Vector64;
const ClassId = u32;

pub const ClassVectorArena = struct {
    pub const CHUNK_SIZE = 8192; // classes per chunk

    allocator: std.mem.Allocator,
    num_batches: usize,
    row_bytes: usize,
    chunks: std.ArrayList([]Vector64),
    len: usize,

    pub fn init(allocator: std.mem.Allocator, num_batches: usize) !ClassVectorArena {
        const chunks = try std.ArrayList([]Vector64).initCapacity(allocator, 20_000);
        return .{
            .allocator = allocator,
            .num_batches = num_batches,
            .row_bytes = num_batches * @sizeOf(Vector64),
            .chunks = chunks,
            .len = 0,
        };
    }

    pub fn deinit(self: *ClassVectorArena) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit();
    }

    pub fn reserve(self: *ClassVectorArena, class_id: ClassId) ![]Vector64 {
        std.debug.assert(class_id == self.len);
        const chunk_idx = class_id / CHUNK_SIZE;
        const item_idx = class_id % CHUNK_SIZE;

        if (chunk_idx >= self.chunks.items.len) {
            const new_chunk = try self.allocator.alloc(Vector64, CHUNK_SIZE * self.num_batches);
            self.chunks.appendAssumeCapacity(new_chunk);
        }
        self.len += 1;
        const chunk = self.chunks.items[chunk_idx];
        const start = item_idx * self.num_batches;
        return chunk[start .. start + self.num_batches];
    }

    pub fn get(self: *const ClassVectorArena, class_id: ClassId) []const Vector64 {
        const chunk_idx = class_id / CHUNK_SIZE;
        const item_idx = class_id % CHUNK_SIZE;
        const chunk = self.chunks.items[chunk_idx];
        const start = item_idx * self.num_batches;
        return chunk[start .. start + self.num_batches];
    }
};
