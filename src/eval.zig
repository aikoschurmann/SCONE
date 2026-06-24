const std = @import("std");
const ast = @import("ast.zig");
const expr_arena = @import("arena.zig");

/// The number of samples used to evaluate and fingerprint an expression.
/// We use 64 to fill exactly two AVX2 registers or one AVX-512 register,
/// providing 64 bits of entropy for boolean expressions.
pub const N_SAMPLES = 64;

/// A native SIMD vector of 64 32-bit integers.
/// Mathematical operations on this type compile directly to highly optimized SIMD assembly.
pub const Vector64 = @Vector(N_SAMPLES, u32);

/// The evaluation context provides the input variables (x, y, z) across 64 distinct test cases.
/// These test cases are used to generate the "Fingerprint" for an expression.
pub const EvaluationContext = struct {
    x_samples: Vector64,
    y_samples: Vector64,
    z_samples: Vector64,

    /// Initializes a context with a mix of highly structured compiler edge-cases
    /// and PRNG entropy to prevent "All Zeros" boolean collapses.
    pub fn init(prng: std.rand.Random) EvaluationContext {
        var ctx: EvaluationContext = undefined;

        // --- ZONE 1: The Smart Seeds ---
        // These structured inputs destroy trivial equivalences (like x & 0xFFFF == 0)
        // by guaranteeing coverage of critical 32-bit boundaries.
        const edge_cases = [_]u32{
            0, 1, 2, 3, 4, 8, 16, 31, 32,
            0xFFFFFFFF, // All ones (-1)
            0x80000000, // INT_MIN (Sign bit only)
            0x7FFFFFFF, // INT_MAX (All bits except sign)
            0x55555555, // Alternating bits (0101...)
            0xAAAAAAAA, // Alternating bits (1010...)
            0x0000FFFF, // Bottom half mask
            0xFFFF0000, // Top half mask
        };

        // Fill the first 16 lanes.
        // We add offsets (+% 1, +% 2) to y and z.
        // If x == y == z for the first 16 lanes, expressions like `x == y`
        // would falsely evaluate to true for 25% of our test cases.
        for (edge_cases, 0..) |val, i| {
            ctx.x_samples[i] = val;
            ctx.y_samples[i] = val +% 1;
            ctx.z_samples[i] = val +% 2;
        }

        // --- ZONE 2: PRNG Entropy ---
        // Fill the remaining lanes (16 to 63) with pure randomness to catch
        // complex mathematical overlaps that slip past the edge cases.
        for (16..N_SAMPLES) |i| {
            ctx.x_samples[i] = prng.int(u32);
            ctx.y_samples[i] = prng.int(u32);
            ctx.z_samples[i] = prng.int(u32);
        }

        return ctx;
    }
};

/// The output of evaluating an ast.Expr across the 64 samples.
pub const Fingerprint = struct {
    output: Vector64,

    /// Calculates a fast FNV-1a 64-bit hash of the fingerprint.
    /// (Note: Zig's std.AutoHashMap uses Wyhash by default, but this is useful
    /// if you implement a custom map or need to hash the fingerprint for external storage).
    pub fn hash(self: *const Fingerprint) u64 {
        var h: u64 = 14695981039346656037; // FNV offset basis
        const prime: u64 = 1099511628211; // FNV prime

        // Safely view the 64-element SIMD vector as a flat slice of 256 individual bytes (u8)
        const bytes = std.mem.asBytes(&self.output);

        for (bytes) |b| {
            h ^= b; // XOR the byte into the bottom of the hash
            h *%= prime; // Multiply by the prime
        }

        return h;
    }
};

/// A 32-bit index representing a pointer to an EquivalenceClass.
pub const ClassId = u32;

/// A formal equivalence class containing expressions proven to compute the exact same function.
pub const EquivalenceClass = struct {
    fingerprint: Fingerprint,
    canonical_expr: ast.ExprId, // The minimum-cost champion of this class (C0)
};

