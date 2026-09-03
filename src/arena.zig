const std = @import("std");
const ast = @import("ast.zig");

/// A Segmented Arena for lock-free concurrent reads.
/// Instead of a single contiguous array that might reallocate and move in memory,
/// we allocate fixed-size chunks. Once a chunk is allocated, it NEVER moves.
/// This allows worker threads to safely read from old chunks while the main thread
/// allocates new chunks, eliminating the need for "magic number" pre-allocations.
pub const ExpressionArena = struct {
    pub const CHUNK_SIZE = 65536; // 64K nodes per chunk
    const Chunk = [CHUNK_SIZE]ast.Expr;

    allocator: std.mem.Allocator,
    chunks: std.ArrayList(*Chunk),
    len: usize,

    pub fn init(allocator: std.mem.Allocator) !ExpressionArena {
        // Pre-allocate the chunk pointer array to hold enough pointers for billions of nodes.
        // 10,000 chunks * 64K = 655 million nodes limit, but the array of pointers only takes 80KB!
        // This ensures the `chunks.items` pointer itself never moves during normal operation,
        // and even if it did, worker threads don't read the chunk pointer array directly via an iterator,
        // they fetch the chunk pointer, which is safe as long as the array doesn't resize while being accessed.
        // Wait, actually the array OF POINTERS could move if it resizes.
        // We pre-allocate it to 100,000 to hold 6.5 Billion nodes safely without ever resizing.
        // 100,000 pointers * 8 bytes = 800 KB of RAM. Extremely lightweight.
        const chunks = try std.ArrayList(*Chunk).initCapacity(allocator, 100_000);
        
        return .{
            .allocator = allocator,
            .chunks = chunks,
            .len = 0,
        };
    }

    pub fn deinit(self: *ExpressionArena) void {
        for (self.chunks.items) |chunk| {
            self.allocator.destroy(chunk);
        }
        self.chunks.deinit();
    }

    pub fn add(self: *ExpressionArena, expr: ast.Expr) !ast.ExprId {
        const id = @as(ast.ExprId, @intCast(self.len));
        
        const chunk_idx = id / CHUNK_SIZE;
        const item_idx = id % CHUNK_SIZE;
        
        if (chunk_idx >= self.chunks.items.len) {
            // Allocate a new chunk
            const new_chunk = try self.allocator.create(Chunk);
            self.chunks.appendAssumeCapacity(new_chunk);
        }
        
        self.chunks.items[chunk_idx][item_idx] = expr;
        self.len += 1;
        
        return id;
    }

    pub fn get(self: *const ExpressionArena, id: ast.ExprId) ast.Expr {
        const chunk_idx = id / CHUNK_SIZE;
        const item_idx = id % CHUNK_SIZE;
        return self.chunks.items[chunk_idx][item_idx];
    }
};
