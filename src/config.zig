const std = @import("std");

pub var active: Config = .{};

pub const Config = struct {
    is_perf_mode: bool = false,
    distill_ces: bool = false,
    clean_db: bool = false,
    use_pruning: bool = true,
    enable_unary: bool = true,
    enable_select: bool = true,
    use_cartesian_grid: bool = false,
    num_random_samples: usize = 4096,
    max_classes_to_verify: usize = 500_000,
    max_counterexamples_per_iter: usize = 5000,
    z3_timeout_ms: u32 = 1000,
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