/// A dynamic list optimized for the absolute fast-path.
/// Stores 1 item inline (zero heap allocations) but safely upgrades
/// to a dynamic ArrayList if SMT-verified collisions occur.
pub const SmallClassList = union(enum) {
    inline_val: ClassId,
    dynamic: std.ArrayList(ClassId),

    /// Initializes the list with a single value, allocating no memory.
    pub fn init(first_val: ClassId) SmallClassList {
        return .{ .inline_val = first_val };
    }

    /// Appends a new ClassId. Only triggers a heap allocation if a collision actually happens.
    pub fn append(self: *SmallClassList, allocator: std.mem.Allocator, val: ClassId) !void {
        switch (self.*) {
            .inline_val => |existing_val| {
                // Upgrade to dynamic list upon collision
                var list = try std.ArrayList(ClassId).initCapacity(allocator, 4);
                list.appendAssumeCapacity(existing_val);
                list.appendAssumeCapacity(val);
                self.* = .{ .dynamic = list };
            },
            .dynamic => |*list| {
                try list.append(val);
            },
        }
    }

    /// Provides a safe slice to iterate over, hiding the internal union state.
    pub fn slice(self: *const SmallClassList) []const ClassId {
        switch (self.*) {
            .inline_val => |*val| return @as(*const [1]ClassId, @ptrCast(val))[0..],
            .dynamic => |*list| return list.items,
        }
    }

    /// Frees memory ONLY if it was upgraded to a dynamic list.
    pub fn deinit(self: *SmallClassList) void {
        if (self.* == .dynamic) {
            self.dynamic.deinit();
        }
    }
};

/// The global data store for the enumeration run.
/// Uses struct-of-arrays and tight indexing to keep the memory footprint low.
pub const ExpressionDatabase = struct {
    allocator: std.mem.Allocator,

    /// Maps ExprId -> Expr (The actual AST nodes)
    expr_arena: expr_arena.ExpressionArena,

    /// Maps ExprId -> ClassId (Keeps mapping overhead to just 4 bytes per expression)
    expr_to_class: std.ArrayList(ClassId),

    /// Maps ClassId -> EquivalenceClass (Holds the heavy 256-byte fingerprints)
    classes: std.ArrayList(EquivalenceClass),

    /// The O(1) Deduplication Index.
    /// Maps Fingerprint -> A list of ClassIds to handle SAT solver collisions safely.
    fp_to_class: std.AutoHashMap(Fingerprint, SmallClassList),

    /// Pre-allocates the entire database to avoid expensive re-hashing and memory copies mid-run.
    pub fn init(
        allocator: std.mem.Allocator,
        expected_expr_count: usize,
        expected_class_count: usize,
    ) !ExpressionDatabase {

        // 1. Pre-allocate the HashMap
        var fp_map = std.AutoHashMap(Fingerprint, SmallClassList).init(allocator);
        try fp_map.ensureTotalCapacity(@as(u32, @intCast(expected_class_count)));

        return .{
            .allocator = allocator,

            // 2. Pre-allocate Arenas and Arrays
            .expr_arena = try expr_arena.ExpressionArena.init(allocator, expected_expr_count),
            .expr_to_class = try std.ArrayList(ClassId).initCapacity(allocator, expected_expr_count),
            .classes = try std.ArrayList(EquivalenceClass).initCapacity(allocator, expected_class_count),
            .fp_to_class = fp_map,
        };
    }

    /// Safely frees all memory associated with the database.
    pub fn deinit(self: *ExpressionDatabase) void {
        // 1. Free any dynamically allocated SmallClassLists
        var it = self.fp_to_class.valueIterator();
        while (it.next()) |list| {
            list.deinit();
        }

        // 2. Free core arrays and maps
        self.fp_to_class.deinit();
        self.classes.deinit();
        self.expr_to_class.deinit();
        self.expr_arena.deinit();
    }
};
