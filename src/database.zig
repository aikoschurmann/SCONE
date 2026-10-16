const std = @import("std");
const ast = @import("ast.zig");
const expr_arena = @import("arena.zig");
const vector_arena = @import("vector_arena.zig");
const eval = @import("eval.zig");

/// 64 bits keep EquivalenceClass at 16 bytes. A collision only merges two distinct functions
/// into one class, which Z3 then splits like any other sampling miss.
pub const FingerprintHash = u64;

pub const EquivalenceClass = struct {
    hash: FingerprintHash,
    canonical_expr: ast.ExprId,
    /// Set when Z3 could not prove all members equal (timeouts); persisted as classes.status.
    unverified: bool = false,
};

pub const ClassId = u32;

/// Fingerprint -> class lookup that stores only class ids (about 5 bytes per class instead of a
/// copy of the hash plus a value). The hash of a stored id is read from `classes[id].hash`, so
/// every call takes the current class array, and a class's hash must be set before it is inserted
/// and must not change while it is in the index (rehash_classes clears the index first).
/// The first class inserted for a fingerprint wins; later ones with the same hash are not indexed.
pub const ClassIndex = struct {
    map: std.HashMapUnmanaged(ClassId, void, Ctx, std.hash_map.default_max_load_percentage) = .{},

    // Lives on the page allocator: the table is replaced on growth, and the old one must be freed.
    const gpa = std.heap.page_allocator;

    const Ctx = struct {
        classes: []const EquivalenceClass,
        pub fn hash(c: Ctx, id: ClassId) u64 {
            return c.classes[id].hash;
        }
        pub fn eql(_: Ctx, a: ClassId, b: ClassId) bool {
            return a == b;
        }
    };
    const ByHash = struct {
        classes: []const EquivalenceClass,
        pub fn hash(_: ByHash, h: FingerprintHash) u64 {
            return h;
        }
        pub fn eql(c: ByHash, h: FingerprintHash, id: ClassId) bool {
            return c.classes[id].hash == h;
        }
    };

    pub fn get(self: *const ClassIndex, classes: []const EquivalenceClass, h: FingerprintHash) ?ClassId {
        return self.map.getKeyAdapted(h, ByHash{ .classes = classes });
    }

    /// Indexes `id` unless a class with the same fingerprint is already indexed.
    pub fn insert(self: *ClassIndex, classes: []const EquivalenceClass, id: ClassId) !void {
        const gop = try self.map.getOrPutContextAdapted(gpa, classes[id].hash, ByHash{ .classes = classes }, Ctx{ .classes = classes });
        if (!gop.found_existing) gop.key_ptr.* = id;
    }

    pub fn clear(self: *ClassIndex) void {
        self.map.clearRetainingCapacity();
    }

    pub fn deinit(self: *ClassIndex) void {
        self.map.deinit(gpa);
    }
};

pub const ExpressionDatabase = struct {
    allocator: std.mem.Allocator,

    expr_arena: expr_arena.ExpressionArena,
    expr_to_class: std.ArrayList(ClassId),
    classes: std.ArrayList(EquivalenceClass),
    fp_to_class: ClassIndex,
    class_vectors: vector_arena.ClassVectorArena,

    pub fn init(allocator: std.mem.Allocator, num_batches: usize) !ExpressionDatabase {
        return .{
            .allocator = allocator,
            .expr_arena = try expr_arena.ExpressionArena.init(allocator),
            .expr_to_class = blk: {
                var list = std.ArrayList(ClassId).init(allocator);
                list.ensureTotalCapacity(5_000_000) catch @panic("oom");
                break :blk list;
            },
            .classes = std.ArrayList(EquivalenceClass).init(allocator),
            .fp_to_class = .{},
            // Page-backed so the vectors can be freed and rebuilt when the sample grid grows.
            .class_vectors = try vector_arena.ClassVectorArena.init(std.heap.page_allocator, num_batches),
        };
    }

    pub fn deinit(self: *ExpressionDatabase) void {
        self.fp_to_class.deinit();
        self.classes.deinit();
        self.expr_to_class.deinit();
        self.expr_arena.deinit();
        self.class_vectors.deinit();
    }
};
