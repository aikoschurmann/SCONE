const std = @import("std");

pub var active: Config = .{};

pub const Config = struct {
    distill_ces: bool = false,
    clean_db: bool = false,
    use_pruning: bool = true,
    enable_unary: bool = true,
    enable_select: bool = true,
    use_cartesian_grid: bool = false,
    /// Fill the default samples with uniform random values only (no edge-value mixing).
    uniform_random_samples: bool = false,
    num_random_samples: usize = 4096,
    z3_timeout_ms: u32 = 1000,
    /// Settle members that a range / known-bits analysis proves equal to a constant base.
    use_absint: bool = true,
    /// Re-check every Nth abstract-interpreter proof with Z3 (0 = off). Soundness safety net.
    audit_absint: u32 = 0,
    /// Re-check every Nth normal-form proof with Z3 (0 = off). Soundness safety net.
    audit_normalize: u32 = 0,
    /// Bit i enables BinOp with enum value i (`--binops`, `--lite`).
    binop_mask: u32 = ~@as(u32, 0),
    /// Bit i enables UnOp with enum value i (`--unops`). Only used when enable_unary is set.
    unop_mask: u32 = ~@as(u32, 0),
    /// Bit i enables search_constants[i] as a cost-0 leaf (`--consts`, `--lite`).
    const_mask: u32 = ~@as(u32, 0),
};

pub const q_size = 131072;

pub const core_numbers = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32 };
pub const bit_patterns = [_]u32{ 0xFFFF, 0x55555555, 0xAAAAAAAA };

pub const base_edge_cases = [_]u32{
    0,          1,          2,          3,          4,          8,          16,         31,         32,
    0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD, 0xFFFFFFFC, 0xFFFFFFF8, 0xFFFFFFF0, 0xFFFFFFE1, 0xFFFFFFE0, 0x80000000,
    0x7FFFFFFF, 0x80000001, 0x7FFFFFFE, 0xFFFF,     0x55555555, 0xAAAAAAAA,
};

pub const num_edge_cases = base_edge_cases.len;
pub const search_constants = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xFFFF };
