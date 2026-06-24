const std = @import("std");

// Struct containing 32 random inputs for each variable.
// Used to evaluate Expr with, if two Expr have the same fingerprint
// Then its very likely they represent the same Expr (later verified with a SAT solver)
pub const EvaluationContext = struct {
    x_samples: [32]u32,
    y_samples: [32]u32,
    z_samples: [32]u32,
};

// The result of evaluating the ast.Expr across the EvaluationContext samples
pub const Fingerprint = struct {
    samples: [32]u32,

    // We need a fast way to check if two fingerprints might be identical
    // before doing a full 32-element array comparison.
    pub fn hash(self: *const Fingerprint) u64 {
        // Standard FNV-1a 64-bit constants
        var h: u64 = 14695981039346656037; // FNV offset basis
        const prime: u64 = 1099511628211; // FNV prime

        // Safely view the [32]u32 array as a flat slice of 128 individual bytes (u8)
        const bytes = std.mem.asBytes(&self.samples);

        for (bytes) |b| {
            h ^= b; // XOR the byte into the bottom of the hash
            h *%= prime; // Multiply by the prime
        }

        return h;
    }
};
